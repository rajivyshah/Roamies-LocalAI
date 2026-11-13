// The Claude Code route ("Sign in with Claude"), driven by a stubbed SDK query. Run: npm test
import assert from 'node:assert/strict';
import { z } from 'zod';
import { ClaudeCodeAgent, closeSpare, fingerprint, resumeId } from '../claudecode.mjs';
import { agentEvents } from '../agentstream.mjs';

const SESSION = 'sess-1', TOOL_ID = 'toolu_1', MSG1 = 'msg_1', MSG2 = 'msg_2';
const ev = (event) => ({ type: 'stream_event', event, parent_tool_use_id: null, session_id: SESSION });

// A fake query(): connects to our MCP server like Claude Code does, calls one tool, then answers.
function fakeQuery(script) {
  const calls = { options: null, inputs: [], interrupts: 0, closes: 0 };
  const query = ({ prompt, options }) => {
    calls.options = options;
    const inputs = prompt[Symbol.asyncIterator]();
    let rpc;
    const connect = async () => {
      const waiting = new Map();
      const transport = { onmessage: undefined, async send(msg) { waiting.get(msg.id)?.(msg); } };
      await options.mcpServers.gg.instance.connect(transport);
      let n = 0;
      return (method, params) => new Promise((resolve) => { const id = ++n; waiting.set(id, resolve); transport.onmessage({ jsonrpc: '2.0', id, method, params }); });
    };
    const ctx = {
      async nextInput() { const x = await inputs.next(); if (!x.done) calls.inputs.push(x.value); return x.value; },
      async rpc(method, params) { rpc ??= await connect(); return rpc(method, params); },
    };
    return Object.assign(script(ctx), { interrupt: async () => { calls.interrupts++; }, close: () => { calls.closes++; } });
  };
  return { query, calls };
}

async function* toolRun(ctx) {
  await ctx.nextInput();
  yield { type: 'system', subtype: 'init', session_id: SESSION };
  const listed = await ctx.rpc('tools/list', {});
  assert.deepEqual(listed.result.tools.map((t) => t.name), ['read_file'], 'our tools are listed over MCP');
  yield ev({ type: 'message_start', message: { id: MSG1, usage: { input_tokens: 10, cache_read_input_tokens: 4 } } });
  yield ev({ type: 'content_block_delta', delta: { type: 'text_delta', text: 'Checking. ' } });
  yield { type: 'assistant', parent_tool_use_id: null, message: { id: MSG1, model: 'claude-haiku-5-5', content: [{ type: 'text', text: 'Checking. ' }, { type: 'tool_use', id: TOOL_ID, name: 'mcp__gg__read_file', input: { path: '~/a.txt' } }] } };
  yield ev({ type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { input_tokens: 10, output_tokens: 5 } });
  yield ev({ type: 'message_stop' });
  const called = await ctx.rpc('tools/call', { name: 'read_file', arguments: { path: '~/a.txt' }, _meta: { 'claudecode/toolUseId': TOOL_ID } });
  assert.deepEqual(called.result.content, [{ type: 'text', text: 'pancake' }], 'the tool result goes back to Claude Code');
  yield { type: 'user', parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: TOOL_ID, content: [{ type: 'text', text: 'pancake' }] }] } };
  yield ev({ type: 'message_start', message: { id: MSG2, usage: {} } });
  yield ev({ type: 'content_block_delta', delta: { type: 'text_delta', text: 'It says pancake.' } });
  yield { type: 'assistant', parent_tool_use_id: null, message: { id: MSG2, model: 'claude-haiku-5-5', content: [{ type: 'text', text: 'It says pancake.' }] } };
  yield ev({ type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { input_tokens: 20, output_tokens: 4 } });
  yield ev({ type: 'message_stop' });
  yield { type: 'result', subtype: 'success', is_error: false, result: 'It says pancake.', session_id: SESSION };
}

const ran = [];
const readFile = { name: 'read_file', description: 'Read a file', parameters: z.object({ path: z.string() }), execute: async (a) => { ran.push(a.path); return 'pancake'; } };
const { query, calls } = fakeQuery(toolRun);
let saved = null;
const agent = new ClaudeCodeAgent({
  model: 'claude-haiku-5-5', system: 'You are Roamie.', tools: [readFile], maxTurns: 24, thinking: 'low',
  priorMessages: [{ role: 'user', content: 'hi' }, { role: 'assistant', content: [{ type: 'text', text: 'hello!' }] }],
  transformContext: (msgs) => msgs.map((m, i) => (i === msgs.length - 1 ? { ...m, content: `<live-state>now</live-state>\n\n${m.content}` } : m)),
  executable: '/bin/claude', cwd: '/home/me', env: { A: '1' }, query, onRateLimit: () => {}, onResume: (s) => { saved = s; },
});

const types = [];
for await (const e of agentEvents(agent.prompt('what is in a.txt?'))) types.push(e.type);
assert.deepEqual(types, ['text_delta', 'turn_end', 'tool_call_start', 'tool_call_end', 'checkpoint', 'text_delta', 'turn_end', 'agent_done'], 'SDK messages map to agent events');
assert.deepEqual(ran, ['~/a.txt'], 'the bridged tool ran once');

const o = calls.options;
assert.equal(o.systemPrompt.prompt, 'You are Roamie.');
assert.deepEqual(o.tools, [], 'none of Claude Code\'s own tools');
assert.deepEqual(o.allowedTools, ['mcp__gg__read_file']);
assert.equal(o.cwd, '/home/me'); assert.equal(o.pathToClaudeCodeExecutable, '/bin/claude'); assert.deepEqual(o.env, { A: '1' });
assert.equal(o.effort, 'low'); assert.equal(o.maxTurns, 24); assert.equal(o.resume, undefined, 'a fresh session');
assert.deepEqual((await o.canUseTool('Bash', {})).behavior, 'deny', 'anything not ours is denied');
const sent = calls.inputs[0].message.content.map((p) => p.text).join('\n');
assert.match(sent, /<conversation_so_far>[\s\S]*User: hi[\s\S]*Assistant: hello!/, 'a fresh session is seeded with the history');
assert.match(sent, /<live-state>now<\/live-state>\n\nwhat is in a\.txt\?$/, 'the pending turn carries the live block');

const msgs = agent.getMessages();
assert.deepEqual(msgs.map((m) => m.role), ['system', 'user', 'assistant', 'user', 'assistant', 'tool', 'assistant']);
assert.equal(msgs[3].content, 'what is in a.txt?', 'the saved user turn has no live block');
assert.deepEqual(msgs[4].content.map((p) => p.type), ['text', 'tool_call']);
assert.equal(msgs[4].content[1].name, 'read_file', 'the MCP prefix is stripped');
assert.equal(msgs[5].content[0].content, 'pancake');
assert.equal(msgs[6].content[0].text, 'It says pancake.');
assert.equal(calls.closes, 1, 'the query is closed after the run');

// The next prompt continues the same Claude Code session, also after the agent is rebuilt from saved messages.
assert.equal(saved.sessionId, SESSION);
assert.equal(resumeId(saved, [...msgs, { role: 'user', content: 'and b?' }]), SESSION);
const fromDisk = msgs.map((m) => JSON.parse(JSON.stringify(m)));
assert.equal(resumeId(saved, [...fromDisk, { role: 'user', content: 'and b?' }]), SESSION, 'survives a save and reload');
assert.equal(resumeId(saved, [...msgs, { role: 'assistant', content: 'other route' }, { role: 'user', content: 'x' }]), undefined, 'turns from another provider start fresh');
assert.equal(resumeId(saved, msgs.slice(0, 3)), undefined, 'trimmed history starts fresh');
assert.equal(fingerprint({ role: 'user', content: [{ type: 'text', text: 'a' }, { type: 'image', data: 'x' }] }), fingerprint({ role: 'user', content: [{ type: 'text', text: 'a' }, { type: 'image', data: '' }] }), 'old images dropped on save keep the fingerprint');

// A failed run reaches the caller as an error, with Claude Code's own message.
async function* failing(ctx) {
  await ctx.nextInput();
  yield { type: 'assistant', parent_tool_use_id: null, message: { id: 'x', model: '<synthetic>', content: [{ type: 'text', text: 'API Error: 401 not logged in' }] } };
  yield { type: 'result', subtype: 'success', is_error: true, result: '' };
}
const bad = new ClaudeCodeAgent({ model: 'm', system: 's', tools: [], executable: '/bin/claude', cwd: '/', env: {}, query: fakeQuery(failing).query, onRateLimit: () => {} });
await assert.rejects(async () => { for await (const _ of agentEvents(bad.prompt('hi'))); }, /401 not logged in/);

// Stop: the run ends quietly and the dangling tool call gets a result.
const stopper = fakeQuery(async function* (ctx) {
  await ctx.nextInput();
  yield { type: 'assistant', parent_tool_use_id: null, message: { id: 'y', model: 'm', content: [{ type: 'tool_use', id: 't9', name: 'mcp__gg__read_file', input: { path: 'x' } }] } };
  await new Promise((r) => setTimeout(r, 30));
  yield { type: 'result', subtype: 'error_during_execution', errors: [] };
});
const ctl = new AbortController();
const stopped = new ClaudeCodeAgent({ model: 'm', system: 's', tools: [readFile], executable: '/bin/claude', cwd: '/', env: {}, query: stopper.query, signal: ctl.signal, onRateLimit: () => {} });
setTimeout(() => ctl.abort(), 10);
const stopTypes = [];
for await (const e of agentEvents(stopped.prompt('go'))) stopTypes.push(e.type);
assert.deepEqual(stopTypes, ['agent_done']);
assert.equal(stopper.calls.interrupts, 1, 'Claude Code is interrupted');
assert.equal(stopped.getMessages().at(-1).content[0].isError, true, 'the open tool call is closed');

// Warm spare: once a run ends, the next one's Claude Code is started ahead (same options, the session to resume)
// and the next prompt takes it instead of starting one; its tools still go through our bridge.
{
  const cold = fakeQuery(toolRun), warmed = fakeQuery(toolRun), starts = [];
  let closes = 0;
  const startup = async ({ options }) => { starts.push(options); return { query: (prompt) => warmed.query({ prompt, options }), close: () => { closes++; } }; };
  const opts = { model: 'claude-haiku-5-5', system: 'You are Roamie.', tools: [readFile], executable: '/bin/claude', cwd: '/', env: {}, onRateLimit: () => {}, keepWarm: true, query: cold.query, startup };
  const a = new ClaudeCodeAgent(opts);
  ran.length = 0;
  for await (const _ of agentEvents(a.prompt('one'))) {}
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(starts.length, 1, 'a spare is started when the run ends');
  assert.equal(starts[0].resume, SESSION, 'the spare continues the same session');
  const types2 = [];
  for await (const e of agentEvents(a.prompt('two'))) types2.push(e.type);
  assert.ok(warmed.calls.options, 'the next prompt runs on the spare');
  assert.equal(cold.calls.inputs.length, 1, 'no second cold start');
  assert.ok(types2.includes('tool_call_end') && types2.at(-1) === 'agent_done', 'tool events still arrive through the spare');
  assert.deepEqual(ran, ['~/a.txt', '~/a.txt'], 'the spare served our tool');
  a.warm();
  const b = new ClaudeCodeAgent({ ...opts, model: 'claude-sonnet-5-5', query: fakeQuery(toolRun).query });
  for await (const _ of agentEvents(b.prompt('other model'))) {}
  await new Promise((r) => setTimeout(r, 0));
  assert.ok(closes >= 1, 'a spare made for other options is closed, not used');
  closeSpare();
}
// A spare that died while waiting: the prompt falls back to a fresh start.
{
  const cold = fakeQuery(toolRun);
  const dead = { query: () => Object.assign((async function* () { throw new Error('process exited'); })(), { interrupt: async () => {}, close: () => {} }), close: () => {} };
  const opts = { model: 'm', system: 's', tools: [readFile], executable: '/bin/claude', cwd: '/', env: {}, onRateLimit: () => {}, keepWarm: true, query: cold.query, startup: async () => dead };
  const c = new ClaudeCodeAgent(opts);
  c.warm();
  const types3 = [];
  for await (const e of agentEvents(c.prompt('hi'))) types3.push(e.type);
  assert.equal(types3.at(-1), 'agent_done', 'the run still completes');
  assert.equal(cold.calls.inputs.length, 1, 'it started Claude Code afresh');
  closeSpare();
}

// The handed-over transcript keeps tool calls out of what the assistant said, so they aren't copied into replies.
{
  const { renderTranscript } = await import('../claudecode.mjs');
  const t = renderTranscript([
    { role: 'user', content: 'what is on my screen?' },
    { role: 'assistant', content: [{ type: 'text', text: 'Reading the page now.\n[called read_window {"target":"browser"}]' }, { type: 'tool_call', id: 't1', name: 'read_window', args: { target: 'browser' } }] },
    { role: 'tool', content: [{ type: 'tool_result', toolCallId: 't1', content: 'Brave Browser — Electrobun' }] },
    { role: 'assistant', content: [{ type: 'text', text: 'Electrobun is open.' }] },
  ], 10_000);
  assert.ok(!/\[called/.test(t), 'no "[called …]" lines, also not ones saved from before');
  assert.match(t, /Assistant: Reading the page now\.\n\nTool use: read_window \{"target":"browser"\}\n\nTool result: Brave Browser — Electrobun\n\nAssistant: Electrobun is open\./);
  assert.match(t, /never text to write in a reply/);
}
// The SDK is loaded lazily, so a run that can't even start must report the failure rather than hang.
{
  const { ClaudeCodeAgent: Agent } = await import('../claudecode.mjs');
  // A query that throws stands in for the SDK being missing when the run starts.
  const broken = new Agent({
    model: 'm', system: 's', tools: [], executable: '/bin/claude', cwd: '/', env: {}, onRateLimit: () => {},
    query: () => { throw new Error('Claude Code isn\'t available.'); },
  });
  await assert.rejects(async () => { for await (const _ of agentEvents(broken.prompt('hi'))); }, /isn't available/,
    'a run that cannot start ends with an error instead of hanging');
}

console.log('claudecode ok');
