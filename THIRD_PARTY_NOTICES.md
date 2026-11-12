# Third-party notices

BitJarvis is licensed under [AGPL-3.0](LICENSE). It builds on the components below, each under its own license.
It is a fork of [Roamies](https://github.com/KenKaiii/Roamies) by Ken Kai — the same components, with the extra
voice engines and local-model endpoints this fork adds; see [NOTICE.md](NOTICE.md).

| Component | How it's used | License |
| --------- | ------------- | ------- |
| [Tauri](https://tauri.app) 2 (`tauri`, `tauri-build`) and plugins `tauri-plugin-single-instance`, `tauri-plugin-updater` | desktop shell, see `showcase/tauri/src-tauri/Cargo.toml` | MIT OR Apache-2.0 |
| [Node.js](https://nodejs.org) v24.22.2 | bundled runtime for the sidecar (version in `showcase/tauri/sidecar/fetch-node.sh`) | MIT |
| [@kenkaiiii/gg-agent](https://github.com/KenKaiii/gg-framework), gg-ai, gg-core 5.95.0 | agent framework in the sidecar | AGPL-3.0-only |
| [zod](https://zod.dev) 4.6.7 | schema validation in the sidecar | MIT |
| [@anthropic-ai/claude-agent-sdk](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk) 0.3.318 | Claude sign-in support in the sidecar; **not bundled in the shipped sidecar** — loaded by a lazy dynamic import in `showcase/tauri/sidecar/claudecode.mjs` when the user actually signs in with Claude, marked `--external` in `showcase/tauri/sidecar/bundle.sh`, and moved from `dependencies` to `devDependencies` in `package.json`. See [docs/claude-code.md](docs/claude-code.md) and `test/unbundle.test.mjs` | Proprietary: "© Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://code.claude.com/docs/en/legal-and-compliance." (not open source). Each end user authenticates with their own Anthropic key or subscription; Claude usage must not be resold or intermediated on their behalf |
| [@anthropic-ai/sdk](https://www.npmjs.com/package/@anthropic-ai/sdk) 1.6.0 | HTTP client statically imported by `@kenkaiiii/gg-ai` for the API-key provider path; **still bundled in the shipped sidecar** as a transitive dependency of gg-* | Proprietary: "© Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://code.claude.com/docs/en/legal-and-compliance." (not open source); bundled via gg-* under AGPL-3.0-only |
| Claude Code | downloaded at sign-in with Claude, not bundled | Anthropic's terms |
| [Doto](https://github.com/oliverlalan/Doto) and [Martian Mono](https://github.com/evilmartians/mono) fonts | text in the app | SIL Open Font License 1.1, texts in `showcase/onboarding/fonts/` |
| [Natural Earth](https://www.naturalearthdata.com) 1:110m countries | country outlines for map cards (`showcase/roamies/world.js`) and their names (`showcase/tauri/sidecar/countries.mjs`) | Public domain |
| [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [ONNX export by istupakov](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx) | Windows speech model, downloaded at setup, not bundled | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| [parakeet-rs](https://github.com/altunenes/parakeet-rs) 0.4.3 | runs the speech model in the Windows voice helper | MIT OR Apache-2.0 |

## Full dependency list

These are the main components. To see every dependency, including indirect ones:

```bash
cd showcase/tauri/sidecar && npm ls --all
cd showcase/tauri/src-tauri && cargo tree
cd showcase/tauri/src-tauri/voice-win && cargo tree
```
