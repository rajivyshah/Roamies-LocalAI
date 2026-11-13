# Legal-readiness review — BitJarvis by Rajiv Shah

> This document is a **lay reading** of the licensing and trademark issues relevant to selling
> BitJarvis, prepared for discussion with counsel. It is not legal advice.

**Applies to:** the 0.1.38 release and later — the ones with Anthropic's Claude Agent SDK unbundled.
**Repository:** <https://github.com/rajivyshah/Roamies-LocalAI>
**Licence of the distributed program:** GNU Affero General Public License v3.0 only (AGPL-3.0-only)

## 1. How the product is structured

| Layer | What it is | Licence / owner |
| --- | --- | --- |
| The app itself | Desktop shell (Rust/Tauri), sidecar (Node), web front end, helpers, artwork | AGPL-3.0-only, © Rajiv Shah for the modifications |
| Original work | Roamies, by Ken Kai | AGPL-3.0-only, © Ken Kai |
| Agent framework | `@kenkaiiii/gg-agent`, `gg-ai`, `gg-core` 5.95.0 | AGPL-3.0-only, © Ken Kai |
| Other libs | Tauri, Node.js, zod, parakeet-rs, fonts, map data | MIT / Apache-2.0 / OFL-1.1 / public domain |
| Speech model | NVIDIA Parakeet TDT 0.6B v3 | CC BY 4.0, downloaded at setup, not redistributed |
| **Claude Agent SDK** | `@anthropic-ai/claude-agent-sdk` 0.3.318 | **Proprietary, © Anthropic PBC** |
| **Anthropic HTTP SDK** | `@anthropic-ai/sdk` 1.6.0 | **Proprietary, © Anthropic PBC** |

Key distribution fact: **every published BitJarvis release ships a source archive**
(`BitJarvis_<version>_source.zip`) of the exact commit it was built from, alongside the installer.
The source is also always available at the repository above. This is the core of the AGPL §6 source
offer.

## 2. AGPL-3.0 compliance (the sellable-part of the product)

AGPL-3.0 permits commercial use and selling of the software, provided that on conveyance the recipient
gets (a) the licence and full notices, and (b) the **complete corresponding source** of the version
distributed, under the same licence.

What we have in place:

- **NOTICE.md** in every release — credits Roamies / Ken Kai, describes this fork's changes, states
  the source location, lists third-party components, and disclaims trademark affiliation.
- **Every release archive is per-release.** `release-windows.yml` creates the archive from the exact
  release tag with `git archive`, so each zip is the precise build source, not the repo tip.
- **THIRD_PARTY_NOTICES.md** maps every dependency to its licence.
- **`@kenkaiiii/gg-*` (AGPL-3.0-only) is used intact.** We do not relicense any part of it.
- **New features stay AGPL.** Anything added to the sidecar, shell, helpers, or web front end is
  licensed AGPL-3.0-only; there is no closed-source module.

Open question for counsel: the AGPL's network-use trigger — because BitJarvis is a desktop app, the
network provisions are a minor concern, but if the updater or any component fetches modified source
over a network, confirm the corresponding-source offer extends appropriately.

## 3. Anthropic proprietary components — the main risk area

### 3.1 Claude Agent SDK (`claude-agent-sdk`, 0.3.318) — **removed from the bundle**

This is the one that matters most. Anthropic's terms forbid reselling or intermediating Claude usage
and forbid using Claude/Anthropic marks in a product name. Shipping their proprietary Node SDK
bundled inside a product you sell was the principal legal loose end.

**Fix in place:** the SDK is no longer a runtime dependency of the sidecar, no longer enters the
esbuild bundle (`bundle.sh` marks it `--external`), and is loaded only by a **lazy dynamic import**
in `showcase/tauri/sidecar/claudecode.mjs` when a user actually signs in with Claude. The Claude Code
CLI binary (~140 MB) is downloaded at runtime by gg-core from Anthropic — it was never redistributed.

Consequence: **the shipped BitJarvis bundle contains zero Anthropic code from this package.** The
feature remains available to anyone who installs the SDK themselves, and the default user who does
not is guided to a Claude API key. Tests guard this: `test/unbundle.test.mjs` asserts no static
import exists in the source, no `claude-agent-sdk` module path or runtime code appears in the bundle,
and package.json/bundle.sh are configured correctly.

### 3.2 Anthropic HTTP SDK (`@anthropic-ai/sdk`, 1.6.0) — **still bundled transitively**

The HTTP client is a **transitive dependency of `@kenkaiiii/gg-ai`** (AGPL), which statically
imports it for the API-key provider path. We cannot externalize it without breaking gg-ai, and
unbundling gg-ai's internal imports would be a much larger, riskier refactor outside the scope of
this work.

Status: it ships bundled, covered under the `gg-*` AGPL attribution. Flag for counsel: confirm
whether gg-ai's distribution of the Anthropic HTTP SDK is itself an Anthropic-terms problem, or
whether it falls within the existing gg-ai licence. This is a **pre-existing upstream issue**, not
something introduced by this fork.

### 3.3 Trademark / naming

- The product is called **BitJarvis**, by Rajiv Shah. "Claude" and "Anthropic" appear only in
  documentation and in the app's "Sign in with Claude" label for the optional feature — not in the
  product name, installer, or branding.
- "Roamies", its artwork and Ken Kai's branding are left untouched and are always attributed; the
  app never implies endorsement.
- Confirmed: Anthropic's terms prohibit using "Claude" in the **product name** — this fork does not.

## 4. Updater and updates branch

The self-updater reads `latest.json` from GitHub Releases, signed with the fork's Tauri key
(`showcase/tauri/sidecar` signing private key, SHA-256 `C5CEFF64D382504C8206DF3DD7833C5E297F2FEB5D43303D29783AF7E024C3DC`
— store this with your release records, not in chat). Releases are published under the fork's own
pipeline, so the update path is separate from Ken Kai's releases. The `updates` branch carries a
mirrored feed for failed GitHub links. This is an internal technical matter; no legal exposure beyond
normal software-update practice.

## 5. Pre-launch checklist for counsel

Before the first commercial sale, verify:

- [ ] AGPL §6 source offer is complete and accurate in the current release (source zip = exact build
      commit; NOTICE.md and THIRD_PARTY_NOTICES.md present in the zip and on GitHub).
- [ ] The shipped sidecar bundle contains no `claude-agent-sdk` runtime code — confirmed by
      `test/unbundle.test.mjs` (run on the tagged release commit).
- [ ] Any distribution of the `@anthropic-ai/sdk` 1.6.0 bundled by gg-ai is acceptable, or a plan is
      agreed for removing it.
- [ ] No Claude/Anthropic/Roamies marks are used in the product name, installer, or store listing;
      "BitJarvis" does not imply affiliation with Anthropic, Ken Kai, or Roamies.
- [ ] The AGPL licence file and copyright notices are preserved in the source archive.
- [ ] The per-release source offer satisfies the jurisdiction(s) where the product is sold (AGPL is
      the offer mechanism; confirm local compliance).
- [ ] Privacy: the app stores keys in the OS secret store, not in config files or logs —
      [PRIVACY.md](../PRIVACY.md) describes this.

## 6. Sources

- GNU AGPL-3.0 licence text: [LICENSE](../LICENSE)
- NOTICE / attribution: [NOTICE.md](../NOTICE.md)
- Third-party licences: [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)
- Claude Code legal: <https://code.claude.com/docs/en/legal-and-compliance>
- Unbundle implementation: [docs/claude-code.md](./claude-code.md), `test/unbundle.test.mjs`
- Fork README: [AGENTS.md](../AGENTS.md)
