// The voice engines: Fish still behaves as it always did, Gemini and a custom OpenAI-compatible
// endpoint speak the same shape as Fish does, and the cues that only Fish understands never get read out.
import assert from 'node:assert/strict';
import { createSpeaker } from '../speaker.mjs';
import { ttsEngine, ttsEngines, fishEngine } from '../tts.mjs';
import { GEMINI_VOICES, GeminiVoice, splitCue, styleFor } from '../tts-gemini.mjs';
import { OpenAiVoice, listVoices, speechUrls } from '../tts-openai.mjs';
import { parseWav } from '../tts-shared.mjs';
import { stripCues } from '../speech.mjs';

const tick = () => new Promise((r) => setTimeout(r, 0));

// ---------- the registry ----------
{
  const ids = ttsEngines().map((e) => e.id);
  assert.deepEqual(ids, ['fish', 'gemini', 'openai'], 'three engines to pick from');
  for (const e of ttsEngines()) assert.ok(e.label && e.needsKey !== undefined && e.needsUrl !== undefined, 'each engine says what it needs');
  assert.equal(ttsEngine('gemini').id, 'gemini');
  assert.equal(ttsEngine('nope').id, 'fish', 'an unknown id falls back to Fish');
}
console.log('engine registry: passed');

// ---------- Fish is still Fish ----------
{
  const e = fishEngine();
  assert.equal(e.rate, 44100);
  assert.equal(e.cues, 'fish');
  assert.deepEqual(e.chain('drama-3'), ['drama-3', 's2.1-pro', 's2.1-pro-free'], 'the same model order as before');
  assert.equal(e.resolve('drama-3', 0, 'drama-3'), 's2.1-pro-free', 'no credit means the free tier');
  assert.equal(e.resolve('drama-3', 5, 's2.1-pro-free'), 'drama-3', 'credit again means the best model');
}
console.log('fish engine: passed');

// ---------- a WAV file ----------
{
  // 3 frames, stereo, 16-bit: 100,200 in the left channel and 300,400 in the right.
  const pcm = Buffer.alloc(44 + 12);
  pcm.write('RIFF', 0); pcm.writeUInt32LE(36 + 12, 4); pcm.write('WAVE', 8);
  pcm.write('fmt ', 12); pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(2, 22);
  pcm.writeUInt32LE(24000, 24); pcm.writeUInt32LE(24000 * 4, 28); pcm.writeUInt16LE(4, 32); pcm.writeUInt16LE(16, 34);
  pcm.write('data', 36); pcm.writeUInt32LE(12, 40);
  [100, 200, 300, 400, -100, -200].forEach((v, i) => pcm.writeInt16LE(v, 44 + i * 2));
  const { pcm: out, rate } = parseWav(new Uint8Array(pcm));
  assert.equal(rate, 24000, 'the WAV says its own rate');
  assert.equal(out.length, 6, 'three mono frames');
  assert.deepEqual([...out.slice(0, 2)], [150 & 0xff, (150 >> 8) & 0xff], 'stereo is mixed down to mono');
  assert.throws(() => parseWav(new Uint8Array([1, 2, 3])), /not a WAV file/);
}
console.log('wav reading: passed');

// ---------- the cues only Fish understands ----------
{
  assert.equal(stripCues('[warm] Hello there.'), 'Hello there.');
  assert.equal(stripCues('Hello [emphasis] there.'), 'Hello there.');
  assert.equal(stripCues('[chuckling] Heh, fair enough.'), 'Heh, fair enough.');
  assert.equal(stripCues('Nothing to strip here.'), 'Nothing to strip here.');
  assert.equal(styleFor('warm'), 'in a warm tone');
  assert.equal(styleFor('chuckling'), 'with a light chuckle');
  assert.equal(styleFor('not a cue'), null);
  assert.deepEqual(splitCue('[warm] Hello there.'), { text: 'Hello there.', style: 'in a warm tone' });
  assert.deepEqual(splitCue('Hello there.'), { text: 'Hello there.', style: null });
}
console.log('voice cues: passed');

// ---------- Gemini ----------
{
  // A fake Gemini: it answers with base64 PCM, and records what it was asked for.
  const asked = [];
  const fakeFetch = async (url, opts) => {
    asked.push({ url, body: JSON.parse(opts.body) });
    return { ok: true, status: 200, json: async () => ({ candidates: [{ content: { parts: [{ inlineData: { data: Buffer.from([1, 0, 2, 0]).toString('base64') } }] } }] }) };
  };
  const engine = ttsEngine('gemini');
  const out = [];
  const v = new GeminiVoice({ key: 'k', model: 'gemini-3.8-flash-tts', voice: 'Kore', fetchImpl: fakeFetch, onAudio: (pcm, rate) => out.push({ pcm: [...pcm], rate }), onEnd: () => out.push({ end: true }) });
  v.say('[warm] Hello there.');
  await tick(); await tick();
  assert.equal(out[0].rate, 24000, 'Gemini audio is 24 kHz');
  assert.deepEqual(out[0].pcm, [1, 0, 2, 0]);
  v.end(); await tick();
  assert.deepEqual(out.at(-1), { end: true });
  assert.ok(asked[0].url.includes('gemini-3.8-flash-tts:generateContent'), 'the model is in the URL');
  assert.equal(asked[0].body.generationConfig.responseModalities[0], 'AUDIO');
  assert.equal(asked[0].body.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName, 'Kore');
  assert.ok(asked[0].body.contents[0].parts[0].text.includes('Hello there.'), 'the sentence is sent');
  assert.ok(!asked[0].body.contents[0].parts[0].text.includes('[warm]'), 'the cue became a style, not a bracket');
}
{ // A refused key is a 'key' problem, so the app says the key is wrong.
  const fakeFetch = async () => ({ ok: false, status: 401, text: async () => 'bad key' });
  const engine = ttsEngine('gemini');
  const a = await engine.check('k', { fetchImpl: fakeFetch });
  assert.deepEqual(a, { ok: false, reason: 'key' });
}
{ // Gemini says a refused key is a 400, not a 401: it still has to read as a wrong key.
  const fakeFetch = async () => ({ ok: false, status: 400, text: async () => JSON.stringify({ error: { code: 400, message: 'API key not valid. Please pass a valid API key.', status: 'INVALID_ARGUMENT' } }) });
  const a = await ttsEngine('gemini').check('k', { fetchImpl: fakeFetch });
  assert.deepEqual(a, { ok: false, reason: 'key' }, 'the key is the problem, not the network');
  const err = await new GeminiVoice({ key: 'k', model: 'gemini-3.8-flash-tts', voice: 'Kore', fetchImpl: fakeFetch, onError: (e) => out.push(e) }).synth('Hi.').catch((e) => e);
  assert.equal(err.reason, 'key');
}
{ // No key: not ready.
  const a = await ttsEngine('gemini').check('', { fetchImpl: async () => ({ ok: true, status: 200 }) });
  assert.deepEqual(a, { ok: false, reason: 'key' });
}
{ // The voices are the ones Gemini offers.
  assert.ok(GEMINI_VOICES.length >= 25, 'plenty of voices');
  assert.ok(GEMINI_VOICES.some((v) => v.id === 'Kore'));
}
console.log('gemini engine: passed');

// ---------- an OpenAI-compatible endpoint ----------
{
  assert.deepEqual(speechUrls('http://localhost:8880'), ['http://localhost:8880/v1/audio/speech', 'http://localhost:8880/audio/speech']);
  assert.deepEqual(speechUrls('http://localhost:8880/v1/'), ['http://localhost:8880/v1/audio/speech']);
  assert.deepEqual(speechUrls(''), []);
}
{
  // A fake endpoint that answers with a WAV file.
  const wav = Buffer.alloc(44 + 4);
  wav.write('RIFF', 0); wav.writeUInt32LE(48, 4); wav.write('WAVE', 8);
  wav.write('fmt ', 12); wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(22050, 24); wav.writeUInt32LE(22050 * 2, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
  wav.write('data', 36); wav.writeUInt32LE(4, 40); wav.writeInt16LE(7, 44); wav.writeInt16LE(9, 46);
  const asked = [];
  const fakeFetch = async (url, opts) => {
    asked.push({ url, body: JSON.parse(opts.body) });
    return { ok: true, status: 200, headers: { get: () => 'audio/wav' }, arrayBuffer: async () => wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength) };
  };
  const out = [];
  const v = new OpenAiVoice({ key: '', model: 'kokoro', voice: 'af_heart', url: 'http://localhost:8880', fetchImpl: fakeFetch, onAudio: (pcm, rate) => out.push({ pcm: [...pcm], rate }), onEnd: () => out.push({ end: true }) });
  v.say('Hello there.');
  await tick(); await tick();
  assert.equal(asked[0].url, 'http://localhost:8880/v1/audio/speech', 'the /v1 is added when it is missing');
  assert.equal(asked[0].body.input, 'Hello there.');
  assert.equal(asked[0].body.response_format, 'wav', 'WAV is asked for, so no decoder is needed');
  assert.equal(out[0].rate, 22050, "the WAV's own rate is kept");
  assert.deepEqual(out[0].pcm, [7, 0, 9, 0]);
  v.end(); await tick();
  assert.deepEqual(out.at(-1), { end: true });
}
{
  // A 401 is a key problem; a missing endpoint is a URL problem.
  const engine = ttsEngine('openai');
  const key = await engine.check('k', { url: 'http://localhost:8880', fetchImpl: async () => ({ ok: false, status: 401 }) });
  assert.deepEqual(key, { ok: false, reason: 'key' });
  const none = await engine.check('k', { url: '', fetchImpl: async () => ({ ok: true }) });
  assert.deepEqual(none, { ok: false, reason: 'url' });
  const good = await engine.check('', { url: 'http://localhost:8880', fetchImpl: async () => ({ ok: true, status: 200 }) });
  assert.deepEqual(good, { ok: true, credit: null }, 'a local server usually wants no key');
}
{
  // The voices an endpoint lists, when it lists them.
  const list = await listVoices('http://localhost:8880', '', { fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({ voices: [{ id: 'af_heart', name: 'Heart' }] }) }) });
  assert.deepEqual(list, [{ id: 'af_heart', name: 'Heart' }]);
  const none = await listVoices('http://localhost:8880', '', { fetchImpl: async () => ({ ok: false, status: 404 }) });
  assert.deepEqual(none, [], 'an endpoint that lists nothing');
}
console.log('openai-compatible engine: passed');

// ---------- the speaker with another engine ----------
{
  // A fake engine: it records what it was asked to say, and plays a tone.
  const made = [];
  const fake = {
    id: 'fake', label: 'Fake', rate: 24000, cues: false,
    models: [{ id: 'm1', name: 'M1' }], voices: null, validModels: ['m1'], freeModel: null,
    defaultModel: 'm1', defaultVoice: 'v1', needsKey: true, needsUrl: false, keyLabel: 'Fake', keySecret: 'fake',
    prewarm: false, chain: (pref) => [pref], resolve: (pref) => pref,
    check: async () => ({ ok: true, credit: null }),
    create: ({ key, model, voice, onAudio, onEnd, onError }) => {
      const v = { said: [], ended: false, aborted: false, key, model, voice,
        open: () => v, say: (s) => v.said.push(s), end: () => { v.ended = true; }, abort: () => { v.aborted = true; },
        onAudio: (p) => onAudio(p, 24000), onEnd: () => onEnd(), onError: (e) => onError(e) };
      made.push(v);
      return v;
    },
  };
  const out = [];
  const sp = createSpeaker({ emit: (m) => out.push(m), onProblem: (p) => out.push({ problem: p }), provider: fake });
  assert.equal(sp.on, false, 'no key yet');
  assert.equal(sp.start(), null, 'nothing to say without a key');
  sp.setKey('k');
  assert.equal(sp.on, true);
  const r = sp.start();
  r.say('[warm] Hello there.');
  assert.deepEqual(made[0].said, ['Hello there.'], 'the cue is gone: this engine does not act on it');
  made[0].onAudio(new Uint8Array([3, 0]));
  assert.deepEqual(out.at(-1), { kind: 'speech', id: r.id, rate: 24000, pcm: Buffer.from([3, 0]).toString('base64') }, 'the audio carries the engine rate');
  made[0].onEnd();
  assert.deepEqual(out.at(-1), { kind: 'speech', id: r.id, end: true, chars: 12 });
}
{ // Switching engines resets the key, the model and the voice.
  const sp = createSpeaker({ emit: () => {} });
  sp.setKey('k');
  assert.equal(sp.provider, 'fish');
  sp.setProvider('gemini');
  assert.equal(sp.provider, 'gemini');
  assert.equal(sp.on, false, 'the new engine has no key yet');
  assert.equal(sp.pick, 'gemini-3.8-flash-tts', 'it starts on its own default model');
  sp.setProvider('nope');
  assert.equal(sp.provider, 'fish', 'an unknown engine falls back to Fish');
}
console.log('speaker with other engines: passed');

console.log('tts tests: passed');
