// Google Gemini's text-to-speech: Roamies' replies in a Gemini voice.
//
// One request per sentence, sent as soon as the sentence is ready, so the reply starts talking while the
// rest is still being written. Gemini answers with the audio as base64 PCM (16-bit, 24 kHz, mono), which
// is exactly what the overlay plays.
//
// Fish's voice cues ("[warm] Hello") are Gemini's style prompts instead: the cue becomes "in a warm tone"
// in front of the sentence. Cues Gemini has no word for are dropped.
import { GEMINI_API_KEY_BASE_URL } from '@kenkaiiii/gg-core';
import { VOICE_CUES } from './speech.mjs';

const API = GEMINI_API_KEY_BASE_URL;

/** Gemini's own error, with the reason the speaker understands. A refused key is a 400 here, not a 401. */
async function geminiError(res) {
  let detail = '';
  try { detail = await res.text(); } catch { /* no body */ }
  const low = detail.toLowerCase();
  const badKey = res.status === 401 || res.status === 403
    || low.includes('api key not valid') || low.includes('api_key_invalid')
    || low.includes('invalid api key') || low.includes('permission_denied');
  const err = new Error(detail ? `Gemini said ${res.status}: ${detail.slice(0, 200)}` : `Gemini said ${res.status}`);
  err.reason = badKey ? 'key' : res.status === 404 ? 'url' : 'network';
  return err;
}

export const GEMINI_MODELS = [
  { id: 'gemini-3.8-flash-tts', name: 'Gemini 3.8 Flash TTS' },
  { id: 'gemini-3.8-flash-lite-tts', name: 'Gemini 3.8 Flash-Lite TTS' },
  { id: 'gemini-3.1-flash-tts-preview', name: 'Gemini 3.1 Flash TTS (preview)' },
  { id: 'gemini-2.5-flash-preview-tts', name: 'Gemini 2.5 Flash TTS (preview)' },
  { id: 'gemini-2.5-pro-preview-tts', name: 'Gemini 2.5 Pro TTS (preview)' },
];

export const GEMINI_VOICES = [
  'Zephyr', 'Puck', 'Charon', 'Kore', 'Fenrir', 'Leda', 'Orus', 'Aoede', 'Callirrhoe', 'Autonoe',
  'Enceladus', 'Iapetus', 'Umbriel', 'Algieba', 'Despina', 'Erinome', 'Algenib', 'Rasalgethi', 'Laomedeia',
  'Achernar', 'Alnilam', 'Schedar', 'Gacrux', 'Pulcherrima', 'Achird', 'Zubenelgenubi', 'Vindemiatrix',
  'Sadachbia', 'Sadaltager', 'Sulafat',
].map((id) => ({ id, name: id }));

const RATE = 24000;

// A cue in Gemini's words. Sounds get their own little map; the moods and tones are close enough as they are.
const SOUNDS = {
  laughing: 'with a laugh', chuckling: 'with a light chuckle', sobbing: 'with a sob', 'crying loudly': 'crying out',
  sighing: 'with a sigh', groaning: 'with a groan', panting: 'out of breath', gasping: 'gasping',
  yawning: 'yawning', snoring: 'snoring', 'clear throat': 'clearing their throat',
};

/** What a Fish cue asks of Gemini: a style for the sentence, or nothing (the cue is dropped). */
export function styleFor(cue) {
  const c = String(cue ?? '').toLowerCase().replace(/^\[|\]$/g, '').trim();
  if (!c) return null;
  if (SOUNDS[c]) return SOUNDS[c];
  if (VOICE_CUES.tones.includes(c)) return `in a ${c} tone`;
  if (VOICE_CUES.emotions.includes(c)) return `in a ${c} tone`;
  if (VOICE_CUES.sounds.includes(c)) return `with a ${c.replace(/ing$/, '')}`;
  return null;
}

/** The sentence without its cue, and the style the cue asks for. */
export function splitCue(text) {
  const m = /^\[([^\]]{1,40})\]\s*/.exec(String(text ?? ''));
  if (!m) return { text: String(text ?? '').trim(), style: null };
  const rest = String(text ?? '').slice(m[0].length).trim();
  return { text: rest, style: styleFor(m[1]) };
}

/** One reply's Gemini voice: a request per sentence, the audio as it arrives. */
export class GeminiVoice {
  constructor({ key, model, voice, fetchImpl = fetch, onAudio, onEnd, onError, timeout = 20000 } = {}) {
    Object.assign(this, { key, model, voice, fetchImpl, onAudio, onEnd, onError, timeout });
    this.pending = 0;
    this.ended = false;
    this.done = false;
    this.heard = false;
    this.controller = null;
  }

  open() { return this; }

  say(text) {
    if (this.done || this.ended || !text?.trim()) return;
    this.pending++;
    this.run(text);
  }

  async run(text) {
    try {
      const { pcm } = await this.synth(text);
      if (this.done) return;
      this.heard = true;
      this.onAudio?.(pcm, RATE);
    } catch (e) {
      if (this.done) return;
      return this.fail(e);
    } finally {
      this.pending--;
      if (!this.pending && this.ended && !this.done) this.finish();
    }
  }

  /** The sentence as Gemini should say it: with the cue turned into a style prompt. */
  prompt(text) {
    const { text: body, style } = splitCue(text);
    return style ? `Say ${style}: ${body}` : body;
  }

  async synth(text) {
    const body = {
      contents: [{ parts: [{ text: this.prompt(text) }] }],
      generationConfig: {
        responseModalities: ['AUDIO'],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: this.voice || GEMINI_VOICES[0].id } } },
      },
    };
    this.controller = new AbortController();
    const res = await this.fetchImpl(`${API}/models/${encodeURIComponent(this.model)}:generateContent`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': this.key ?? '' },
      body: JSON.stringify(body),
      signal: this.controller.signal,
    });
    if (!res.ok) throw await geminiError(res);
    const j = await res.json().catch(() => null);
    const part = j?.candidates?.[0]?.content?.parts?.find((p) => p?.inlineData?.data);
    if (!part) throw new Error('Gemini sent no audio back');
    const raw = typeof part.inlineData.data === 'string' ? Buffer.from(part.inlineData.data, 'base64') : Buffer.from(part.inlineData.data ?? []);
    if (!raw.length) throw new Error('Gemini sent no audio back');
    return { pcm: new Uint8Array(raw) };
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

export function geminiEngine({ fetchImpl = fetch } = {}) {
  return {
    id: 'gemini',
    label: 'Google Gemini',
    rate: RATE,
    cues: 'style',
    models: GEMINI_MODELS,
    voices: GEMINI_VOICES,
    validModels: GEMINI_MODELS.map((m) => m.id),
    freeModel: null,
    defaultModel: GEMINI_MODELS[0].id,
    defaultVoice: GEMINI_VOICES[0].id,
    needsKey: true,
    needsUrl: false,
    keyLabel: 'Google AI Studio',
    keySecret: 'tts-gemini',
    prewarm: false, // the beats are said live, one request each
    chain: (pref) => [pref],
    resolve: (pref) => pref,
    check: async (key, { fetchImpl: f = fetchImpl } = {}) => {
      if (!key) return { ok: false, reason: 'key' };
      try {
        const res = await f(`${API}/models?pageSize=1`, { headers: { 'x-goog-api-key': key } });
        if (res.ok) return { ok: true, credit: null };
        const err = await geminiError(res);
        return { ok: false, reason: err.reason };
      } catch {
        return { ok: false, reason: 'network' };
      }
    },
    create: ({ key, model, voice, onAudio, onEnd, onError }) => new GeminiVoice({ key, model, voice, fetchImpl, onAudio, onEnd, onError }),
  };
}
