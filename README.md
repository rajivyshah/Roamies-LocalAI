<p align="center">
  <img src="showcase/tauri/src-tauri/icons/128x128@2x.png" width="128" alt="BitJarvis icon">
</p>

<p align="center">
  <strong>BitJarvis — a little buddy that lives on your screen and keeps you on track.</strong>
</p>

<p align="center">
  <a href="https://github.com/rajivyshah/Roamies-LocalAI/releases/latest"><img src="https://img.shields.io/github/v/release/rajivyshah/Roamies-LocalAI?style=for-the-badge&label=Download&color=78ffe2" alt="BitJarvis desktop release"></a>
  <a href="https://github.com/rajivyshah/Roamies-LocalAI/releases"><img src="https://img.shields.io/github/downloads/rajivyshah/Roamies-LocalAI/total?style=for-the-badge&label=App%20downloads&color=2ecc71" alt="BitJarvis downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL--3.0-blue.svg?style=for-the-badge" alt="AGPL-3.0 License"></a>
</p>

**BitJarvis** is a desktop companion by **Rajiv Shah**.

It is a fork of **[Roamies](https://github.com/KenKaiii/Roamies)** by **Ken Kai** — the original project, under the
[AGPL-3.0 licence](LICENSE). Ken's work is the foundation: the agent, the little creatures on your screen, the
memory, the reminders, the hands that click things for you. BitJarvis adds more ways to talk and more ways to
run it, and it updates itself from this repository.

## What BitJarvis adds to Roamies

- **More voices.** Replies can be spoken by **Gemini TTS** or by **any OpenAI-compatible speech endpoint** —
  Kokoro, a local TTS server, anything that speaks `/v1/audio/speech`. Pick the engine, model and voice in the
  app's **Voice** page and hear a sample before you commit. Fish Audio still works exactly as it did.
- **Your own models.** The brain can run on a model server **on your own computer**: Ollama, LM Studio, or any
  OpenAI-compatible endpoint you point it at. Add the server in the **Model** page under "Your own models"; the
  app finds the models it hosts. Keys stay in your OS secret store.
- **It updates itself from this fork.** The in-app updater, its signing key and its release pipeline point at
  this repository — never at the upstream project's releases.

Everything else is Roamies as Ken Kai wrote it. [NOTICE.md](NOTICE.md) says exactly what changed, and
[docs/voice-providers.md](docs/voice-providers.md) is the guide to the voice engines.

## What it does

- **Talk, don't type.** Hold ⌃⌥ (Ctrl+Alt on Windows and Linux), say it, let go. Circle something with the cursor
  while you talk and it sees what you mean.
- **Or type.** Tap ⌥⌘ (Ctrl+Shift on Windows and Linux) and a small text field opens beside your cursor.
- **It talks back.** Spoken replies in its own voice, with real feeling.
- **It remembers.** What you said you'd do, reminders down to the second, and what matters to you.
- **It draws on your screen.** Rings the exact button to click and sketches answers beside what you're reading.
- **It does the clicking.** Opens apps, sites and files, and on macOS and Windows clicks or types in other apps.
- **Your subscriptions.** Sign in with Claude or ChatGPT, use an API key (Gemini, Grok, Kimi Code and more), or
  run it on your own server.

## Get started

**Windows:** [download the latest BitJarvis release](https://github.com/rajivyshah/Roamies-LocalAI/releases/latest)
and run the `.exe` installer. Requires Windows 10 or later. It isn't code-signed with a Windows certificate yet,
so Windows shows a SmartScreen warning the first time: click **More info**, then **Run anyway**. The in-app
updater verifies releases against this project's own signing key, so an update that arrives through the app is
the one that was published here.

**macOS and Linux:** this fork's release pipeline builds Windows installers. The original project builds the
macOS `.dmg` and the Linux `.deb`/`.rpm`/`.AppImage` — see
[Roamies' releases](https://github.com/KenKaiii/Roamies/releases). Those builds do not include BitJarvis's
additions.

**Build it yourself** — with Rust, Node.js 22+, the [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/)
and, on macOS, the Xcode Command Line Tools:

```bash
git clone https://github.com/rajivyshah/Roamies-LocalAI.git
cd Roamies-LocalAI/showcase/tauri
(cd sidecar && npm ci && npm test)
./build.sh dev        # debug build
./build.sh            # release bundle for this OS
```

Every published release carries the complete source of that exact build as
`BitJarvis_<version>_source.zip`, next to the installer. The **Source code** link in the app's About panel points
at the release you are running.

## Privacy

BitJarvis has no analytics, and nothing is collected by the developer. Your messages — and screenshots when you
ask about the screen — go to the AI provider you pick. [PRIVACY.md](PRIVACY.md) lists what is sent where.

## Licence

BitJarvis is free software under the **AGPL-3.0**. You can use, change and sell it; if you distribute it, you
must pass on the same freedom — the complete source of what you distribute, under the same licence. See
[LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). Third-party components and their licences are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

**Roamies** was created by **Ken Kai** — <https://github.com/KenKaiii/Roamies> — and this fork keeps his name,
his copyright and his licence wherever they belong. The parts that are ours are marked in
[NOTICE.md](NOTICE.md). BitJarvis is not endorsed by the original author.
