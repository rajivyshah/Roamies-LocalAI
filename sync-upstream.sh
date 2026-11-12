#!/bin/bash
# Brings Ken's upstream changes into this fork, checks them, and builds a new installer.
#
#   ./sync-upstream.sh              fetch -> rebase -> test -> build the installer (nothing is installed)
#   ./sync-upstream.sh --merge      the same, but merge upstream/main instead of rebasing onto it
#   ./sync-upstream.sh --install    also run the installer (Windows) or open the disk image (macOS)
#   ./sync-upstream.sh --push       also push this branch to origin
#
# The tests run before the build on purpose: if one of Ken's changes breaks the voice engines or the
# local model endpoint, the script stops there, and nothing reaches the installed app. To go back to
# where you were, the SHA it prints at the end takes you there: git reset --hard <that SHA>.
#
# Ken's repo is the "upstream" remote; this fork is "origin".
set -euo pipefail
cd "$(dirname "$0")"

MERGE=0; INSTALL=0; PUSH=0
for a in "$@"; do
  case "$a" in
    --merge) MERGE=1 ;;
    --install) INSTALL=1 ;;
    --push) PUSH=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BEFORE="$(git rev-parse HEAD)"

echo "==> Working tree"
if [ -n "$(git status --porcelain)" ]; then
  echo "There are uncommitted changes. Commit or stash them first (git status)." >&2
  exit 1
fi

echo "==> Fetching Ken's latest (upstream/main) and your fork (origin)"
git fetch upstream main
git fetch origin

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "Already up to date with upstream/main; nothing to merge."
else
  COUNT="$(git rev-list --count HEAD..upstream/main)"
  echo "==> ${COUNT} new commit(s) from Ken"
  git log --oneline HEAD..upstream/main | head -20
  if [ "$MERGE" = "1" ]; then
    echo "==> Merging upstream/main into ${BRANCH}"
    git merge --no-edit upstream/main || {
      echo "Merge conflict. Fix it (git status), then 'git commit' to finish, or 'git merge --abort' to stop." >&2
      exit 1
    }
  else
    echo "==> Rebasing ${BRANCH} onto upstream/main"
    git rebase upstream/main || {
      echo "Conflict while rebasing. Fix it (git status), then 'git rebase --continue', or 'git rebase --abort' to stop." >&2
      exit 1
    }
  fi
fi

echo "==> Installing the sidecar's dependencies"
(cd showcase/tauri/sidecar && npm ci)

echo "==> Running the tests"
if ! (cd showcase/tauri/sidecar && npm test); then
  echo "The tests failed, so nothing was built and nothing was installed." >&2
  echo "Go back to where you were with: git reset --hard ${BEFORE}" >&2
  exit 1
fi

echo "==> Building the installer"
# The updater's signed artifacts need this fork's private key. Without one the build still produces the
# installer; it just skips the .sig file that the in-app updater reads. The key lives outside the repo
# (see docs/fork-maintenance.md); TAURI_SIGNING_PRIVATE_KEY overrides it.
KEY_FILE="${TAURI_SIGNING_PRIVATE_KEY:-$HOME/.roamies-fork/tauri.key}"
if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ] && [ -f "$KEY_FILE" ]; then
  TAURI_SIGNING_PRIVATE_KEY="$KEY_FILE"
  export TAURI_SIGNING_PRIVATE_KEY
  echo "Signing with ${KEY_FILE}"
fi
BUILD_ARGS=()
if [ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]; then
  CONF="$(mktemp -t tauri-fork-config.XXXXXX.json)"
  echo '{"bundle":{"createUpdaterArtifacts":false}}' > "$CONF"
  BUILD_ARGS=(--config "$(cygpath -w "$CONF" 2>/dev/null || echo "$CONF")")
fi
(cd showcase/tauri && TAURI_BUNDLES=nsis ./build.sh release "${BUILD_ARGS[@]}")

echo
echo "==> Done"
echo "Started at:  ${BEFORE}"
echo "Now at:      $(git rev-parse HEAD)"
if [ "$MERGE" = "1" ]; then
  echo "Undo with:   git reset --hard ${BEFORE}"
else
  echo "Undo with:   git reset --hard ${BEFORE}   (a rebase rewrites the branch, so this drops Ken's commits too)"
fi

if [ "$INSTALL" = "1" ]; then
  echo "==> Installing"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # Close the running app first: the installer replaces its files.
      taskkill //IM roamies.exe //F >/dev/null 2>&1 || true
      SETUP="$(ls -1 showcase/tauri/src-tauri/target/release/bundle/nsis/*-setup.exe 2>/dev/null | head -1)"
      [ -n "$SETUP" ] || { echo "No installer found." >&2; exit 1; }
      echo "Running ${SETUP} (it will ask you to confirm)"
      "$SETUP" ;;
    Darwin)
      DMG="$(ls -1 showcase/tauri/src-tauri/target/release/bundle/dmg/*.dmg 2>/dev/null | head -1)"
      [ -n "$DMG" ] || { echo "No disk image found." >&2; exit 1; }
      open "$DMG"; echo "Drag Roamies onto Applications to finish." ;;
    *) echo "Install it by hand from showcase/tauri/src-tauri/target/release/bundle/." ;;
  esac
fi

if [ "$PUSH" = "1" ]; then
  echo "==> Pushing to origin/${BRANCH}"
  git push origin "$BRANCH"
fi

echo "Your branch now has Ken's changes and the tests passed."
