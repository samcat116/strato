#!/usr/bin/env bash
#
# Publish a rendered Homebrew formula to the tap repository.
#
#   TAP_TOKEN=... push-homebrew-formula.sh <tap-repo> <formula-path> <version> <source-ref>
#
# <source-ref> is only used in the commit body, to say which release produced
# the formula.
#
# Exits 0 without pushing when there is nothing to do: the tap already carries
# this exact formula (a re-run), or it is already on a newer version (a
# backport). Both are normal outcomes, not failures.
set -euo pipefail

TAP_REPO="${1:?usage: push-homebrew-formula.sh <tap-repo> <formula-path> <version> <source-ref>}"
FORMULA="${2:?missing <formula-path>}"
VERSION="${3:?missing <version>}"
SOURCE_REF="${4:?missing <source-ref>}"
: "${TAP_TOKEN:?TAP_TOKEN must be set}"

FORMULA="$(cd "$(dirname "$FORMULA")" && pwd)/$(basename "$FORMULA")"
# Explicit template rather than a bare `mktemp -d`: the default template is a
# GNU coreutils extension. Current macOS supplies one too — this script pushed
# v0.1.1 to the tap from a Mac — but the release job runs on macos-latest now,
# and the template is portable to both. (`-t prefix` is not: GNU rejects it.)
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/strato-tap.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# One attempt at the whole clone-to-push sequence. Run in a subshell so `cd`
# and a partial clone cannot leak into the next attempt.
attempt() (
    set -e
    rm -rf "$WORKDIR/tap"
    # Works on a tap with no commits yet: git takes the branch name from the
    # remote's advertised HEAD (its default branch) even when there is nothing
    # to check out, so the push below creates the branch `brew tap` will clone
    # rather than whatever the runner's init.defaultBranch happens to be.
    git clone --depth 1 \
        "https://x-access-token:${TAP_TOKEN}@github.com/${TAP_REPO}.git" "$WORKDIR/tap"
    cd "$WORKDIR/tap"

    # A backport — tagging v1.1.4 after v1.2.0 already shipped — must not walk
    # the public install path backwards. The no-op check below cannot catch
    # that: the formula content genuinely differs. Compare versions instead.
    #
    # `sort -V` is not a GNU-ism to root out: BSD sort implements it, verified
    # on macOS. And if it ever were missing, `set -o pipefail` is inherited
    # here, so the assignment fails and the attempt fails with it — the guard
    # breaks closed (job fails) rather than open (silent tap downgrade).
    if [ -f Formula/strato.rb ]; then
        current="$(sed -n 's/^  version "\(.*\)"$/\1/p' Formula/strato.rb)"
        newest="$(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -1)"
        if [ -n "$current" ] && [ "$current" != "$VERSION" ] && [ "$newest" = "$current" ]; then
            echo "tap is at $current; not downgrading it to $VERSION"
            exit 0
        fi
    fi

    mkdir -p Formula
    cp "$FORMULA" Formula/strato.rb
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add Formula/strato.rb
    # Re-running for a version already in the tap is a no-op, not an
    # empty-commit failure.
    if git diff --cached --quiet; then
        echo "tap already carries strato $VERSION; nothing to push"
        exit 0
    fi
    git commit -m "strato ${VERSION}" -m "Released from ${SOURCE_REF}."
    git push origin HEAD
    echo "pushed strato $VERSION to $TAP_REPO"
)

# Retry by starting over rather than rebasing: releases are serialized per tag,
# not across tags, so another release can land in the tap between the clone and
# the push. A fresh clone re-runs the downgrade guard against what is actually
# there now, where a rebase would replay this formula over a newer one.
#
# `set +e` around the call, rather than `attempt || ...`: bash disables `set -e`
# inside a subshell that is an operand of `&&`/`||` or an `if` condition — even
# one that sets `-e` itself — so a failing command mid-attempt would be ignored
# and the attempt would "succeed".
for try in 1 2 3; do
    set +e
    attempt
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        exit 0
    fi
    echo "tap update attempt ${try} failed (status ${status})" >&2
    sleep 5
done

echo "could not update ${TAP_REPO} after 3 attempts" >&2
exit 1
