// The bits every voice engine needs: reading a WAV file, turning an HTTP failure into an error the
// speaker understands, and tidying a base URL. Kept apart from the engines so none of them import
// each other.

/** A WAV file's audio as 16-bit mono PCM, with the rate it was recorded at. Throws on anything else. */
export function parseWav(input) {
  const b = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (b.length < 44 || b[0] !== 0x52 || b[1] !== 0x49 || b[2] !== 0x46 || b[3] !== 0x46) throw new Error('that is not a WAV file');
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const tag = (at) => String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3]);
  let at = 12, fmt = null, data = null;
  while (at + 8 <= b.length) {
    const id = tag(at), size = view.getUint32(at + 4, true);
    if (id === 'fmt ' && at + 24 <= b.length) {
      fmt = { format: view.getUint16(at + 8, true), channels: view.getUint16(at + 10, true), rate: view.getUint32(at + 12, true), bits: view.getUint16(at + 22, true) };
    } else if (id === 'data') {
      data = { at: at + 8, size: Math.min(size, b.length - at - 8) };
    }
    at += 8 + size + (size % 2); // chunks are word-aligned
  }
  if (!fmt || !data) throw new Error('that WAV file has no audio in it');
  if (!fmt.rate || fmt.rate < 8000 || fmt.rate > 192000) throw new Error('that WAV file has an odd sample rate');
  const pcm = toMono16(b, data.at, data.size, fmt);
  return { pcm, rate: fmt.rate };
}

/** Any PCM in a WAV file, as 16-bit mono little-endian. */
function toMono16(b, at, size, fmt) {
  const { channels, bits, format } = fmt;
  const bytes = bits >> 3;
  const frames = Math.floor(size / (bytes * channels));
  const out = new Uint8Array(frames * 2);
  const view = new DataView(b.buffer, b.byteOffset, b.byteLength);
  for (let f = 0; f < frames; f++) {
    let sum = 0;
    for (let c = 0; c < channels; c++) {
      const p = at + (f * channels + c) * bytes;
      let v = 0;
      if (format === 3 && bits === 32) v = Math.max(-1, Math.min(1, view.getFloat32(p, true))) * 32767;
      else if (bits === 8) v = (b[p] - 128) * 256;
      else if (bits === 16) v = view.getInt16(p, true);
      else if (bits === 24) v = ((b[p + 1] << 8) | b[p + 2]) << 8 >> 8; // the top 16 bits
      else if (bits === 32) v = view.getInt32(p, true) >> 16;
      else throw new Error(`that WAV file is ${bits}-bit, which I can't read`);
      sum += v;
    }
    const mono = Math.round(sum / channels);
    out[f * 2] = mono & 0xff;
    out[f * 2 + 1] = (mono >> 8) & 0xff;
  }
  return out;
}

/** The base URL of an endpoint, without a trailing slash. */
export const trimUrl = (url) => String(url ?? '').trim().replace(/\/+$/, '');

/** An HTTP failure as an error the speaker understands: 'key' (the key is wrong), 'url' or 'network'. */
export async function httpError(res, what = 'it') {
  let detail = '';
  try { detail = (await res.text()).slice(0, 200); } catch { /* no body */ }
  const err = new Error(detail ? `${what} said ${res.status}: ${detail}` : `${what} said ${res.status}`);
  err.reason = res.status === 401 || res.status === 403 ? 'key' : res.status === 404 ? 'url' : 'network';
  return err;
}
