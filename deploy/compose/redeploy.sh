#!/usr/bin/env bash
#
# Redeploy services of the Strato compose stack without leaving it subtly
# broken.
#
# Recreating control-plane on its own (e.g. `docker compose up -d --no-deps
# control-plane`) breaks the stack in a way that produces misleading errors:
# envoy and spire-api-bridge run with network_mode: "service:control-plane",
# so recreating the control plane orphans them into the old container's dead
# network namespace. The visible symptom is e.g. registration-token creation
# failing with "SPIRE server unreachable: 127.0.0.1:8081" — which reads like a
# SPIRE problem, not a container-lifecycle one. This script encodes the
# correct sequence: the namespace owner and everything inside its namespace
# are always recreated together.
#
# Usage:
#   ./redeploy.sh                  # pull + redeploy control-plane (and its
#                                  # network-namespace sidecars)
#   ./redeploy.sh frontend         # pull + redeploy the frontend
#   ./redeploy.sh all              # both
#   ./redeploy.sh --build [...]    # build from source instead of pulling
#                                  # (requires the build: override, see README)
#   ./redeploy.sh --no-pull [...]  # skip pull/build; redeploy the image
#                                  # already present locally
set -euo pipefail

cd "$(dirname "$0")"

MODE="pull"
TARGET="control-plane"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) MODE="build"; shift ;;
    --no-pull) MODE="none"; shift ;;
    control-plane|frontend|all) TARGET="$1"; shift ;;
    -h|--help)
      sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1 (see --help)" >&2
      exit 1
      ;;
  esac
done

# Services to fetch/build vs. services to recreate. envoy and spire-api-bridge
# ship third-party images that never change with a Strato release, but they
# must be recreated whenever control-plane is, because they live inside its
# network namespace.
FETCH=()
RECREATE=()
case "$TARGET" in
  control-plane)
    FETCH=(control-plane)
    RECREATE=(control-plane spire-api-bridge envoy)
    ;;
  frontend)
    FETCH=(frontend)
    RECREATE=(frontend)
    ;;
  all)
    FETCH=(control-plane frontend)
    RECREATE=(control-plane spire-api-bridge envoy frontend)
    ;;
esac

case "$MODE" in
  pull) docker compose pull "${FETCH[@]}" ;;
  build) docker compose build "${FETCH[@]}" ;;
  none) ;;
esac

docker compose up -d --force-recreate "${RECREATE[@]}"

# The proxy re-resolves upstream IPs via Docker's embedded DNS (nginx.conf
# uses a request-time resolver), so it converges on the new containers within
# ~10s on its own. Restart it anyway: it is instant, drops nothing important,
# and also covers a proxy still running a pre-resolver nginx.conf.
docker compose restart proxy

echo
echo "Redeployed: ${RECREATE[*]}"
docker compose ps "${RECREATE[@]}"
