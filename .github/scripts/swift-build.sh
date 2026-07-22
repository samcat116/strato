#!/usr/bin/env bash
# swift build against a (possibly warm, possibly shared) scratch tree, with a
# one-shot cold retry when the failure looks like a poisoned tree rather than
# broken source.
#
#   swift-build.sh <scratch-dir> [swift build args...]
#
# Reusing a build tree across commits and branches is what makes CI fast, but
# it introduces a failure mode a cold build cannot have: a stale ModuleCache,
# a half-written object from a cancelled run, or an llbuild database that no
# longer matches the tree. strato#386 hit exactly this when a job container
# change poisoned the ModuleCache, and it took a manual cache-key salt to
# escape. The scratch root is toolchain-keyed to prevent the common cause, but
# something has to handle the rest without a human.
#
# The retry is deliberately NOT unconditional. A failing compile is the normal
# outcome for a PR with a bug in it, and rebuilding those from scratch would
# double every red build's time to feedback -- the opposite of why the warm
# tree exists. So: if the compiler emitted a source-level diagnostic, the code
# is wrong and we report it immediately. If it failed with no diagnostic
# pointing at a line of source (a compiler crash, a malformed module, an
# llbuild error), the tree is suspect and we wipe it and try once from cold.
#
# Worst case for a misclassification is one wasted rebuild, never a wrong
# result: the retry recompiles everything from source.
set -euo pipefail

scratch="${1:?usage: swift-build.sh <scratch-dir> [swift build args...]}"
shift

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# pipefail makes this return swift's status rather than tee's.
build() {
    swift build --scratch-path "$scratch" "$@" 2>&1 | tee "$log"
}

if build "$@"; then
    exit 0
fi

# Matches "Sources/App/Foo.swift:12:5: error: ..." anywhere in the line, so it
# still fires on absolute paths and on notes emitted with a leading column.
if grep -qE '\.swift:[0-9]+:[0-9]+: (error|warning): ' "$log"; then
    echo "::error::swift build failed with source-level diagnostics; not retrying"
    exit 1
fi

echo "::warning::swift build failed with no source-level diagnostic — treating $scratch as poisoned, wiping and retrying cold"
rm -rf "$scratch"
mkdir -p "$scratch"

if build "$@"; then
    echo "cold rebuild succeeded; the previous tree was stale"
    exit 0
fi

echo "::error::swift build failed again after a cold rebuild; not a stale-tree problem"
exit 1
