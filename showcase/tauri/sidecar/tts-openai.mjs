// Any OpenAI-compatible speech endpoint: POST /v1/audio/speech, the way OpenAI does it.
//
// That one shape covers a lot of free voices: a local Kokoro-FastAPI (one Docker command, CPU only, no
// account), Piper's HTTP server, or OpenAI itself. The endpoint answers with WAV (or raw PCM); the WAV's
// own header says the sample rate, so whatever it plays at is what comes out.
//
// The base URL is the user's: "http://localhost:8880", "http://localhost:8880/v1" or a server of their own.
// The /v1 part is added when it's missing, so both work.
import { httpError, parseWav, trimUrl } from './tts-shared.mjs';
import { stripCues } from './speech.mjs';

const RATE = 24000; // what a raw PCM answer is at (OpenAI's own PCM output is 24 kHz)

/** The URLs a speech endpoint might live at, in the order to try them. */
export function speechUrls(url) {
  const base = trimUrl(url);
  if (!base) return [];
  return base.endsWith('/v1') ? [`${base}/audio/speech`] : [`${base}/v1/audio/speech`, `${base}/audio/speech`];
}

/** The voices an endpoint offers, if it lists them (Kokoro-FastAPI does). Empty when it doesn't. */
export async function listVoices(url, key, { fetchImpl = fetch } = {}) {
  const base = trimUrl(url);
  if (!base) return [];
  const roots = base.endsWith('/v1') ? [base] : [`${base}/v1`, base];
  for (const root of roots) {
    try {
      const res = await fetchImpl(`${root}/audio/voices`, { headers: key ? { authorization: `Bearer ${key}` } : {} });
      if (!res.ok) continue;
      const j = await res.json().catch(() => null);
      const list = Array.isArray(j?.voices) ? j.voices : Array.isArray(j?.data) ? j.data : null;
      if (!list) continue;
      return list.map((v) => ({ id: String(v.id ?? v.name ?? v), name: String(v.name ?? v.id ?? v) })).slice(0, 60);
    } catch { /* try the next one */ }
  }
  return [];
}

/** One reply's voice on an OpenAI-compatible endpoint: a request per sentence. */
export class OpenAiVoice {
  constructor({ key, model, voice, url, fetchImpl = fetch, onAudio, onEnd, onError, timeout = 30000 } = {}) {
    Object.assign(this, { key, model, voice, url, fetchImpl, onAudio, onEnd, onError, timeout });
    this.pending = 0;
    this.ended = false;
    this.done = false;
    this.heard = false;
    this.controller = null;
    this.working = null; // the URL that answered last time
  }

  open() { return this; }

  say(text) {
    if (this.done || this.ended || !text?.trim()) return;
    this.pending++;
    this.run(text);
  }

  async run(text) {
    try {
      // Fish's cues mean nothing here, and would be read out as brackets.
      const { pcm, rate } = await this.synth(stripCues(text));
      if (this.done) return;
      this.heard = true;
      this.onAudio?.(pcm, rate);
    } catch (e) {
      if (this.done) return;
      return this.fail(e);
    } finally {
      this.pending--;
      if (!this.pending && this.ended && !this.done) this.finish();
    }
  }

  async synth(text) {
    const body = {
      model: this.model || 'tts-1',
      input: text,
      voice: this.voice || 'alloy',
      response_format: 'wav',
      speed: 1,
    };
    const headers = { 'content-type': 'application/json' };
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    const candidates = this.working ? [this.working] : speechUrls(this.url);
    if (!candidates.length) throw Object.assign(new Error('no speech endpoint is set'), { reason: 'url' });
    let last = null;
    for (const target of candidates) {
      this.controller = new AbortController();
      let res;
      try {
        res = await this.fetchImpl(target, { method: 'POST', headers, body: JSON.stringify(body), signal: this.controller.signal });
      } catch (e) {
        last = Object.assign(new Error(`could not reach the speech endpoint: ${String(e?.message ?? e).slice(0, 80)}`), { reason: 'network' });
        continue;
      }
      if (res.status === 404 && !this.working) { last = Object.assign(new Error('the speech endpoint is not there'), { reason: 'url' }); continue; }
      if (!res.ok) throw await httpError(res, 'the speech endpoint');
      this.working = target;
      const bytes = new Uint8Array(await res.arrayBuffer());
      if (!bytes.length) throw new Error('the speech endpoint sent no audio');
      if (bytes[0] === 0x52 && bytes[1] === 0x49) return parseWav(bytes); // a WAV file: it says its own rate
      const type = String(res.headers?.get?.('content-type') ?? '');
      if (type.includes('mpeg') || type.includes('mp3') || type.includes('ogg') || type.includes('aac')) {
        throw new Error('that endpoint answered with MP3 or Ogg: ask it for wav or pcm instead');
      }
      return { pcm: bytes, rate: RATE };
    }
    throw last ?? new Error('could not reach the speech endpoint');
  }

  end() {
    if (this.done || this.ended) return;
    this.ended = true;
    if (!this.pending) this.finish();
  }

  abort() {
    if (this.done) return;
    this.done = true;
    try { this.controller?.abort(); } catch { /* already gone */ }
  }

  finish() {
    if (this.done) return;
    this.done = true;
    this.onEnd?.();
  }

  fail(err) {
    if (this.done) return;
    this.done = true;
    err.heard = this.heard;
    this.onError?.(err);
  }
}

export function openaiEngine({ fetchImpl = fetch } = {}) {
  return {
    id: 'openai',
    label: 'OpenAI-compatible endpoint',
    rate: RATE,
    cues: false, // no cues: they're dropped, so nothing is read out by mistake
    models: null, // the user types the model the server wants
    voices: null, // and the voice
    validModels: null,
    freeModel: null,
    defaultModel: 'tts-1',
    defaultVoice: 'alloy',
    needsKey: false, // a local server usually wants no key at all
    needsUrl: true,
    keyLabel: 'Endpoint key',
    keySecret: 'tts-custom',
    prewarm: false,
    chain: (pref) => [pref],
    resolve: (pref) => pref,
    check: async (key, { url, fetchImpl: f = fetchImpl } = {}) => {
      const base = trimUrl(url);
      if (!base) return { ok: false, reason: 'url' };
      const roots = base.endsWith('/v1') ? [base] : [`${base}/v1`, base];
      for (const root of roots) {
        try {
          const res = await f(`${root}/models`, { headers: key ? { authorization: `Bearer ${key}` } : {} });
          if (res.status === 401 || res.status === 403) return { ok: false, reason: 'key' };
          if (res.ok) return { ok: true, credit: null };
        } catch { /* try the next one */ }
      }
      return { ok: false, reason: 'network' };
    },
    create: ({ key, model, voice, url, onAudio, onEnd, onError }) => new OpenAiVoice({ key, model, voice, url, fetchImpl, onAudio, onEnd, onError }),
  };
}
