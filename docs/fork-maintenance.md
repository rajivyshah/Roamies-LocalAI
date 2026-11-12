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

Your fork keeps the upstream release workflow, so a tag builds a signed installer and publishes it to
your fork, where the app's updater will find it:

```bash
git tag v0.1.35 && git push origin v0.1.35
```

Two things have to be in place first:

- **The signing key.** The updater only installs a build whose signature matches the public key in
  `showcase/tauri/src-tauri/tauri.conf.json` (`plugins.updater.pubkey`). Your fork uses its own key
  pair, and the private half belongs in your fork's Actions secret `TAURI_SIGNING_PRIVATE_KEY`
  (with `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` if it has a password) — never in the repo.
- **The feed.** The updater's endpoints point at your fork's releases, with your fork's `updates`
  branch as the second address. The `Update feed` workflow writes that branch when a release is
  published.

If you would rather not publish anything, the updater simply finds nothing and stays quiet: a failed
check is written to the log, not to the screen.

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
