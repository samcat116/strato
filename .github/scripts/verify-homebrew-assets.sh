#!/usr/bin/env bash
#
# Verify a rendered Homebrew formula against the release it points at.
#
#   verify-homebrew-assets.sh <formula-path> <repo> <tag>
#
# For every platform the formula covers, reads the sha256 the formula pairs
# with that platform's url and compares it against the bytes GitHub actually
# serves.
#
# The brew smoke test can only install the leg matching the runner it is on,
# which leaves the other two legs' checksums verified by nothing: a
# token-substitution bug that crossed linux-x86_64's sha onto linux-arm64 would
# reach the tap and break `brew install` for those users. This closes that.
#
# Reads each sha back OUT of the rendered formula rather than re-reading the
# sidecar it came from. The sidecars are the rendering's input, so comparing
# against them would only prove the release is self-consistent — not that the
# rendering put the right sha next to the right url.
#
# Shared by the release workflow's bump-homebrew-formula job and build.yaml's
# PR-time check, so the check validates the same verification the release runs
# rather than a copy of it.
set -euo pipefail

FORMULA="${1:?usage: verify-homebrew-assets.sh <formula-path> <repo> <tag>}"
REPO="${2:?missing <repo>}"
TAG="${3:?missing <tag>}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/strato-verify.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

# sha256sum on Linux, shasum on macOS — this runs on both.
sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

for platform in macos-arm64 linux-x86_64 linux-arm64; do
    asset="strato-cli-${platform}.tar.gz"
    url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"

    # The first sha256 line following THIS platform's url. Homebrew formulae
    # always order a spec's url before its checksum, and `homepage` is not an
    # `url` line, so it cannot be matched by accident.
    sha="$(awk -v url="$url" '
        $1 == "url" && $2 == "\""url"\"" { found = 1; next }
        found && $1 == "sha256" { gsub(/"/, "", $2); print $2; exit }
    ' "$FORMULA")"
    [ -n "$sha" ] || {
        echo "no sha256 is paired with ${asset} in ${FORMULA}" >&2
        exit 1
    }

    curl -fsSL --retry 3 -o "$WORKDIR/$asset" "$url"
    got="$(sha256_of "$WORKDIR/$asset")"
    rm -f "$WORKDIR/$asset"
    [ "$sha" = "$got" ] || {
        echo "${asset}: the formula says ${sha}, ${TAG} serves ${got}" >&2
        exit 1
    }
    echo "verified $asset"
done
