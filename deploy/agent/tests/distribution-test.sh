#!/usr/bin/env bash
set -euo pipefail
for suite in distribution publisher binary-install; do
  python3 "$(dirname "$0")/${suite}-test.py"
done
