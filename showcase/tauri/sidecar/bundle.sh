#!/bin/bash
# Bundles the sidekick brain into dist/ so the app ships one JS file instead of node_modules.
# Optional voice deps stay external (never loaded); zstd-wasm loads its .wasm from disk, so it's copied.
set -euo pipefail
cd "$(dirname "$0")"
# esbuild: $ESBUILD, then PATH, then the one `npm ci` installs here (a devDependency).
ES="${ESBUILD:-}"
if [ -z "$ES" ]; then
  ES="$(command -v esbuild || true)"
  [ -n "$ES" ] || { [ -x node_modules/.bin/esbuild ] && ES=node_modules/.bin/esbuild; } || true
fi
[ -x "$ES" ] || { echo "esbuild not found; set ESBUILD=/path/to/esbuild" >&2; exit 1; }
rm -rf dist && mkdir -p dist/node_modules/@bokuweb
"$ES" sidekick.mjs --bundle --platform=node --format=esm --target=node22 --outfile=dist/sidekick.mjs \
  --external:@huggingface/transformers --external:ogg-opus-decoder --external:@bokuweb/zstd-wasm \
  --external:@anthropic-ai/claude-agent-sdk \
  --banner:js="import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" \
  --log-level=warning
cp -R node_modules/@bokuweb/zstd-wasm dist/node_modules/@bokuweb/
# The recorded beats (beats/make.mjs): the audio and its index, not the script.
mkdir -p dist/beats && cp beats/index.json beats/*.pcm dist/beats/
echo '{"type":"module"}' > dist/package.json
