# Contributing

Thanks for helping out. Bug reports, ideas and pull requests are all welcome.

This is **BitJarvis**, a fork of [Roamies](https://github.com/KenKaiii/Roamies) by Ken Kai. Changes here land in
BitJarvis; changes to the original app belong in [his repository](https://github.com/KenKaiii/Roamies). See
[NOTICE.md](NOTICE.md) for what this fork changed.

## Setup

With Rust, Node.js 22+, the [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/) and, on macOS,
the Xcode Command Line Tools installed:

```bash
git clone https://github.com/rajivyshah/Roamies-LocalAI.git
cd Roamies-LocalAI/showcase/tauri
(cd sidecar && npm ci && npm test)
./build.sh dev        # debug build
./build.sh            # release bundle for this OS
```

## Before you open a pull request

- Run `npm test` in `showcase/tauri/sidecar`.
- Run `shellcheck` on any shell script you changed.
- Keep CI (`.github/workflows/ci.yml` and `.github/workflows/ci-fork.yml`) green.
- Keep pull requests small and focused on one thing.

## The safety rule

Every tool that touches files, commands, URLs or other apps goes through
`showcase/tauri/sidecar/safety.mjs`. Add a test case in `showcase/tauri/sidecar/test/safety.test.mjs` with
every rule change.

## Security problems

Please don't open a public issue. Report them as described in [SECURITY.md](SECURITY.md).
