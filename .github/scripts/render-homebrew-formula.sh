#!/usr/bin/env bash
#
# Render the Homebrew formula for a release from .github/homebrew/strato.rb.tmpl.
#
#   render-homebrew-formula.sh <tag> <repo> <sidecar-dir> <output-path>
#
# <sidecar-dir> holds the release's `strato-cli-<os>-<arch>.tar.gz.sha256`
# sidecars, exactly as `gh release download` leaves them. Every platform the
# formula covers must have one: a partially-uploaded release is a failure, not
# something to render around.
#
# Shared by the release workflow's bump-homebrew-formula job and build.yaml's
# PR-time check, so the check validates the same rendering the release runs
# rather than a copy of it. CI only compiles Swift, and this template is never
# exercised by a PR otherwise — a typo in it would surface as a failed release
# job after the tag is already public.
set -euo pipefail

TAG="${1:?usage: render-homebrew-formula.sh <tag> <repo> <sidecar-dir> <output-path>}"
REPO="${2:?missing <repo>}"
SIDECAR_DIR="${3:?missing <sidecar-dir>}"
OUTPUT="${4:?missing <output-path>}"

TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../homebrew" && pwd)/strato.rb.tmpl"

# Homebrew versions carry no leading "v"; the tag does.
VERSION="${TAG#v}"

# One `sed` pass over the template rather than in-place edits: `sed -i` differs
# between GNU and BSD, and this should stay runnable on a maintainer's Mac.
sed_args=(-e "s|@@VERSION@@|${VERSION}|g")

# `gh release download` fails only when its pattern matched NOTHING, so a
# release missing one leg's assets still reaches this script; each platform's
# sidecar is therefore checked by name.
for platform in macos-arm64 linux-x86_64 linux-arm64; do
    asset="strato-cli-${platform}.tar.gz"
    sidecar="${SIDECAR_DIR}/${asset}.sha256"
    [ -f "$sidecar" ] || {
        echo "missing checksum sidecar for $asset on $TAG" >&2
        exit 1
    }
    sha="$(awk '{print $1}' "$sidecar")"
    [ -n "$sha" ] || {
        echo "empty checksum in $sidecar" >&2
        exit 1
    }
    # macos-arm64 -> MACOS_ARM64 (the underscore in x86_64 survives).
    token="$(printf '%s' "$platform" | tr 'a-z-' 'A-Z_')"
    url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
    sed_args+=(-e "s|@@${token}_URL@@|${url}|g" -e "s|@@${token}_SHA256@@|${sha}|g")
done

sed "${sed_args[@]}" "$TEMPLATE" > "$OUTPUT"

# A leftover placeholder means the template grew a token this script does not
# fill — catch it here, not as a 404 in someone's `brew install`.
if grep -n '@@' "$OUTPUT"; then
    echo "unsubstituted placeholders remain in the rendered formula" >&2
    exit 1
fi

# Cheap guard against a template edit that broke the Ruby.
ruby -c "$OUTPUT" > /dev/null

echo "rendered $OUTPUT for $TAG"
