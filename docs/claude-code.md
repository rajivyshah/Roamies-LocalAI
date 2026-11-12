# Claude Code in BitJarvis, without the SDK in the bundle

## Summary

BitJarvis can run replies through **Claude Code** (the `"Sign in with Claude"` flow), but the
Anthropic Node SDK (`@anthropic-ai/claude-agent-sdk`) is **not shipped inside the BitJarvis sidecar
bundle**. It is a lazy, dynamic import that only loads when a user actually signs in with Claude and
runs that mode. If the SDK is missing, BitJarvis offers the API-key path as a clear fallback instead
of failing.

This is intentional: Anthropic's terms forbid reselling or intermediating Claude usage, so shipping
their proprietary SDK bundled in a product you sell was the one legal loose end. Removing it keeps
the product clean while leaving the feature available to anyone who installs the SDK themselves.

## How it works

1. **The CLI binary is already downloaded at runtime.** `gg-core` (the agent framework) downloads
   Anthropic's ~140 MB `claude` CLI on the user's machine at sign-in time. It already exists;
   BitJarvis does not ship it.

2. **The Node wrapper is an opt-in dynamic import.** In `showcase/tauri/sidecar/claudecode.mjs` the
   SDK used to be a static `import`. It is now loaded only by `await import('@anthropic-ai/
   claude-agent-sdk')` inside `loadSdk()`, which runs the first time Claude Code actually needs to
   start a session (in `warmSpare()` and `claudeCodeLoop()`).

3. **The build keeps it out for good.** `showcase/tauri/sidecar/bundle.sh` passes
   `--external:@anthropic-ai/claude-agent-sdk` to esbuild, and the package no longer lists it as a
   runtime dependency (it was moved to `devDependencies`, so it is used only for local development
   and testing).

4. **The shipped bundle is verified clean.** `test/unbundle.test.mjs` asserts that no static import
   of the SDK exists in the source, that the bundle has no `claude-agent-sdk` module paths or
   runtime code, and that package.json/bundle.sh are configured correctly. Run it with
   `npm run test:unbundle`.

## What the user sees

- **If the SDK is not installed** (the normal case for a buyer): signing in with Claude shows
  "Claude Code isn't available. Sign in with an API key instead (Model page), or install the Claude
  Code SDK yourself." The app continues normally with an API key.
- **If the user installs the SDK** (e.g. `npm install -g @anthropic-ai/claude-agent-sdk` and signs
  in with Claude): the dynamic import resolves, the agent runs through Claude Code as before, with
  warm spares and session resume unchanged.

## Where the work is

- `showcase/tauri/sidecar/claudecode.mjs` — lazy `loadSdk()` / `sdkAvailable()`, dynamic import in
  `warmSpare()` and `claudeCodeLoop()`.
- `showcase/tauri/sidecar/sidekick.mjs` — `claudeCodeRoute()` checks `sdkAvailable()` before
  routing to Claude Code; the sign-in error message guides users to the API-key fallback.
- `showcase/tauri/sidecar/package.json` — SDK moved from `dependencies` to `devDependencies`.
- `showcase/tauri/sidecar/bundle.sh` — `--external:@anthropic-ai/claude-agent-sdk`.
- `showcase/tauri/sidecar/test/unbundle.test.mjs` — source + bundle guard tests.

## Caveats

`@anthropic-ai/sdk` v1.6.0 (the HTTP client, not the agent SDK) is still present in the shipped
bundle as a transitive dependency of `@kenkaiiii/gg-*` (AGPL-3.0-only), which statically imports it
for the API-key provider path. That code remains under the gg-* AGPL terms and is not part of this
unbundle.
