// The hands tools (macOS and Windows) against a fake hands helper: act_in_app drops read-only steps, screenshots use the helper's own
// resize, and an app that isn't installed gives a plain answer. Run: npm test
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

if (!['darwin', 'win32'].includes(process.platform)) { console.log('hands tests: skipped (macOS and Windows only)'); process.exit(0); }
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'roamies-hands-test-'));
// A .mjs helper runs on this Node (tools.mjs), so the same fake works on Windows.
const log = path.join(dir, 'calls.jsonl'), fake = path.join(dir, 'hands.mjs');
fs.writeFileSync(fake, `import fs from 'node:fs'; const a = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(a) + '\\n');
const swap = ${JSON.stringify(path.join(dir, 'front.json'))};
const win = fs.existsSync(swap) ? JSON.parse(fs.readFileSync(swap, 'utf8')) : { id: 7, app: 'TextEdit', title: 'notes.txt', bounds: [0, 0, 800, 600] };
let o = { ok: true, window: win };
if (a[0] === 'act') { const p = JSON.parse(a[1]); o = p.app === 'NoSuchAppRoamiesTest' ? { ok: false, error: 'No matching window is open.' } : { ok: true, done: p.steps.map((s) => s.do), window: win }; }
// Live progress on stderr, as the real helpers write it: where each step lands, what it types, when it takes the cursor.
if (a[0] === 'act' && JSON.parse(a[1]).app === 'HopTest') {
  for (const d of [{ ev: 'start', window: win, steps: 3 }, { ev: 'step', i: 0, do: 'click', label: 'Save', bounds: [100, 200, 80, 24] }, { ev: 'step', i: 1, do: 'key', label: 'cmd+a' },
    { ev: 'borrow' }, { ev: 'step', i: 2, do: 'type', label: '', text: 'my secret words', bounds: [300, 400, 200, 30] }, { ev: 'return' }]) console.error('@' + JSON.stringify(d));
  console.error('not progress');
}
if (a[0] === 'find-text') o = { ok: true, matches: [{ text: a[2], match: 'exact', role: 'button', bounds: [100, 100, 80, 24], window: win }] };
if (a[0] === 'ui') o = { ok: true, window: win, controls: [], texts: [], note: 'Nothing to list.' };
if (a[0] === 'front') { if (win.slowFront) { const t = Date.now(); while (Date.now() - t < 2000); } o = { ok: true, app: win.app, title: win.title, ...(win.url ? { url: win.url } : {}) }; }
if (a[0] === 'capture') { fs.writeFileSync(a[1], 'x'); o = { ok: true, file: a[1], window: win, pixels: [800, 600] }; }
console.log(JSON.stringify(o));
`);
process.env.ROAMIES_HANDS = fake;
const { createTools } = await import('../tools.mjs');
const noop = async () => {};
const { tools } = createTools({ allowActions: () => true, ui: () => {}, ask: async () => false, openUrl: noop, onCommitments: noop, showList: noop, fmtWhen: String, commitmentsText: () => '', userName: 'Test' });
const tool = (n) => tools.find((t) => t.name === n);
const calls = () => fs.readFileSync(log, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
const ctx = { toolCallId: 't1' };

// read_window / take_screenshot inside act_in_app steps are dropped, not a failed call.
fs.writeFileSync(log, '');
const r = await tool('act_in_app').execute({ target: 'TextEdit', steps: [{ do: 'key', key: 'cmd+end' }, { do: 'read_window' }, { do: 'type', text: 'hi' }] }, ctx);
assert.match(r, /key, type/);
const act = calls().find((c) => c[0] === 'act');
assert.deepEqual(JSON.parse(act[1]).steps.map((s) => s.do), ['key', 'type']);
assert.ok(!calls().some((c) => c[0] === 'capture'), 'no window pictures taken while it works in an app');
// Regression: only a read_window step failed the call; it reads the window instead.
assert.match(await tool('act_in_app').execute({ target: 'TextEdit', steps: [{ do: 'read_window' }] }, ctx), /^TextEdit — notes\.txt/);
assert.ok(!calls().some((c) => c[0] === 'act' && JSON.parse(c[1]).steps.length === 0), 'no empty act sent');

// Screenshots ask the helper to shrink to 1568 px and use the size it reports.
fs.writeFileSync(log, '');
const shot = await tool('take_screenshot').execute({ target: 'TextEdit' }, ctx);
assert.match(shot.content[0].text, /800×600 px/);
assert.ok(calls().some((c) => c[0] === 'capture' && c[3] === '1568'));
// Shot at once with nothing shown on screen: no window lookup first, no preview copy for an animation.
assert.ok(!calls().some((c) => c[0] === 'locate'), 'no locate round trip before the shot');
assert.equal(calls().find((c) => c[0] === 'capture').length, 4, 'no preview thumbnail requested');

// While it acts, the overlay hears where each step lands (in order) and when the real cursor is taken, between
// "on" and "off". Never what is typed.
{
  const seen = [];
  const made = createTools({ allowActions: () => true, ui: (m) => { if (m.kind === 'hands') seen.push(m); }, ask: async () => false, openUrl: noop, onCommitments: noop, showList: noop, fmtWhen: String, commitmentsText: () => '', userName: 'Test' });
  await made.hands('act', JSON.stringify({ app: 'HopTest', steps: [{ do: 'click', id: 1 }, { do: 'key', key: 'cmd+a' }, { do: 'type', text: 'my secret words' }] }));
  assert.deepEqual(seen, [{ kind: 'hands', on: true }, { kind: 'hands', step: { bounds: [100, 200, 80, 24] } }, { kind: 'hands', borrow: true },
    { kind: 'hands', step: { bounds: [300, 400, 200, 30] } }, { kind: 'hands', on: false }]);
  assert.ok(!JSON.stringify(seen).includes('secret'), 'typed text never reaches the overlay');
  // Reading a window is not acting: nothing is sent.
  seen.length = 0;
  await made.hands('ui', 'front');
  assert.deepEqual(seen, []);
}

// An app that isn't installed: one clear answer instead of "No matching window".
await assert.rejects(tool('act_in_app').execute({ target: 'NoSuchAppRoamiesTest', steps: [{ do: 'key', key: 'return' }] }, ctx), /no app called "NoSuchAppRoamiesTest"/);
await assert.rejects(tool('open').execute({ target: 'NoSuchAppRoamiesTest' }, ctx), /no app called "NoSuchAppRoamiesTest"/);

// A bare web address opens as a link (in the app asked for), not as an app called "example.com".
const opened = await tool('open').execute({ target: 'example.invalid-tld-roamies.test', app: 'NoSuchAppRoamiesTest' }, ctx).catch((e) => String(e.message));
assert.match(opened, /no app called "NoSuchAppRoamiesTest"/, 'treated as a link opened in the named app');

// The stale watcher polls every 1.5 s and each poll spawns the helper, which is slow on a CI runner: wait for
// the event instead of for a fixed time, or the test fails on a slow machine.
const waitFor = async (fn, ms = 20_000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (fn()) return true; await new Promise((r) => setTimeout(r, 50)); } return false; };
const settle = (ms) => new Promise((r) => setTimeout(r, ms));

// draw: a walkthrough waits for each click, and each next step is looked up only after it (the screen has changed).
{
  fs.writeFileSync(log, '');
  const sent = [], spoken = [], other = [];
  let clicks = 0, hold = false;
  const made = createTools({
    allowActions: () => true, ask: async () => false, openUrl: noop, onCommitments: noop, showList: noop, fmtWhen: String, commitmentsText: () => '', userName: 'Test',
    speak: (t) => { spoken.push(t); return true; },
    ui: (m) => {
      if (m.e?.type?.startsWith('ink_')) other.push(m.e);
      if (m.e?.type !== 'draw') return;
      sent.push({ ...m.e, lookups: calls().filter((c) => c[0] === 'find-text').map((c) => c[2]) });
      setImmediate(() => {
        made.ink.started(m.e.id, m.e.seg);
        const last = m.e.beats.at(-1);
        if (last?.wait && !hold) setTimeout(() => { clicks++; made.ink.waitDone(m.e.id, last.n, 'clicked'); }, 5);
      });
    },
  });
  const draw = made.tools.find((t) => t.name === 'draw');
  const step = (say, text) => ({ say, marks: [{ kind: 'target', at: { text }, label: text }], wait: 'click' });
  const res = await draw.execute({ beats: [step('[warm] Open Format first.', 'Format'), step('Then pick High.', 'High')] }, { toolCallId: 'd1' });
  assert.equal(clicks, 2);
  assert.deepEqual(sent.map((e) => [e.seg, e.beats.map((b) => b.n), e.last]), [[0, [1], false], [1, [2], true]], 'one segment per waiting step');
  assert.deepEqual(sent[0].lookups, ['Format'], 'step 2 is not looked up before step 1 is clicked');
  assert.deepEqual(sent[1].lookups, ['Format', 'High']);
  assert.deepEqual(sent[0].beats[0].at, undefined);
  assert.deepEqual(sent[0].beats[0].marks[0].at.rect, [100, 100, 80, 24], 'exact bounds from the helper');
  assert.equal(sent[0].beats[0].caption, 'Open Format first.', 'the caption drops voice cues');
  assert.equal(sent[0].beats[0].voiced, true);
  assert.deepEqual(spoken, ['[warm] Open Format first.', 'Then pick High.'], 'each line is spoken when its step starts');
  assert.match(res, /Drew p1 target “Format”, p2 target “High”\..*Beat 1: Test clicked\..*Beat 2: Test clicked\./);
  // Regression: after a walkthrough the reply said each step again. The result quotes what was already said, last.
  assert.match(res, /Already said out loud as it drew: "Open Format first\." "Then pick High\." Don't repeat or rephrase any of that in your reply/);
  // An explanation without waits: each beat goes out as soon as its own places are found (the first marks draw while
  // the rest are looked up), all spoken in order, and the same words are looked up once.
  sent.length = 0; spoken.length = 0; fs.writeFileSync(log, '');
  const ring = (text) => ({ kind: 'ring', at: { text } });
  await draw.execute({ beats: [{ say: 'One.', marks: [ring('A'), { kind: 'connect', at: { text: 'A' }, to: { text: 'B' } }] }, { say: 'Two.', marks: [ring('C')] }, { say: 'Three.', marks: [ring('D')] }] }, { toolCallId: 'd5' });
  assert.deepEqual(sent.map((e) => [e.seg, e.last]), [[0, false], [1, false], [2, true]]);
  assert.deepEqual(sent[0].lookups, ['A', 'B'], 'beat 1 is sent before beats 2 and 3 are looked up, and "A" is looked up once');
  assert.deepEqual(spoken, ['One.', 'Two.', 'Three.']);
  // Edits name what's there; unknown parts are refused with the list.
  await assert.rejects(draw.execute({ edit: [{ do: 'recolor', part: 'p9', tone: 'red' }] }, { toolCallId: 'd2' }), /no p9 on screen now \(there is: p1 target “Format”, p2 target “High”, p3 ring “A”/);
  assert.match(await draw.execute({ edit: [{ do: 'recolor', part: 'p1', tone: 'red' }] }, { toolCallId: 'd3' }), /Edited the drawing/);
  // A drawing in a later request replaces the old one, cards and all; an edit in a later request keeps it.
  made.nextTurn();
  await draw.execute({ edit: [{ do: 'recolor', part: 'p1', tone: 'amber' }] }, { toolCallId: 'd6' });
  assert.ok(!other.some((e) => e.type === 'ink_clear'), 'editing keeps the drawing');
  made.nextTurn();
  await draw.execute({ beats: [{ say: 'A card.', marks: [{ kind: 'note', text: 'hi' }] }] }, { toolCallId: 'd7' });
  assert.deepEqual(other.at(-1), { type: 'ink_clear' }, 'everything cleared, not just the screen marks');
  assert.match(await draw.execute({ beats: [{ say: 'Another.', marks: [{ kind: 'note', text: 'two' }] }] }, { toolCallId: 'd8' }), /On screen now: p\d+ note “hi”, p\d+ note “two”\./, 'same request: cards add up');
  // Another window comes to the front: the whole drawing goes (cards too), and the model is told nothing is there.
  fs.writeFileSync(path.join(dir, 'front.json'), JSON.stringify({ id: 9, app: 'Safari', title: 'x', bounds: [0, 0, 900, 700] }));
  assert.ok(await waitFor(() => other.at(-1)?.type === 'ink_stale'), 'another window in front makes the drawing stale');
  await assert.rejects(draw.execute({ edit: [{ do: 'erase', part: 'p1' }] }, { toolCallId: 'd9' }), /nothing is drawn/);
  fs.rmSync(path.join(dir, 'front.json'));
  // A drawing that goes by itself (the tour, the setup showcase) is about no window: switching windows keeps it.
  other.length = 0;
  await made.ink.show([{ say: 'Graphs too.', marks: [{ kind: 'note', text: 'a showcase card' }] }], 'showcase-1', { fade: 5 });
  fs.writeFileSync(path.join(dir, 'front.json'), JSON.stringify({ id: 11, app: 'Notes', title: 'y', bounds: [0, 0, 900, 700] }));
  // Long enough for the watcher to have polled twice and found nothing wrong: the showcase is about no window.
  await settle(6000);
  assert.ok(!other.some((e) => e.type === 'ink_stale'), 'the showcase stays when another window comes to the front');
  assert.match(made.ink.describe(), /note “a showcase card”/);
  fs.rmSync(path.join(dir, 'front.json'));
  // Typing goes through the helper's fill (the same path as act_in_app).
  fs.writeFileSync(log, '');
  await draw.execute({ beats: [{ say: 'Your email goes here.', marks: [{ kind: 'type', at: { text: 'Email' }, text: 'a@b.com' }] }] }, { toolCallId: 'd4' });
  assert.deepEqual(JSON.parse(calls().find((c) => c[0] === 'act')[1]).steps, [{ do: 'fill', field: 'Email', text: 'a@b.com' }]);
  // Regression: talking over a walkthrough that waits for a click left its caption up, still waiting.
  made.nextTurn(); hold = true;
  const talk = new AbortController();
  const cut = draw.execute({ beats: [step('Click the Scale box.', 'Scale'), step('Then type 130.', 'Scale')] }, { toolCallId: 'd9', signal: talk.signal });
  while (!sent.some((e) => e.id === 'd9')) await new Promise((r) => setTimeout(r, 5));
  await new Promise((r) => setTimeout(r, 20));
  talk.abort();
  assert.equal(await cut, 'Stopped.');
  assert.deepEqual(other.at(-1), { type: 'ink_clear' }, 'the overlay stops too, and what it drew goes');
  hold = false;
  // Cut off before it got to waiting: it stops at once instead of waiting out the timeout.
  const early = new AbortController(); early.abort();
  const t0 = Date.now();
  assert.equal(await draw.execute({ beats: [step('Click Scale.', 'Scale')] }, { toolCallId: 'd10', signal: early.signal }), 'Stopped.');
  assert.ok(Date.now() - t0 < 5000, 'no wait for the timeout');
  // Regression: Stop while it was drawing diagrams (cards only, no screen marks) left them playing and on screen.
  made.nextTurn();
  await draw.execute({ beats: [{ say: 'A diagram.', marks: [{ kind: 'note', text: 'diagram' }] }] }, { toolCallId: 'd11' });
  other.length = 0;
  made.ink.stop(true);
  assert.deepEqual(other, [{ type: 'ink_clear' }], 'cancelling the request clears its cards and stops the overlay');
  assert.equal(made.ink.describe(), '', 'nothing of it is left');
  // Stopping only the voice after the answer is done keeps the cards, but still stops the overlay playing.
  await draw.execute({ beats: [{ say: 'Another.', marks: [{ kind: 'note', text: 'kept' }] }] }, { toolCallId: 'd12' });
  other.length = 0;
  made.ink.stop();
  assert.deepEqual(other, [{ type: 'ink_clear', screen: true, stop: true }]);
  assert.match(made.ink.describe(), /note “kept”/);
  // Regression: "make everything" drew eight cards at once, which covered the screen. Four stay up; the model is
  // told which closed, and what it lists as on screen is what's left.
  made.nextTurn();
  const many = await draw.execute({ beats: ['a', 'b', 'c', 'd', 'e', 'f'].map((text) => ({ say: `Card ${text}.`, marks: [{ kind: 'note', text }] })) }, { toolCallId: 'd13' });
  assert.match(many, /Drew p\d+ note “a”, .*p\d+ note “f”\./, 'all six are named as drawn');
  assert.match(many, /Only 4 cards stay up at once, so the oldest closed as newer ones were drawn \(p\d+, p\d+\)\./);
  assert.match(many, /On screen now: p\d+ note “c”, p\d+ note “d”, p\d+ note “e”, p\d+ note “f”\./);
  // A drawing that goes by itself (the setup showcase) keeps all of its cards.
  made.nextTurn();
  await made.ink.show(['a', 'b', 'c', 'd', 'e'].map((text) => ({ say: `Card ${text}.`, marks: [{ kind: 'note', text }] })), 'showcase-2', { fade: 5 });
  assert.match(made.ink.describe(), /note “a”.*note “e”/, 'the showcase keeps five cards');
  console.log('draw tool tests: passed');
}

// Regression: a borrowed real click landed on the Sidekick's bubble instead of the app (and its Cmd+A selected the
// overlay). The overlay goes click-through before the helper acts, and back after, even when acting fails.
{
  fs.writeFileSync(log, '');
  const seen = [];
  const t = createTools({ allowActions: () => true, ui: (m) => { if (m.kind === 'hands') seen.push({ on: m.on, acted: fs.readFileSync(log, 'utf8').includes('["act"') }); }, ask: async () => false, openUrl: noop, onCommitments: noop, showList: noop, fmtWhen: String, commitmentsText: () => '', userName: 'Test' }).tools;
  await t.find((x) => x.name === 'act_in_app').execute({ target: 'TextEdit', steps: [{ do: 'key', key: 'return' }] }, ctx);
  assert.deepEqual(seen, [{ on: true, acted: false }, { on: false, acted: true }], 'click-through on before acting, off after');
  seen.length = 0;
  await t.find((x) => x.name === 'act_in_app').execute({ target: 'NoSuchAppRoamiesTest', steps: [{ do: 'key', key: 'return' }] }, ctx).catch(() => {});
  assert.equal(seen.at(-1)?.on, false, 'click-through released after a failed act');
}

// A drawing goes with the screen it was about: a click in its window that changes what it shows (the user's, reported by
// the voice helper, or the agent's own), or one of its app's menu items. Cards too. Clicks elsewhere don't count.
{
  fs.writeFileSync(log, ''); if (fs.existsSync(path.join(dir, 'front.json'))) fs.rmSync(path.join(dir, 'front.json'));
  const events = [], watching = [];
  let hold = false;
  const made = createTools({
    allowActions: () => true, ask: async () => false, openUrl: noop, onCommitments: noop, showList: noop, fmtWhen: String, commitmentsText: () => '', userName: 'Test', speak: () => true,
    watchClicks: (on) => watching.push(on),
    ui: (m) => {
      if (m.e?.type?.startsWith('ink_')) events.push(m.e.type);
      if (m.e?.type !== 'draw') return;
      setImmediate(() => { made.ink.started(m.e.id, m.e.seg); const last = m.e.beats.at(-1); if (last?.wait && !hold) setTimeout(() => made.ink.waitDone(m.e.id, last.n, 'clicked'), 5); });
    },
  });
  const tool = (n) => made.tools.find((t) => t.name === n);
  const graph = async () => { made.nextTurn(); events.length = 0; await tool('draw').execute({ beats: [{ say: 'Sales.', marks: [{ kind: 'graph', title: 'Sales', plots: [{ label: 's', points: [[1, 1], [2, 3]] }] }, { kind: 'ring', at: { text: 'Buy' } }] }] }, { toolCallId: `g${Math.random()}` }); };
  await graph();
  assert.equal(watching.at(-1), true, 'clicks are watched while a drawing is on a window');
  made.ink.userClick({ x: 900, y: 300, role: 'AXLink', app: 'Safari', acts: true });
  assert.match(made.ink.describe(), /graph “Sales”/, 'a click outside its window leaves it');
  made.ink.userClick({ x: 300, y: 200, role: 'AXLink', app: 'TextEdit', acts: true });
  assert.equal(made.ink.describe(), '', 'a link clicked in its window: all of it goes, the graph card too');
  assert.deepEqual([events.at(-1), watching.at(-1)], ['ink_stale', false]);
  await graph();
  made.ink.userClick({ x: 40, y: 10, role: 'AXMenuItem', app: 'TextEdit', acts: true });
  assert.equal(made.ink.describe(), '', "one of its app's menu items counts too");
  await graph();
  await tool('act_in_app').execute({ target: 'TextEdit', steps: [{ do: 'type', text: 'hi' }] }, { toolCallId: 'a1' });
  assert.match(made.ink.describe(), /graph/, 'typing alone leaves it');
  await tool('act_in_app').execute({ target: 'TextEdit', steps: [{ do: 'click_text', text: 'Next page' }] }, { toolCallId: 'a2' });
  assert.equal(made.ink.describe(), '', "the agent's own click changes the screen too");
  await graph();
  // An app that doesn't exist, so the test never opens a real browser tab (it did, on every run): the drawing goes
  // as soon as the open is attempted.
  await tool('open').execute({ target: 'https://example.invalid-tld-roamies.test', app: 'NoSuchAppRoamiesTest' }).catch(() => {});
  assert.equal(made.ink.describe(), '', 'so does opening a page');
  // A walkthrough waiting for a click: that click is the step, not the screen going away.
  made.nextTurn(); hold = true;
  const walk = tool('draw').execute({ beats: [{ say: 'Click Format.', marks: [{ kind: 'target', at: { text: 'Format' } }], wait: 'click' }] }, { toolCallId: 'w1' });
  for (let i = 0; i < 100 && !made.ink.describe(); i++) await new Promise((r) => setTimeout(r, 20));
  made.ink.userClick({ x: 140, y: 112, role: 'AXButton', app: 'TextEdit', acts: true });
  assert.match(made.ink.describe(), /target “Format”/, 'kept while it waits for the click');
  made.ink.waitDone('w1', 1, 'clicked'); await walk;
  // The page itself changing counts, however it happened: a click on something script-driven (no link or button) that
  // then loads another page, keys or a swipe. Read as the browser's address, or the title in other apps.
  const front = (w) => fs.writeFileSync(path.join(dir, 'front.json'), JSON.stringify({ id: 7, app: 'Brave Browser', bounds: [0, 0, 800, 600], ...w }));
  // Gone within a few seconds (the helper is a separate process, slow on CI runners).
  const gone = async () => { for (let i = 0; i < 150 && made.ink.describe(); i++) await settle(100); return made.ink.describe(); };
  front({ title: 'Repo', url: 'https://github.com/a/b' });
  await graph();
  made.ink.userClick({ x: 300, y: 200, role: 'AXGroup', app: 'Brave Browser', acts: false });
  await settle(2000);
  assert.match(made.ink.describe(), /graph/, 'a click that changed nothing leaves it');
  made.ink.userClick({ x: 300, y: 200, role: 'AXGroup', app: 'Brave Browser', acts: false });
  front({ title: 'Repo', url: 'https://github.com/a/b/issues' });
  assert.equal(await gone(), '', 'a script-driven click that loaded another page');
  front({ title: 'Repo', url: 'https://github.com/a/b' });
  await graph();
  front({ title: 'Repo', url: 'https://github.com/a/b#readme' });
  await settle(2500);
  assert.match(made.ink.describe(), /graph/, 'a jump within the page is the same page');
  front({ title: 'Other', url: 'https://example.com/' });
  assert.equal(await gone(), '', 'another page with no click at all (keys, a swipe back)');
  front({ app: 'Mail', title: '(3) Inbox' });
  await graph();
  front({ app: 'Mail', title: '(4) Inbox' });
  await settle(2500);
  assert.match(made.ink.describe(), /graph/, 'an unread count in the title is the same view');
  front({ app: 'Mail', title: 'Sent' });
  assert.equal(await gone(), '', 'another mailbox (a new title) is a new view');
  // The page couldn't be read when it was drawn (a slow helper): the next look takes it as the start, so a later
  // change still clears it instead of never counting.
  front({ app: 'Mail', title: 'Inbox', slowFront: true }); // reading the page times out while it draws
  await graph();
  front({ app: 'Mail', title: 'Inbox' });
  await settle(2500);
  assert.match(made.ink.describe(), /graph/, 'still there');
  front({ app: 'Mail', title: 'Drafts' });
  assert.equal(await gone(), '', 'a change after a missed first read still clears it');
  fs.rmSync(path.join(dir, 'front.json'));
}
fs.rmSync(dir, { recursive: true, force: true });
console.log('hands tests: passed');

// Live "where am I" line: app, window title and page, without query strings; '' when nothing is known.
{
  const { frontLine } = await import('../tools.mjs');
  const l = frontLine({ app: 'Google Chrome', title: 'Inbox (3) - me@example.com - Gmail', url: 'https://mail.google.com/mail/u/0/?tab=rm&token=SECRET#inbox' }, 'Ken');
  assert.match(l, /Right now Ken is in Google Chrome — "Inbox \(3\) - me@example.com - Gmail" \(mail\.google\.com\/mail\/u\/0\)/);
  assert.match(l, /overrides any app or page from earlier/);
  assert.ok(!/SECRET|tab=/.test(l), 'query string dropped');
  assert.equal(frontLine({ app: 'Notes', url: 'file:///Users/x/secret.txt' }), '- Right now The user is in Notes. This was just checked and overrides any app or page from earlier messages; they can still ask about something elsewhere.');
  assert.equal(frontLine({}), '');
  assert.equal(frontLine(null), '');
  console.log('front line tests: passed');
}

