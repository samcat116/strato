#!/usr/bin/env bash
# One-shot SPIRE bootstrap for the control-plane side.
#
# Runs after spire-server is up and:
#   1. creates the control-plane workload entry (Envoy's server SVID),
#   2. mints a join token for the control-plane-side spire-agent, and
#   3. exports the trust bundle,
# handing (2) and (3) to spire-agent-cp / control-plane via the shared
# handoff volume. Idempotent: safe to re-run on every `up`.
set -euo pipefail

SOCK=/tmp/spire-server/private/api.sock
TRUST_DOMAIN=strato.local
HANDOFF=/handoff
CP_NODE="spiffe://${TRUST_DOMAIN}/cp-node"
CP_WORKLOAD="spiffe://${TRUST_DOMAIN}/control-plane"
# DNS SAN for Envoy's server SVID: the hostname agents dial for mTLS. Go TLS
# clients (Grafana Alloy pushing telemetry) refuse a URI-SAN-only certificate,
# so the entry must carry this. Passed in from .env via docker-compose.yml.
DNS_NAME="${STRATO_HOSTNAME:-localhost}"

log() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

log "Waiting for the SPIRE server admin socket at ${SOCK}"
for _ in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 1; done
[ -S "$SOCK" ] || { echo "error: admin socket never appeared" >&2; exit 1; }

log "Waiting for the SPIRE server /ready endpoint"
for _ in $(seq 1 60); do curl -sf http://spire-server:8086/ready >/dev/null 2>&1 && break; sleep 1; done

mkdir -p "$HANDOFF"

# 1. Control-plane (Envoy) server-cert entry. The envoyproxy image runs its
#    process as uid 101; the control-plane-side agent attests it by that uid
#    over the Workload API. A duplicate create on re-run is tolerated, but any
#    OTHER failure is fatal — Envoy's server SVID depends on this entry, so
#    starting without it would leave agents unable to complete mTLS.
log "Creating control-plane workload entry (${CP_WORKLOAD}, unix:uid:101, dns:${DNS_NAME})"
if ! entry_out=$(spire-server entry create \
    -socketPath "$SOCK" \
    -parentID "$CP_NODE" \
    -spiffeID "$CP_WORKLOAD" \
    -selector unix:uid:101 \
    -dns "$DNS_NAME" \
    -x509SVIDTTL 3600 2>&1); then
    printf '%s\n' "$entry_out" | sed 's/^/    /' >&2
    if ! printf '%s' "$entry_out" | grep -qiE "already exists|similar entry"; then
        die "failed to create control-plane workload entry"
    fi
    # The entry exists from an earlier `up` — possibly created before DNS SANs
    # were added, or with a different hostname. The duplicate check above keys
    # on spiffeID+parentID+selectors only, so update to converge the DNS SAN.
    entry_id=$(spire-server entry show \
        -socketPath "$SOCK" \
        -spiffeID "$CP_WORKLOAD" 2>/dev/null | awk '/Entry ID/{print $NF; exit}')
    [ -n "$entry_id" ] || die "entry reported as existing but not found for update"
    log "Entry already exists (${entry_id}); updating to converge DNS SAN"
    spire-server entry update \
        -socketPath "$SOCK" \
        -entryID "$entry_id" \
        -parentID "$CP_NODE" \
        -spiffeID "$CP_WORKLOAD" \
        -selector unix:uid:101 \
        -dns "$DNS_NAME" \
        -x509SVIDTTL 3600 | sed 's/^/    /' \
        || die "failed to update control-plane workload entry"
else
    printf '%s\n' "$entry_out" | sed 's/^/    /'
fi

# 2. Single-use join token pinned to the control-plane node identity. The agent
#    redeems it on first attestation and uses its own node SVID thereafter, so a
#    fresh (unredeemed) token each `up` is harmless.
log "Minting join token for ${CP_NODE}"
TOKEN=$(spire-server token generate \
    -socketPath "$SOCK" \
    -spiffeID "$CP_NODE" \
    -ttl 86400 2>/dev/null | awk '/Token:/{print $2}')
[ -n "$TOKEN" ] || { echo "error: failed to mint join token" >&2; exit 1; }
printf '%s' "$TOKEN" > "$HANDOFF/cp-agent-token"

# 3. Trust bundle for spire-agent-cp bootstrap and for the control plane to
#    re-verify forwarded client certificates.
log "Exporting trust bundle"
spire-server bundle show -socketPath "$SOCK" -format pem > "$HANDOFF/bundle.pem"

touch "$HANDOFF/ready"
log "Bootstrap complete"
