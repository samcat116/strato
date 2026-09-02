#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

cp "$repo_root/deploy/compose/setup.sh" "$test_root/setup.sh"
output="$(cd "$test_root" && bash ./setup.sh 2>&1)"

if [[ "$output" == *"command not found"* ]]; then
  printf 'not ok: setup executed text from the generated env template\n%s\n' "$output" >&2
  exit 1
fi

grep -Fq '# Image tag to deploy. `main` is rebuilt' "$test_root/.env"
grep -q '^STRATO_VERSION=main$' "$test_root/.env"

echo 'setup.sh: generated env comments remain literal and the image tag is intact'
