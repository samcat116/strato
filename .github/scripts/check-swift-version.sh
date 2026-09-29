#!/usr/bin/env bash
# Release binaries must match the runtime copied from the Docker build image.
set -euo pipefail

expected=6.4.0
output=$(swift --version)
printf '%s\n' "$output"
actual=$(printf '%s\n' "$output" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?)([[:space:]]|$).*/\1/p' | head -n 1)
# Apple Swift omits the zero patch component.
if [ "$actual" = "6.4" ]; then actual=6.4.0; fi
if [ "$actual" != "$expected" ]; then
    echo "::error::Expected Swift $expected, found ${actual:-unknown}. Update the runner toolchain to match the Dockerfiles before building."
    exit 1
fi
