# NOTICE

**BitJarvis** — a desktop companion by **Rajiv Shah**.

---

## 1. This program is free software

BitJarvis is licensed under the **GNU Affero General Public License, version 3** (AGPL-3.0). The full
licence text is in [LICENSE](LICENSE), and it applies to the whole program — the desktop shell, the
sidecar, the helpers, the web front end and the artwork in this repository.

You are free to use, study, change and redistribute BitJarvis, including for commercial purposes and
selling copies of it. If you convey a modified version, the AGPL requires you to pass on the same
freedom: the complete corresponding source of the version you distribute, under AGPL-3.0, plus the
licence and these notices. Section 6 of the licence says how.

You may not sell this software, or a modified version of it, as proprietary software, and you may not
add a closed-source module to it.

## 2. The original work

BitJarvis is a fork of **Roamies**, by **Ken Kai**.

| | |
| --- | --- |
| Original project | Roamies — <https://github.com/KenKaiii/Roamies> |
| Original author | Ken Kai (KenKaiii) |
| This fork | BitJarvis — <https://github.com/rajivyshah/Roamies-LocalAI> |
| This fork's author | Rajiv Shah |
| Licence (both) | AGPL-3.0-only, unchanged |

Copyright (C) 2026 Ken Kai — the original Roamies, from which this fork is derived. All original
copyright, patent, trademark and attribution notices in the source are preserved, and must stay.

Copyright (C) 2026 Rajiv Shah — the modifications described in section 3 below.

## 3. What this fork changed

BitJarvis is a modified version of Roamies. The changes are:

- **Rebrand.** The application is now called BitJarvis, by Rajiv Shah. The product name, bundle
  identifier (`com.rajivyshah.bitjarvis`), installer, window titles and in-app text were changed.
  The original name Roamies, the original author and the original licence remain credited here and
  in the app's About panel.
- **More voice engines.** Besides Fish Audio, replies can be spoken by **Gemini TTS**
  (`showcase/tauri/sidecar/tts-gemini.mjs`) and by **any OpenAI-compatible speech endpoint**
  (`showcase/tauri/sidecar/tts-openai.mjs`), chosen in the app's Voice page. The engine registry is
  `showcase/tauri/sidecar/tts.mjs`; Fish Audio's behaviour is unchanged.
- **Your own model servers.** The chat brain can run on a local, OpenAI-compatible endpoint — Ollama,
  LM Studio, or anything else you point it at (`showcase/tauri/sidecar/local.mjs`, and the "Your own
  models" group on the app's Model page). Endpoint keys are stored in the OS secret store.
- **The app updates itself from this fork.** The updater, its signing key and its release pipeline
  point at this repository (`rajivyshah/Roamies-LocalAI`), never at the upstream project's releases.
  See `docs/fork-maintenance.md`.
- **A panel that scrolls.** The settings panel is a fixed 560×560 window; pages taller than that now
  scroll instead of clipping.

Everything else — the agent framework, the hands and voice helpers, the overlay, the memory and
reminders, the onboarding — is Roamies as Ken Kai wrote it.

## 4. Source code

The complete source of any BitJarvis build is public in this repository, and every published release
carries a source archive of the exact commit it was built from
(`BitJarvis_<version>_source.zip` next to the installer).

| You want | Where |
| --- | --- |
| The source of the version you are running | The **Source code** link in the app's About panel points at that release |
| All the source, latest | <https://github.com/rajivyshah/Roamies-LocalAI> |
| The original project | <https://github.com/KenKaiii/Roamies> |

Building from source needs Node.js 22+, a Rust toolchain and the platform's build tools; the steps
are in [README.md](README.md) and `showcase/tauri/build.sh`.

## 5. Third-party components

BitJarvis builds on other people's work — the Rust and JavaScript libraries it depends on, the fonts
it draws with, the speech model it downloads, and Anthropic's Claude Agent SDK. Each one is used
under its own licence, and the full list, with links and licences, is in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). In short:

- Tauri, Node.js, zod, parakeet-rs — MIT / Apache-2.0 / similar permissive licences.
- `@kenkaiiii/gg-agent`, `gg-ai`, `gg-core` (Ken Kai's agent framework) — AGPL-3.0-only.
- Doto and Martian Mono fonts — SIL Open Font License 1.1. Natural Earth map data — public domain.
- NVIDIA Parakeet speech model — CC BY 4.0, downloaded at setup, not redistributed here.
- `@anthropic-ai/claude-agent-sdk` — **proprietary**, © Anthropic PBC. It is bundled in the sidecar and
  is used for the optional "Claude Code" mode. If you distribute BitJarvis, Anthropic's terms apply
  to that component: each end user authenticates with their own Anthropic key or subscription, and
  Claude usage must not be resold or intermediated on their behalf. See
  <https://code.claude.com/docs/en/legal-and-compliance>.

## 6. Trademarks

The AGPL grants permissions for the **software**, not for names, logos or other trademarks. "Roamies",
the Roamies artwork and Ken Kai's personal branding remain his. BitJarvis is not endorsed by, and is
not affiliated with, the original author beyond the attribution in this file and in the app's About
panel.

## 7. No warranty

BitJarvis is distributed under the AGPL, **without any warranty**, as stated in sections 15–17 of the
licence. There is no guarantee that it is fit for any particular purpose, and the authors accept no
liability for any claim or damage arising from its use.

---

*BitJarvis by Rajiv Shah. Based on Roamies by Ken Kai, AGPL-3.0.*
