#!/usr/bin/env bash
# Tests for the pure helper functions in ../e2e-agent.sh.
#
# Same shape as deploy/agent/tests/install-sh-test.sh, and for the same reason:
# e2e-agent.sh is a standalone launcher with no library to source, so this
# harness lifts the functions under test out of it with sed and runs them
# against stubbed dependencies. The coupling that implies — each function must
# start at column 0 and end with a closing brace at column 0 — is checked by
# extract_function below, which fails loudly rather than silently testing
# nothing if e2e-agent.sh is reshaped.
#
# Covers the guard on `reset`, which deletes /var/lib/spire/agent and
# /var/lib/strato/vms — every VM disk on the host. Both halves matter:
# strato_unit_state decides whether systemd is running the agent, and
# strato_guests_running decides whether guests are live on the paths about to
# be removed. Getting either wrong in the permissive direction destroys VM
# state; getting them wrong in the strict direction strands a dev host.
#
#   bash deploy/compose/tests/e2e-agent-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SH="$SCRIPT_DIR/../e2e-agent.sh"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

FAILURES=0
CASES=0

fail() {
  echo "  FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

# check <description> <expected> <actual>
check() {
  CASES=$((CASES + 1))
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    fail "$1 — expected '$2', got '$3'"
  fi
}

extract_function() {
  local name="$1" body
  body="$(sed -n "/^${name}()/,/^}/p" "$AGENT_SH")"
  case "$body" in
    "") echo "error: could not extract ${name}() from $AGENT_SH" >&2; exit 1 ;;
  esac
  # A truncated extraction (function no longer ends with a lone brace) would
  # otherwise produce a syntax error blamed on this harness.
  case "$body" in
    *$'\n}') ;;
    *) echo "error: extraction of ${name}() from $AGENT_SH is not brace-terminated" >&2; exit 1 ;;
  esac
  printf '%s\n' "$body"
}

HARNESS="$WORK_DIR/harness.sh"
{
  echo 'set -uo pipefail'
  extract_function strato_unit_state
  extract_function strato_guests_running
} > "$HARNESS"
# shellcheck source=/dev/null
. "$HARNESS"

# --- strato_unit_state -------------------------------------------------------
# Only the first field is the verdict; the other two are the raw systemctl
# values the caller reports back to the operator.

STUB_DIR="$WORK_DIR/bin"
mkdir -p "$STUB_DIR"

# stub_systemctl <listed:yes|no> <is-active> <is-enabled>
stub_systemctl() {
  cat > "$STUB_DIR/systemctl" << EOF
#!/usr/bin/env bash
case "\$1" in
  list-unit-files)
    [ "$1" = yes ] && printf 'UNIT FILE            STATE    PRESET\nstrato-agent.service $3 enabled\n'
    exit 0 ;;
  is-active)  echo "$2"; [ "$2" = active ] && exit 0 || exit 3 ;;
  is-enabled) echo "$3"; [ "$3" = enabled ] && exit 0 || exit 1 ;;
esac
EOF
  chmod +x "$STUB_DIR/systemctl"
}

# verdict — the state word alone, with the stub on PATH.
verdict() {
  PATH="$STUB_DIR:$PATH" strato_unit_state | cut -d' ' -f1
}

echo "strato_unit_state: systemd is running the unit, or will"
stub_systemctl yes active enabled
check "active + enabled refuses" in-use "$(verdict)"
stub_systemctl yes active disabled
check "active alone refuses (disabled but running right now)" in-use "$(verdict)"
stub_systemctl yes inactive enabled
check "enabled alone refuses (comes back at the next boot)" in-use "$(verdict)"
stub_systemctl yes inactive enabled-runtime
check "enabled-runtime refuses" in-use "$(verdict)"
stub_systemctl yes inactive linked
check "linked refuses (systemd owns the unit file)" in-use "$(verdict)"
stub_systemctl yes inactive alias
check "alias refuses" in-use "$(verdict)"

echo "strato_unit_state: transitional states are not idle"
for s in activating deactivating reloading; do
  stub_systemctl yes "$s" disabled
  check "$s refuses" in-use "$(verdict)"
done

echo "strato_unit_state: unknown is-active values fail toward refusing"
# The fall-through from here reaches `rm -rf /var/lib/strato/vms`, so anything
# this script does not recognise must not be read as safe to wipe.
stub_systemctl yes refreshing disabled
check "a state systemd added later (refreshing) refuses" in-use "$(verdict)"
stub_systemctl yes "" disabled
check "an empty is-active (systemctl failed) refuses" in-use "$(verdict)"

echo "strato_unit_state: a leftover unit nobody runs"
stub_systemctl yes inactive disabled
check "inactive + disabled is stale, not a refusal" stale "$(verdict)"
check "and reports the values it saw" "stale inactive disabled" \
  "$(PATH="$STUB_DIR:$PATH" strato_unit_state)"
stub_systemctl yes failed disabled
check "failed + disabled is stale" stale "$(verdict)"
stub_systemctl yes inactive masked
check "masked is stale" stale "$(verdict)"

echo "strato_unit_state: no unit, no systemd"
stub_systemctl no inactive disabled
check "no unit file is absent" absent "$(verdict)"
check "absent still echoes three fields" "absent - -" \
  "$(PATH="$STUB_DIR:$PATH" strato_unit_state)"
rm -f "$STUB_DIR/systemctl"
# PATH is set to the stub dir alone, so an absolute bash is required — resolving
# `bash` through the emptied PATH would fail for the wrong reason.
BASH_ABS="$(command -v bash)"
check "a host without systemctl is absent" "absent - -" \
  "$(PATH="$STUB_DIR" "$BASH_ABS" -c ". '$HARNESS'; strato_unit_state" 2>/dev/null)"

# --- strato_guests_running ---------------------------------------------------
# Scoped to the path `reset` deletes, so unrelated guests on a dev host do not
# trip it. Stubbing pgrep keeps this from depending on what the host is running.

stub_pgrep() { # stub_pgrep <output>
  cat > "$STUB_DIR/pgrep" << EOF
#!/usr/bin/env bash
printf '%s' "$1"
[ -n "$1" ] && exit 0 || exit 1
EOF
  chmod +x "$STUB_DIR/pgrep"
}

echo "strato_guests_running"
stub_pgrep ""
check "no guests is empty output" "" "$(PATH="$STUB_DIR:$PATH" strato_guests_running)"
stub_pgrep "4242"
check "a live guest is reported" "4242" "$(PATH="$STUB_DIR:$PATH" strato_guests_running)"
stub_pgrep $'4242\n4243'
check "several guests are reported" $'4242\n4243' \
  "$(PATH="$STUB_DIR:$PATH" strato_guests_running)"
# pgrep exits 1 when nothing matched; under `set -e`-less pipefail that must not
# make the function look like it failed, and callers test for empty output.
stub_pgrep ""
PATH="$STUB_DIR:$PATH" strato_guests_running >/dev/null
check "no match still exits 0 (the || true)" 0 "$?"

# The real matcher must be anchored on the directory reset deletes rather than
# on hypervisor names, or an unrelated VM on a dev host would block the run.
check "matches the VM state directory, not qemu/firecracker by name" 1 \
  "$(grep -c "pgrep -f '/var/lib/strato/vms'" "$AGENT_SH")"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All $CASES checks passed."
else
  echo "$FAILURES of $CASES checks failed." >&2
fi
exit "$((FAILURES > 0))"
