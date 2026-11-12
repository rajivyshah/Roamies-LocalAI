# Keeping your fork alive

Your fork (`rajivyshah/Roamies-LocalAI`) has two features Ken's build does not: the extra voice
engines (Gemini, any OpenAI-compatible endpoint) and your own model servers (Ollama, LM Studio,
anything OpenAI-compatible). This page is the playbook for keeping both of those **and** Ken's new
features, without either one breaking the other.

## The two update paths

There are two ways a new build can reach your computer, and they come from different places:

| | Where it comes from | How it arrives |
| --- | --- | --- |
| **Ken's features** | `upstream/main` in git | You pull them, the tests run, you build and install |
| **The app updating itself** | a release on **your** fork | Signed and installed by the app, like before |

The important part is that the app's own updater never looks at Ken's releases any more. Ken's next
release cannot silently replace your build and take the voice engines and the local endpoint with it.
The only thing that can change your app is a build **you** made.

## Getting Ken's features in

One command, from the root of the clone:

```bash
./sync-upstream.sh
```

It fetches `upstream/main`, rebases your branch onto it (add `--merge` to merge instead), installs
the sidecar's dependencies, runs the whole test suite, and builds a fresh installer. It stops at the
installer on purpose — **nothing is installed until you say so**:

```bash
./sync-upstream.sh --install   # also runs the installer (Windows) / opens the disk image (macOS)
./sync-upstream.sh --push      # also pushes your branch to your fork
```

The order matters. The tests run *before* the build, so if one of Ken's changes breaks something of
yours, you find out before it reaches the installed app. When that happens the script prints the SHA
you were on, and this puts you back:

```bash
git reset --hard <that SHA>
```

## When there is a conflict

Your changes are mostly in **new files**, which git never conflicts over:

| Yours | Shared with Ken (may conflict) |
| --- | --- |
| `showcase/tauri/sidecar/tts.mjs` | `showcase/tauri/sidecar/sidekick.mjs` |
| `showcase/tauri/sidecar/tts-gemini.mjs` | `showcase/panel/panel.js` |
| `showcase/tauri/sidecar/tts-openai.mjs` | `showcase/panel/panel.css` |
| `showcase/tauri/sidecar/tts-shared.mjs` | `showcase/onboarding/onboarding.js` |
| `showcase/tauri/sidecar/local.mjs` | `showcase/tauri/sidecar/package.json` (the test list) |
| `showcase/tauri/sidecar/test/tts.test.mjs` | `showcase/tauri/src-tauri/tauri.conf.json` (the updater) |
| `showcase/tauri/sidecar/test/local.test.mjs` | |

So a conflict is nearly always in one of the four shared files, and nearly always small: the voice
engine's wiring in `sidekick.mjs`, the Voice page in `panel.js`, the panel's scrolling in
`panel.css`, and the onboarding line in `onboarding.js`. Resolve it by keeping **both** sides — Ken's
new behaviour and ours — and then let the tests tell you if you got it wrong.

The tests that guard this are `test/tts.test.mjs` and `test/local.test.mjs`; they are part of
`npm test`, so the script runs them for you. If Ken changes the way the panel or the speaker is
wired, those tests fail loudly instead of the app quietly losing a feature.

## Publishing your own releases

Your fork keeps the upstream release workflow, plus two of its own. `release-windows.yml` builds the
Windows installer, signs it with your key, publishes it to your fork and writes the `latest.json` the
updater reads. `ci-fork.yml` runs the tests and a build on every branch, so a change that came in
from upstream is checked before it is released.

> A fork does **not** run the workflows it inherits from the repository it was forked from: only the
> workflows this fork adds itself (with their own file names) are active. That is why the release and
> the CI above are files of their own, and why the release writes the `updates` branch itself instead
> of leaving it to upstream's `update-feed.yml`.

To publish one:

```bash
# 1. bump the version, so the updater sees a newer one than the app has
#    (showcase/tauri/src-tauri/tauri.conf.json)
# 2. tag it and push the tag
git tag fork-v0.1.35 && git push origin fork-v0.1.35
```

The tag is `fork-v...` on purpose: upstream's `release.yml` (kept untouched, so a rebase stays
painless) also builds macOS and Linux, and a fork has no Apple certificate. The two workflows
therefore never run on the same tag.

Two things have to be in place first:

- **The signing key in GitHub.** The updater only installs a build whose signature matches the public
  key in `showcase/tauri/src-tauri/tauri.conf.json` (`plugins.updater.pubkey`) — which is already
  your fork's key. The private half belongs in your fork's Actions secret `TAURI_SIGNING_PRIVATE_KEY`
  (the whole contents of `~/.roamies-fork/tauri.key`), with `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` only
  if the key has a password. Add it under **Settings → Secrets and variables → Actions → New
  repository secret**. Never in the repo.
- **The key on this machine.** `~/.roamies-fork/tauri.key` is what `sync-upstream.sh` signs local
  builds with. Back it up somewhere safe: without it you cannot sign an update, and the app cannot
  install one.

If you would rather not publish anything, the updater simply finds nothing and stays quiet: a failed
check is written to the log, never to the screen.

## The licence

Roamies is AGPL-3.0, and that stays true of your fork. Using it for yourself needs nothing. If you
hand a build to anyone else, you must publish that build's source under the same licence — your fork
*is* that source, as long as the "Source code" link in the app points at it (it does).

## Where things live on your machine

| | |
| --- | --- |
| Your settings, keys and memory | `~/.gg/` — `sidekick.json` (settings), `auth.json` (sign-ins), shared with GG Coder |
| Your endpoint keys | the OS secret store (Keychain / DPAPI / keyring), never in a file |
| The installed app | `C:\Users\<you>\AppData\Local\Roamies` (Windows), `/Applications/Roamies.app` (macOS) |
| The build in this clone | `showcase/tauri/src-tauri/target/release/bundle/nsis/` (Windows), `.../dmg/` (macOS) |
| The signing key | outside the repo, e.g. `~/.roamies-fork/tauri.key`, backed up somewhere safe |
