#!/usr/bin/env bash
# CI-only publisher. All builds/probes finish before creating a draft release.
set -euo pipefail
: "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY:?}"
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 1
tag="main-${GITHUB_SHA:0:12}"
cp deploy/agent/install.sh deploy/agent/single-nic-discover.py agent-downloads/
files=(agent-downloads/*.tar.gz agent-downloads/*.sha256
       agent-downloads/agent-manifest.json agent-downloads/install.sh
       agent-downloads/single-nic-discover.py)
if ! state=$(gh release view "$tag" --json isDraft --jq .isDraft); then
  cat > agent-downloads/notes.md <<EOF
Bare-host Linux agent for commit $GITHUB_SHA. See agent-manifest.json for
architecture, checksum, embedded identity and workload wire version. These
agent-only archives use the existing updater; they need no Swift toolchain.

Use install.sh --version $tag with your reviewed enrollment command. This
prerelease does not replace the stable latest release. Review wire compatibility
and the update bridge before assigning it to an enrolled agent.

single-nic-discover.py collects read-only evidence only. Management-NIC
migration is not implemented; do not attach a live management NIC to OVS.
EOF
  gh release create "$tag" --target "$GITHUB_SHA" --title "Agent $tag" \
    --draft --prerelease --latest=false --notes-file agent-downloads/notes.md
  state=true
fi
# Draft releases may not create their tag until publication. Check both the
# declared draft target and any already existing tag before uploading.
refs=$(gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$tag" --jq '.[].ref')
if grep -Fxq "refs/tags/$tag" <<< "$refs"; then
  resolved=$(gh api "repos/$GITHUB_REPOSITORY/commits/$tag" --jq .sha)
  [ "$resolved" = "$GITHUB_SHA" ] || { echo "release tag commit mismatch" >&2; exit 1; }
elif [ "$state" = false ]; then
  echo "published release is missing its tag" >&2; exit 1
fi
if [ "$state" = true ]; then
  target=$(gh release view "$tag" --json targetCommitish --jq .targetCommitish)
  [ "$target" = "$GITHUB_SHA" ] || { echo "draft target commit mismatch" >&2; exit 1; }
fi
if [ "$state" = false ]; then
  previous=$(mktemp -d)
  trap 'rm -rf "$previous"' EXIT
  for file in "${files[@]}"; do
    gh release download "$tag" --pattern "${file##*/}" --dir "$previous"
    cmp "$file" "$previous/${file##*/}" || {
      echo "refusing to replace published asset ${file##*/}" >&2; exit 1;
    }
  done
  echo "$tag already published with identical assets"
  exit 0
fi
# Overwrite only inside an unpublished draft after a failed/partial upload.
gh release upload "$tag" "${files[@]}" --clobber
gh release edit "$tag" --draft=false --prerelease --latest=false
# Read back the publication rather than interpreting an uncertain edit as a
# reason to create/overwrite a second release.
[ "$(gh release view "$tag" --json isDraft --jq .isDraft)" = false ]
[ "$(gh api "repos/$GITHUB_REPOSITORY/commits/$tag" --jq .sha)" = "$GITHUB_SHA" ]
