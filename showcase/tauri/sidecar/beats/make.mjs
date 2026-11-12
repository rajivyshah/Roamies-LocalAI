// Records the beats (speaker.mjs BEATS) in every look's voice and both paid Fish models, into beats/*.pcm + index.json,
// so the app ships them and never makes them at run time. 24 kHz from Fish itself (about half the size of 44.1, still
// full speech bandwidth); the overlay plays each chunk at its own rate. Needs the Fish Audio key in the Keychain (from the app).
//   node beats/make.mjs [--only <voiceId>]          re-run after changing BEATS or a look's voice
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_VOICE, FishVoice } from '../fish.mjs';
import { BEATS } from '../speaker.mjs';
import { createSecrets } from '../secrets.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HANDS = process.env.ROAMIES_HANDS || '/Applications/Roamies.app/Contents/MacOS/roamies-hands';
const MODELS = ['drama-3', 's2.1-pro'], RATE = 24000;
// Every look's voice, from the LOOKS table in sidekick.mjs (the default one is DEFAULT_VOICE).
const LOOK_VOICES = [DEFAULT_VOICE, ...new Set([...fs.readFileSync(path.join(HERE, '..', 'sidekick.mjs'), 'utf8').matchAll(/\['\w+', '[^']+', '([0-9a-f]{32})'\]/g)].map((m) => m[1]))];
const only = process.argv.includes('--only') ? process.argv[process.argv.indexOf('--only') + 1] : null;
const key = await createSecrets({ hands: HANDS }).get('fish-audio');
if (!key) { console.error('No Fish Audio key in the Keychain: add one in BitJarvis first.'); process.exit(1); }

// Trim silence at both ends (keeping a little), so a beat starts the moment it plays.
function trim(pcm) {
  const s = new Int16Array(pcm.buffer, pcm.byteOffset, pcm.byteLength >> 1), loud = 500, pad = Math.round(RATE * 0.04);
  let a = 0, b = s.length - 1;
  while (a < s.length && Math.abs(s[a]) < loud) a++;
  while (b > a && Math.abs(s[b]) < loud) b--;
  return Buffer.from(s.slice(Math.max(0, a - pad), Math.min(s.length, b + pad)).buffer);
}
const record = (voice, model, phrase) => new Promise((resolve, reject) => {
  const got = [];
  const v = new FishVoice({ key, voice, model, rate: RATE, onAudio: (p) => got.push(Buffer.from(p.buffer, p.byteOffset, p.byteLength)), onEnd: () => resolve(Buffer.concat(got)), onError: reject }).open();
  v.say(phrase); v.end();
});

const indexFile = path.join(HERE, 'index.json');
const index = fs.existsSync(indexFile) ? JSON.parse(fs.readFileSync(indexFile, 'utf8')) : { rate: RATE, sets: {} };
for (const voice of LOOK_VOICES) {
  if (only && voice !== only) continue;
  for (const model of MODELS) {
    const parts = [], set = {};
    let at = 0;
    for (const phrase of BEATS) {
      let pcm;
      for (let tries = 0; !pcm; tries++) { try { pcm = trim(await record(voice, model, phrase)); } catch (e) { if (tries >= 2) throw e; } }
      set[phrase] = [at, pcm.length]; parts.push(pcm); at += pcm.length;
    }
    const file = `${voice}.${model}.pcm`;
    fs.writeFileSync(path.join(HERE, file), Buffer.concat(parts));
    index.sets[`${voice}:${model}`] = { file, beats: set };
    console.log(`${file}: ${BEATS.length} beats, ${(at / 1024).toFixed(0)} KB, ${(at / 2 / RATE).toFixed(1)} s`);
  }
}
fs.writeFileSync(indexFile, JSON.stringify(index, null, 1) + '\n');
