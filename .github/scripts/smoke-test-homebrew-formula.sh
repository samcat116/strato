#!/usr/bin/env bash
#
# Install and test a rendered Homebrew formula, without publishing it.
#
#   smoke-test-homebrew-formula.sh <formula-path> <tap-repo> <label>
#
# <label> only names the staging commit, to say what is being tested.
#
# Proves the formula installs and that the binary runs, and it gives the
# formula's `test do` block its only caller — so a release that skipped the
# CompiledBuildInfo bake fails here instead of shipping a formula whose
# `strato --version` says "dev". Only the leg matching the host can be
# installed; verify-homebrew-assets.sh covers the other two.
#
# Requires brew, so callers must run it on macos-latest: GitHub removed
# Homebrew from the ubuntu-24.04 runner image.
#
# Shared by the release workflow's bump-homebrew-formula job and build.yaml's
# PR-time check, so the check exercises the same smoke test the release runs
# rather than a copy of it.
set -euo pipefail

FORMULA="${1:?usage: smoke-test-homebrew-formula.sh <formula-path> <tap-repo> <label>}"
TAP_REPO="${2:?missing <tap-repo>}"
LABEL="${3:?missing <label>}"

command -v brew > /dev/null 2>&1 || {
    echo "brew is not installed; this script needs a macOS runner" >&2
    exit 1
}

FORMULA="$(cd "$(dirname "$FORMULA")" && pwd)/$(basename "$FORMULA")"

# Homebrew refuses to install a formula that is not in a tap ("Homebrew
# requires formulae to be in a tap"), so stage the rendered file in a local tap
# under the name users actually type. Nothing is published from here. Naming
# the formula fully-qualified also satisfies the third-party tap trust check
# without a separate `brew trust`.
# stratocloud/homebrew-strato -> the tap name stratocloud/strato.
BREW_TAP="${TAP_REPO/homebrew-/}"
TAP_DIR="$(brew --repository)/Library/Taps/${TAP_REPO}"

# A real clone of the tap would shadow the formula under test with whatever is
# published, so it cannot just be written over — but it is also someone's
# actual tap, which this script has no business deleting. CI never has one; a
# maintainer running this on their Mac gets told what to do. A staging
# directory left by an earlier run has no remote and is safe to replace.
if [ -d "$TAP_DIR" ] && git -C "$TAP_DIR" remote get-url origin > /dev/null 2>&1; then
    echo "${TAP_DIR} is a real clone of ${TAP_REPO}, and would shadow the formula under test." >&2
    echo "Run \`brew untap ${BREW_TAP}\` and try again." >&2
    exit 1
fi
rm -rf "$TAP_DIR"
mkdir -p "$TAP_DIR/Formula"
cp "$FORMULA" "$TAP_DIR/Formula/strato.rb"

# A bare directory does load as a tap, but several brew code paths shell out to
# git for tap metadata and have historically failed with "not in a git
# directory" against one that isn't a repo (Homebrew/brew#10392). An empty repo
# costs milliseconds and removes the question from a step that gates a push.
git -C "$TAP_DIR" init -q
git -C "$TAP_DIR" add Formula/strato.rb
git -C "$TAP_DIR" -c user.name=ci -c user.email=ci@local commit -qm "stage ${LABEL}"

# Deliberately NOT setting HOMEBREW_NO_INSTALL_FROM_API: it governs only the
# homebrew/core and homebrew/cask taps, which it switches to "(large, slow)
# local checkouts" (`man brew`). Third-party taps are always read from disk, so
# it would buy nothing here and cost a homebrew/core clone on a runner image
# that ships API-only.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# --force so this reinstalls: strato can still be installed from an earlier run
# after its tap is gone (the guard above only rejects a live clone), and a
# plain `brew install` of an already-installed version is a no-op — the smoke
# test would pass without ever touching the formula under test.
brew install --formula --force "${BREW_TAP}/strato"
brew test "${BREW_TAP}/strato"
