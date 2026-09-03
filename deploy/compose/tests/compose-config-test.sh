#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
compose_file="$repo_root/deploy/compose/docker-compose.yml"

render_public_address() {
  local -a environment=(env -u SPIRE_SERVER_PUBLIC_ADDRESS)
  if [[ $# -eq 1 ]]; then
    environment=(env "SPIRE_SERVER_PUBLIC_ADDRESS=$1")
  fi

  "${environment[@]}" \
    "${common_env[@]}" \
    STRATO_HOSTNAME=strato.example.test \
    SPIRE_NODE_PORT=18085 \
    docker compose -f "$compose_file" config --format json \
    | jq -er '.services["control-plane"].environment.SPIRE_SERVER_PUBLIC_ADDRESS'
}

common_env=(
  POSTGRES_PASSWORD=test
  VALKEY_PASSWORD=test
  WEBAUTHN_RELYING_PARTY_ID=strato.example.test
  WEBAUTHN_RELYING_PARTY_ORIGIN=https://strato.example.test
  CONTROL_PLANE_URL=https://strato.example.test
)

legacy_address="$(render_public_address 2>/dev/null)"

if [[ "$legacy_address" != "strato.example.test:18085" ]]; then
  printf 'not ok: legacy environment rendered SPIRE address %q\n' "$legacy_address" >&2
  exit 1
fi

explicit_address="$(render_public_address spire.example.test:28085 2>/dev/null)"

if [[ "$explicit_address" != "spire.example.test:28085" ]]; then
  printf 'not ok: explicit SPIRE address rendered as %q\n' "$explicit_address" >&2
  exit 1
fi

echo 'docker-compose.yml: legacy and explicit SPIRE public addresses render correctly'
