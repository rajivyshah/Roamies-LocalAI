# Voice providers (and where the local-AI-endpoint work fits)

This fork lets you pick who speaks Roamies' replies: **Fish Audio** (the default, unchanged),
**Google Gemini**, or **any OpenAI-compatible speech endpoint** — a local Kokoro or Piper, or a server
of your own. Fish Audio bills your account per character; the other two can cost nothing at all.

The chat side (which AI answers you) is a separate question, covered at the bottom: the framework Roamies
is built on already knows how to talk to a local model server, so that one is mostly wiring.

## What is where

| File | What it does |
| --- | --- |
| `showcase/tauri/sidecar/tts.mjs` | The registry: every engine has the same shape, and Fish is one of them |
| `showcase/tauri/sidecar/tts-shared.mjs` | Reading a WAV file, HTTP errors the speaker understands, URL tidying |
| `showcase/tauri/sidecar/tts-gemini.mjs` | Google's text-to-speech |
| `showcase/tauri/sidecar/tts-openai.mjs` | Any `POST /v1/audio/speech` endpoint (local or hosted) |
| `showcase/tauri/sidecar/speaker.mjs` | Speaks replies — now for any engine, not just Fish |
| `showcase/panel/panel.js` | The panel's Voice page: engine, model, voice, endpoint, key |
| `showcase/tauri/sidecar/test/tts.test.mjs` | Tests for all of the above (`npm test`) |

The audio path itself did not change. The sidecar has always sent 16-bit mono PCM with its sample rate
(`{ kind: 'speech', id, rate, pcm }`), and the overlay plays whatever rate it is told
(`showcase/roamies/voice-out.js`). That is why a new engine is a sidecar-only change: no Rust, no Swift.

## The engine shape

An engine is a plain object. `speaker.mjs` never asks which one it has.

```js
{
  id: 'gemini', label: 'Google Gemini',
  rate: 24000,                    // the sample rate its audio comes at
  cues: 'style',                  // 'fish' performs [cue] tags, 'style' takes a style prompt, false ignores them
  models: [{ id, name }],         // what the panel offers (null: the user types it)
  voices: [{ id, name }],
  validModels: ['gemini-3.8-flash-tts'],   // null: any model name is fine
  freeModel: null,                // Fish only: the tier to fall back to with no credit
  defaultModel, defaultVoice,
  needsKey: true, needsUrl: false,
  keyLabel: 'Google AI Studio', keySecret: 'tts-gemini',   // where the key is kept
  prewarm: false,                 // Fish only: the "One sec." beats are recorded once, in the voice
  chain: (pref) => [pref],        // the models to try, in order, when one fails before any audio
  resolve: (pref, credit, current) => pref,
  check: (key, { url }) => ({ ok: true, credit: null }),    // or { ok: false, reason: 'key' | 'network' | 'url' }
  create: ({ key, model, voice, url, onAudio, onEnd, onError }) => session,
}
```

A session is what `create` returns: `say(text)` as sentences come, then `end()`; `abort()` stops at once.
It calls `onAudio(pcm, rate)` with 16-bit mono PCM, `onEnd()` when it is done, and `onError(err)` when it
fails (`err.heard` says whether any audio had already arrived, so a caller knows whether a retry would
repeat itself).

## Using each engine

### Google Gemini

1. Panel → **Voice** → *Voice engine* → **Google Gemini**.
2. Pick a model (`gemini-3.8-flash-tts` and `gemini-3.8-flash-lite-tts` are the current ones) and a voice
   (Kore, Puck, Charon and 27 more).
3. Add a key. Gemini uses the **Google AI Studio key you already saved for chat** if there is one, so
   usually there is nothing to add. A separate key for speech can be added on the Voice page; it is kept
   in the OS secret store (Keychain / DPAPI / keyring), never in the config file.

One request per sentence, sent as soon as the sentence is ready, so the reply starts talking while the rest
is still being written. Gemini answers with base64 PCM (16-bit, 24 kHz, mono), which is exactly what the
overlay plays.

Roamies' voice cues (`[warm] Hello`) are Fish's syntax. With Gemini they become style prompts —
"in a warm tone" — and a cue Gemini has no word for is dropped rather than read out.

### A local voice (free, offline)

Anything that speaks OpenAI's speech API works. The best-known free one is Kokoro-82M:

```bash
docker run -p 8880:8880 ghcr.io/remsky/kokoro-fastapi-cpu:latest
```

Then in the panel: **Voice engine** → **OpenAI-compatible endpoint**, and set

- **Speech endpoint**: `http://localhost:8880` (the `/v1` is added for you if it is missing)
- **Model**: `kokoro`
- **Voice**: `af_heart` (or any other Kokoro voice)

"Ask the endpoint for its voices" lists what it has, when it lists them. No key is needed for a local
server, and nothing leaves the machine. Piper's HTTP server and other OpenAI-compatible servers work the
same way.

The endpoint is asked for **WAV** (or raw PCM), never MP3: a WAV says its own sample rate, so nothing has
to be decoded, and MP3 would need a decoder the app doesn't ship.

### Fish Audio

Unchanged: the same models, the same credit check, the same fallback to the free tier, the same recorded
"beats". The Fish tests (`test/fish.test.mjs`, `test/speaker.test.mjs`) are untouched and still pass.

## Adding another engine

1. Write `showcase/tauri/sidecar/tts-<name>.mjs` with a `create` function returning a session.
2. Add it to the registry in `tts.mjs` (`fish`, `gemini`, `openai`).
3. Add it to `test/tts.test.mjs`.

Nothing else needs to change: the panel's Voice page, the key handling and the "play a sample" button all
read the engine's own list of models and voices.

## Keys, and where they live

| Engine | Where the key is kept |
| --- | --- |
| Fish Audio | `fish-audio` in the OS secret store (Keychain / DPAPI / keyring) |
| Gemini | `tts-gemini` in the OS secret store, or the AI Studio key already in `~/.gg/auth.json` |
| OpenAI-compatible | `tts-custom` in the OS secret store (optional: most local servers want none) |

The config file (`~/.gg/sidekick.json`) only ever holds the engine name, the model, the voice and the
endpoint URL — never a key.

## The chat side: your own local model endpoint

Roamies' brain is a [gg-framework](https://github.com/KenKaiii/gg-framework) agent, and the framework
already supports local model servers — Roamies just never asks for them. In `@kenkaiiii/gg-core` 5.95.0
(the version this repo pins) there is:

- `discoverLocalModels()` / `probeEndpoint()` — finds models on an Ollama, LM Studio, llama.cpp or vLLM
  server, or on any URL you give it
- `LocalEndpoint` — `{ id, label, baseUrl, kind: 'ollama' | 'lmstudio' | 'llamacpp' | 'vllm' | 'custom' }`
- `formatLocalModelId()` — model ids look like `local/ollama/qwen3:8b`
- `AuthStorage.setLocalEndpoint(id, baseUrl, apiKey)` — stores the endpoint's credential in `~/.gg/auth.json`
- a `"local"` provider in `@kenkaiiii/gg-ai` — the OpenAI-compatible transport

Putting it together is roughly:

```js
const { models } = await discoverLocalModels([{ id: 'mybox', label: 'My box', baseUrl: 'http://127.0.0.1:11434/v1', kind: 'ollama' }]);
const infos = models.map((m) => toModelInfo(m, endpoint));
registerRuntimeModels(infos);
setProviderCatalog('local', infos);
await auth.setLocalEndpoint('mybox', 'http://127.0.0.1:11434/v1');   // the credential carries the base URL
```

After that `getModel('local/mybox/qwen3:8b')` resolves and `getAuthStorageKeys` returns `local:mybox`, so
the existing `resolveCredentials({ storageKeys })` path in `sidekick.mjs` picks it up with no new plumbing —
the same way a local model id resolves today in GG Coder. What is left is the panel's Model page: an
"Add endpoint" row, the probed model list, and letting `config.model` be a `local/...` id.

That part is not implemented in this fork yet.

## Fork setup, and staying in sync with upstream

This work is a fork of [KenKaiii/Roamies](https://github.com/KenKaiii/Roamies) (AGPL-3.0). Nothing here is
committed to upstream, and nothing upstream is rewritten: the changes are additive, so a rebase is mostly
about the sidecar's pinned npm versions.

```bash
git clone https://github.com/<you>/Roamies.git
cd Roamies
git remote add upstream https://github.com/KenKaiii/Roamies.git
git fetch upstream && git rebase upstream/main
```

Upstream bumps `@kenkaiiii/gg-core` often, so after a rebase: `cd showcase/tauri/sidecar && npm ci && npm test`.

If you ever distribute a build of this fork, AGPL-3.0 asks you to publish the source of that build under
the same licence. Using it for yourself needs nothing.

### Building it

The same as upstream: Rust, Node.js 22+, the Tauri prerequisites, and (on Windows) MSVC Build Tools.
`build.sh` is a bash script, so run it under Git Bash or WSL on Windows.

```bash
cd showcase/tauri/sidecar && npm ci && npm test   # the tests first
cd .. && ../build.sh dev                            # debug build
./build.sh                                          # release bundle for this OS
```

## Known limits

- Gemini is one request per sentence, so the first syllable waits for the whole sentence to be synthesised
  (roughly 0.3–0.8 s). Fish streams word by word.
- The recorded "beats" (the "One sec." lines) are Fish recordings. Other engines say them live, so they
  cost one request each and are a touch slower.
- Only Fish understands Roamies' full cue vocabulary. Gemini gets the moods and tones as style prompts;
  a plain OpenAI-compatible endpoint gets no cues at all.
- An endpoint that answers with MP3 is refused, with a note to ask it for WAV or PCM instead.
