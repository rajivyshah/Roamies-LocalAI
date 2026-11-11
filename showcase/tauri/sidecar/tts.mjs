// Voice engines: who speaks Roamies' replies.
//
// Fish Audio was the only one for a long time. The user can now pick Google Gemini's text-to-speech
// or any OpenAI-compatible speech endpoint (a local Kokoro, Piper, ...), and Roamies talks in that voice.
//
// Every engine has the same shape, so the speaker (speaker.mjs) never asks which one it has:
//   {
//     id, label,          // what the panel shows
//     rate,               // the PCM sample rate the engine's audio comes at
//     cues,               // 'fish' (it performs [cue] tags), 'style' (it takes a style prompt), false (no cues)
//     models, voices,     // [{id, name}] lists, or null when the user types them in
//     validModels,        // the model ids it accepts, or null for any
//     freeModel,          // the model to fall back to when the account has no credit (Fish only)
//     defaultModel, defaultVoice,
//     needsKey, needsUrl, // what it needs before it can speak at all
//     keyLabel, keySecret,// the key's name and where it's kept (the OS secret store)
//     prewarm,            // the "One sec." beats are made once, in the voice, so they play instantly
//     chain(pref),        // the models to try, in order, when one fails before any audio
//     resolve(pref, credit, current), // the model to use once the account is known
//     check(key, { url }),// { ok, credit } | { ok: false, reason: 'key' | 'network' | 'url' }
//     create({ key, model, voice, url, onAudio, onEnd, onError }), // one reply's voice
//   }
//
// A voice session is what create() returns: say(text) as sentences come, then end(); abort() stops at
// once. It calls onAudio(pcm, rate) with 16-bit mono PCM, onEnd() when it's done, onError(err) when it
// fails (err.heard says whether any audio had already arrived, so a caller can retry or not).
import { DEFAULT_VOICE, FISH_CHOICES, FISH_MODELS, FREE_MODEL, FishVoice, RATE, fishAccount } from './fish.mjs';
import { geminiEngine } from './tts-gemini.mjs';
import { openaiEngine } from './tts-openai.mjs';

export { parseWav, trimUrl, httpError } from './tts-shared.mjs';

// ---------- the Fish Audio engine (the one Roamies shipped with) ----------
// Its voices come from the look the user picked (sidekick.mjs), its models from the two it offers,
// and its account has credit that decides whether the paid models or the free tier are used.
export const fishEngine = ({ FishVoiceImpl = FishVoice, account = fishAccount } = {}) => ({
  id: 'fish',
  label: 'Fish Audio',
  rate: RATE,
  cues: 'fish',
  models: FISH_CHOICES,
  voices: null, // the look picks the voice
  validModels: FISH_MODELS,
  freeModel: FREE_MODEL,
  defaultModel: FISH_MODELS[0],
  defaultVoice: DEFAULT_VOICE,
  needsKey: true,
  needsUrl: false,
  keyLabel: 'Fish Audio',
  keySecret: 'fish-audio',
  prewarm: true, // the "One sec." beats are made once, in the voice, so they play instantly
  chain: (pref) => FISH_MODELS.slice(Math.max(0, FISH_MODELS.indexOf(pref))),
  resolve: (pref, credit, current) => (credit != null && credit <= 0.01 ? FREE_MODEL : current === FREE_MODEL ? pref : current),
  check: (key) => account(key),
  create: ({ key, model, voice, onAudio, onEnd, onError }) => new FishVoiceImpl({ key, model, voice, onAudio, onEnd, onError }),
});

// ---------- the registry ----------
const ENGINES = { fish: fishEngine(), gemini: geminiEngine(), openai: openaiEngine() };

/** Every engine the user can pick, in the order the panel lists them. */
export const ttsEngines = () => Object.values(ENGINES).map((e) => ({ id: e.id, label: e.label, needsKey: e.needsKey, needsUrl: e.needsUrl, keyLabel: e.keyLabel }));

/** One engine by id, or the Fish one when the id is unknown. */
export const ttsEngine = (id) => ENGINES[id] ?? ENGINES.fish;

export const ttsEngineIds = () => Object.keys(ENGINES);
