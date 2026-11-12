// Test the Anthropic SDK unbundle.
//
// The direct dependency on @anthropic-ai/claude-agent-sdk (the claude-code Node wrapper,
// whose license forbids reselling/intermediating Claude usage) has been removed from the
// shipped sidecar. It is only ever loaded by a dynamic `import()` in claudecode.mjs when the
// user actually runs "Sign in with Claude" (which also requires the Claude Code CLI binary,
// downloaded at runtime by gg-core). The shipped bundle therefore contains no claude-agent-sdk
// runtime code.
//
// Note: @anthropic-ai/sdk (v1.6.0) is still present in the bundle as a transitive dependency of
// @kenkaiiii/gg-* (AGPL), where gg-ai statically imports it for the API-key provider path. That
// remains under the gg-* AGPL terms and is not part of this unbundle.
//
// Run: npm run test:unbundle
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE = path.dirname(fileURLToPath(new URL('.', import.meta.url)));
const BUNDLE = path.join(SOURCE, 'dist/sidekick.mjs');

// 1) No static import of the SDK anywhere in the source tree.
const walk = async (dir, out) => {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory() && !e.name.startsWith('node_modules') && e.name !== 'dist') {
      await walk(p, out);
    } else if (e.isFile() && e.name.endsWith('.mjs')) {
      out.push(p);
    }
  }
};
const files = [];
await walk(SOURCE, files);
let staticFound = false;
for (const f of files) {
  const raw = await fs.readFile(f, 'utf8');
  if (/^\s*import[\s\S]*?\bfrom\s+['"]@anthropic-ai\/claude-agent-sdk['"]/.test(raw)) {
    console.error('static import still present:', f);
    staticFound = true;
  }
}
assert.ok(!staticFound, 'no static imports of @anthropic-ai/claude-agent-sdk in source');

// 2) The SDK enters only via a lazy dynamic import in claudecode.mjs.
const claudecode = await fs.readFile(path.join(SOURCE, 'claudecode.mjs'), 'utf8');
assert.match(claudecode, /await import\(['"]@anthropic-ai\/claude-agent-sdk['"]\)/,
  'SDK is loaded via dynamic import in claudecode.mjs');
assert.match(claudecode, /loadSdk/, 'a lazy loader exists');

// 3) The shipped bundle contains NO claude-agent-sdk runtime code or module paths.
const bundle = await fs.readFile(BUNDLE, 'utf8');
assert.equal(bundle.indexOf('node_modules/@anthropic-ai/claude-agent-sdk/'), -1,
  'bundle has no claude-agent-sdk module paths');
assert.equal(bundle.indexOf('mod = await import("node_modules/@anthropic-ai/claude-agent-sdk")'), -1,
  'bundle has no inline SDK module resolution');

// (Note: @anthropic-ai/sdk v1.6.0 is still bundled as a transitive dependency of @kenkaiiii/gg-*
// for the API-key provider path — see the file-level comment and THIRD_PARTY_NOTICES.)

// 4) package.json no longer lists the SDK as a runtime dependency of the shipped sidecar.
const pkg = JSON.parse(await fs.readFile(path.join(SOURCE, 'package.json'), 'utf8'));
assert.equal(pkg.dependencies?.['@anthropic-ai/claude-agent-sdk'], undefined,
  'SDK removed from dependencies');
assert.equal(pkg.devDependencies?.['@anthropic-ai/claude-agent-sdk'], '0.3.318',
  'SDK kept in devDependencies only');

// 5) bundle.sh marks the SDK external so it can never be bundled.
const sh = await fs.readFile(path.join(SOURCE, 'bundle.sh'), 'utf8');
assert.match(sh, /--external:@anthropic-ai\/claude-agent-sdk/, 'bundle.sh externalizes the SDK');

// 6) sdkAvailable() is exported and reflects whether the SDK can be imported.
const { sdkAvailable } = await import('../claudecode.mjs');
assert.equal(typeof sdkAvailable, 'function', 'sdkAvailable is exported');
try {
  await import('@anthropic-ai/claude-agent-sdk');
  assert.ok(await sdkAvailable(), 'sdkAvailable is true when the SDK is importable');
} catch {
  assert.ok(!(await sdkAvailable()), 'sdkAvailable is false when the SDK is absent');
}

console.log('unbundle checks ok');
