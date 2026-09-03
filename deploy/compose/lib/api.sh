#!/usr/bin/env bash
# Shared API helpers for live Compose contract tests.

# request METHOD PATH OUTPUT [JSON] -- prints only the HTTP status code.
request() {
  local method="$1" path="$2" output="$3" body="${4:-}"
  if [[ -n "$body" ]]; then
    curl -sS -o "$output" -w '%{http_code}' -X "$method" "${AUTH[@]}" \
      -H 'Content-Type: application/json' -d "$body" "${ORIGIN}${path}"
  else
    curl -sS -o "$output" -w '%{http_code}' -X "$method" "${AUTH[@]}" "${ORIGIN}${path}"
  fi
}

json_get() {
  local expression="$1" file="$2"
  python3 -c "import json; d=json.load(open('$file')); print($expression)"
}

expect_code() {
  local label="$1" actual="$2" expected="$3" body_file="$4"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $label returned $actual, expected $expected" >&2
    cat "$body_file" >&2
    exit 1
  fi
  echo "  ok: $label -> $actual"
}

wait_converged() {
  local vm_id="$1" generation="$2" label="$3" started=$SECONDS state
  while (( SECONDS - started < TIMEOUT_SECONDS )); do
    request GET "/api/vms/${vm_id}" "$TMP_DIR/state.json" >/dev/null
    state="$(python3 - "$generation" "$TMP_DIR/state.json" <<'PY'
import json, sys
target = int(sys.argv[1])
d = json.load(open(sys.argv[2]))
c = d["conditions"]
degraded = c.get("degraded")
if degraded and degraded.get("sinceGeneration") == target:
    print("failed:" + degraded.get("reason", "unknown error"))
elif c.get("converged") and c.get("observedGeneration", -1) >= target:
    print("done")
else:
    print("pending")
PY
)"
    case "$state" in
      done) echo "  ok: $label converged at generation $generation"; return ;;
      failed:*) echo "FAIL: $label ${state#failed:}" >&2; exit 1 ;;
    esac
    sleep 1
  done
  echo "FAIL: timed out waiting for $label at generation $generation" >&2
  cat "$TMP_DIR/state.json" >&2
  exit 1
}
