#!/usr/bin/env bash
#
# Smoke test for the assembled deploy/compose stack, exercised THROUGH the
# nginx proxy. Some bugs only exist in the interaction between the control
# plane and a strict HTTP proxy — e.g. a duplicate Content-Length header
# (issue #517) passed every unit test and direct curl to the container, while
# nginx 502'd every agent image download. Only a composed stack can catch
# those, which is exactly what this script checks:
#
#   - /health through the proxy
#   - unauthenticated API requests are rejected
#   - image full download: 200, exactly one Content-Length == file size,
#     body checksum matches what was uploaded
#   - image ranged download: 206, exactly one Content-Length == range size,
#     Content-Range present (a "fix" that forced Content-Length to the full
#     file size would fail here)
#   - the agent mTLS listener (Envoy) presents a server certificate on :8443
#
# The image checks upload a small throwaway image into the given project and
# delete it afterwards.
#
# Usage:
#   ./smoke-test.sh --api-key sk_...            # origin/agent endpoint from .env
#   ./smoke-test.sh --origin http://host --api-key sk_... [--project <uuid>]
#   STRATO_API_KEY=sk_... ./smoke-test.sh
#
# An admin/write API key is required (see `docker compose run --rm bootstrap`
# for a fresh deployment). --project defaults to the first project visible to
# the key. Exits non-zero if any check fails.
set -uo pipefail

cd "$(dirname "$0")"

ORIGIN=""
API_KEY="${STRATO_API_KEY:-}"
PROJECT_ID=""
AGENT_ENDPOINT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --origin) ORIGIN="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --agent-endpoint) AGENT_ENDPOINT="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1 (see --help)" >&2
      exit 1
      ;;
  esac
done

# Fill defaults from the deployment's .env when run next to it.
if [[ -f .env ]]; then
  [[ -z "$ORIGIN" ]] && ORIGIN="$(sed -n 's/^CONTROL_PLANE_URL=//p' .env)"
  [[ -z "$AGENT_ENDPOINT" ]] && AGENT_ENDPOINT="$(sed -n 's/^EXTERNAL_HOSTNAME=//p' .env)"
fi
ORIGIN="${ORIGIN:-http://localhost}"
AGENT_ENDPOINT="${AGENT_ENDPOINT:-localhost:8443}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: an API key is required (--api-key or STRATO_API_KEY)." >&2
  echo "On a fresh deployment: docker compose run --rm bootstrap" >&2
  exit 1
fi

AUTH=(-H "Authorization: Bearer ${API_KEY}")
TMP="$(mktemp -d)"
IMAGE_ID=""

cleanup() {
  if [[ -n "$IMAGE_ID" && -n "$PROJECT_ID" ]]; then
    curl -sS -o /dev/null -X DELETE "${AUTH[@]}" \
      "${ORIGIN}/api/projects/${PROJECT_ID}/images/${IMAGE_ID}" || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
pass() { echo "  ok: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# expect_eq <label> <actual> <expected>
expect_eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1 (got '$2', want '$3')"
  fi
}

json_get() { # json_get <python-expr-on-d> ; JSON on stdin
  python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# sha256 that works on both Linux (sha256sum) and macOS (shasum)
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# header_count <headers-file> <header-name>
header_count() { grep -ci "^$2:" "$1" || true; }
# header_value <headers-file> <header-name> — first occurrence, trimmed
header_value() { grep -i "^$2:" "$1" | head -1 | cut -d' ' -f2- | tr -d '\r'; }

echo "Smoke-testing ${ORIGIN} (agent endpoint ${AGENT_ENDPOINT})"

# --- 1. Health through the proxy ---------------------------------------------
code=$(curl -sS -o /dev/null -w '%{http_code}' "${ORIGIN}/health") || code="unreachable"
expect_eq "GET /health -> 200" "$code" "200"

# --- 2. Unauthenticated requests are rejected --------------------------------
code=$(curl -sS -o /dev/null -w '%{http_code}' "${ORIGIN}/api/projects")
if [[ "$code" == "401" || "$code" == "403" ]]; then
  pass "unauthenticated GET /api/projects -> $code"
else
  fail "unauthenticated GET /api/projects (got '$code', want 401/403)"
fi

# --- 3. Authenticated API access ---------------------------------------------
code=$(curl -sS -o "$TMP/projects.json" -w '%{http_code}' "${AUTH[@]}" "${ORIGIN}/api/projects")
expect_eq "authenticated GET /api/projects -> 200" "$code" "200"

if [[ -z "$PROJECT_ID" && "$code" == "200" ]]; then
  PROJECT_ID=$(json_get "d[0]['id']" < "$TMP/projects.json" 2>/dev/null || true)
fi
if [[ -z "$PROJECT_ID" ]]; then
  fail "no project available (pass --project); skipping image download checks"
else
  # --- 4. Upload a throwaway image artifact -----------------------------------
  BLOB_SIZE=1048576
  head -c "$BLOB_SIZE" /dev/urandom > "$TMP/blob"

  IMAGE_ID=$(
    curl -sS "${AUTH[@]}" -H 'Content-Type: application/json' \
      -d "{\"name\": \"smoke-test-$$\", \"description\": \"deploy/compose smoke test (safe to delete)\"}" \
      "${ORIGIN}/api/projects/${PROJECT_ID}/images" | json_get "d['id']" 2>/dev/null || true
  )
  if [[ -z "$IMAGE_ID" ]]; then
    fail "create image shell"
  else
    pass "create image shell"
    code=$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" \
      -F "kind=disk-image" -F "file=@$TMP/blob;filename=smoke.raw" \
      "${ORIGIN}/api/projects/${PROJECT_ID}/images/${IMAGE_ID}/artifacts")
    expect_eq "upload ${BLOB_SIZE}-byte disk artifact -> 200" "$code" "200"

    DOWNLOAD="${ORIGIN}/api/projects/${PROJECT_ID}/images/${IMAGE_ID}/download"

    # --- 5. Full download through the proxy -----------------------------------
    code=$(curl -sS -D "$TMP/h_full" -o "$TMP/out_full" -w '%{http_code}' "${AUTH[@]}" "$DOWNLOAD")
    expect_eq "full download -> 200" "$code" "200"
    expect_eq "full download: exactly one Content-Length" "$(header_count "$TMP/h_full" Content-Length)" "1"
    expect_eq "full download: Content-Length == file size" "$(header_value "$TMP/h_full" Content-Length)" "$BLOB_SIZE"
    expect_eq "full download: body matches upload" "$(sha256 "$TMP/out_full")" "$(sha256 "$TMP/blob")"

    # --- 6. Ranged download (resumable agent fetches) -------------------------
    code=$(curl -sS -D "$TMP/h_range" -o "$TMP/out_range" -w '%{http_code}' "${AUTH[@]}" \
      -H 'Range: bytes=0-1023' "$DOWNLOAD")
    expect_eq "ranged download -> 206" "$code" "206"
    expect_eq "ranged download: exactly one Content-Length" "$(header_count "$TMP/h_range" Content-Length)" "1"
    expect_eq "ranged download: Content-Length == 1024" "$(header_value "$TMP/h_range" Content-Length)" "1024"
    if [[ "$(header_value "$TMP/h_range" Content-Range)" == "bytes 0-1023/${BLOB_SIZE}" ]]; then
      pass "ranged download: Content-Range correct"
    else
      fail "ranged download: Content-Range (got '$(header_value "$TMP/h_range" Content-Range)', want 'bytes 0-1023/${BLOB_SIZE}')"
    fi
    head -c 1024 "$TMP/blob" > "$TMP/blob_head"
    expect_eq "ranged download: bytes match" "$(sha256 "$TMP/out_range")" "$(sha256 "$TMP/blob_head")"

    # --- 7. Cleanup (also exercises DELETE through the proxy) -----------------
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "${AUTH[@]}" \
      "${ORIGIN}/api/projects/${PROJECT_ID}/images/${IMAGE_ID}")
    if [[ "$code" == "200" || "$code" == "204" ]]; then
      pass "delete image -> $code"
      IMAGE_ID=""
    else
      fail "delete image (got '$code')"
    fi
  fi
fi

# --- 8. Agent mTLS listener (Envoy) ------------------------------------------
# A full agent handshake needs a SPIRE-issued client SVID, so settle for
# proving the TLS side is alive: Envoy must present a server certificate.
if command -v openssl >/dev/null 2>&1; then
  if openssl s_client -connect "$AGENT_ENDPOINT" </dev/null 2>/dev/null \
      | grep -q 'BEGIN CERTIFICATE'; then
    pass "Envoy mTLS listener presents a server certificate on ${AGENT_ENDPOINT}"
  else
    fail "Envoy mTLS listener on ${AGENT_ENDPOINT} (no server certificate presented)"
  fi
else
  echo "  skip: openssl not found, not checking the agent mTLS listener"
fi

echo
echo "${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
