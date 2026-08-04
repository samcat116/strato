#!/usr/bin/env bash
# Tests for the pure helper functions in ../install.sh.
#
# install.sh has to stay a single curl-able file, so there is no library to
# source: this harness lifts the functions under test out of it with sed and
# runs them against fixture files. The coupling that implies — each function
# must start at column 0 and end with a closing brace at column 0 — is checked
# by extract_function below, which fails loudly rather than silently testing
# nothing if install.sh is reshaped.
#
# Covers the two helpers with real logic and real consequences: the qemu.conf
# writer (which edits a 0600 root-owned file that can hold VNC/TLS secrets) and
# the version comparison behind the libvirt floor.
#
#   bash deploy/agent/tests/install-sh-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"
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
  body="$(sed -n "/^${name}()/,/^}/p" "$INSTALL_SH")"
  case "$body" in
    "") echo "error: could not extract ${name}() from $INSTALL_SH" >&2; exit 1 ;;
  esac
  # A truncated extraction (function no longer ends with a lone brace) would
  # otherwise produce a syntax error blamed on this harness.
  case "$body" in
    *$'\n}') ;;
    *) echo "error: extraction of ${name}() from $INSTALL_SH is not brace-terminated" >&2; exit 1 ;;
  esac
  printf '%s\n' "$body"
}

# The functions under test, plus the log/warn stubs they call.
HARNESS="$WORK_DIR/harness.sh"
{
  echo 'set -uo pipefail'
  echo 'log() { :; }'
  echo 'warn() { :; }'
  extract_function set_qemu_conf_key
  extract_function version_ge
} > "$HARNESS"
# shellcheck source=/dev/null
. "$HARNESS"

# --- set_qemu_conf_key -------------------------------------------------------
# Returns 0 when the file changed, 1 when it already agreed. Callers use that to
# decide whether to restart libvirtd, so "no change" must really mean no change.

# write_keys <file> — the three keys install.sh owns; echoes "changed"/"unchanged".
write_keys() {
  LIBVIRT_QEMU_CONF="$1"
  local changed=0
  if set_qemu_conf_key user '"root"'; then changed=1; fi
  if set_qemu_conf_key group '"root"'; then changed=1; fi
  if set_qemu_conf_key dynamic_ownership 1; then changed=1; fi
  [ "$changed" -eq 1 ] && echo changed || echo unchanged
}

echo "set_qemu_conf_key: a stock libvirt qemu.conf"
STOCK="$WORK_DIR/stock.conf"
cat > "$STOCK" << 'EOF'
# Master configuration file for the QEMU driver.
#vnc_listen = "0.0.0.0"
#user = "libvirt-qemu"
#group = "libvirt-qemu"
#dynamic_ownership = 1
#security_driver = "selinux"
EOF
chmod 600 "$STOCK"
STOCK_COMMENTS="$(grep '^#' "$STOCK")"
check "first run reports a change" changed "$(write_keys "$STOCK")"
check "re-run is a no-op (no daemon restart)" unchanged "$(write_keys "$STOCK")"
check "0600 mode survives the append path" 600 "$(stat -c %a "$STOCK")"
check "the agent's uid is written" 'user = "root"' "$(grep '^user' "$STOCK")"
check "dynamic_ownership is left on" 'dynamic_ownership = 1' "$(grep '^dynamic_ownership' "$STOCK")"
# Verbatim, not a count: those lines are the documentation an operator reads, and
# the writer must never mistake a commented default for an assignment. Selecting
# the original lines back out of the edited file proves each survived intact and
# in order (the file also gains our own managed-block comments, which is fine).
check "libvirt's commented defaults are untouched" \
  "$STOCK_COMMENTS" "$(grep -Fxf <(printf '%s\n' "$STOCK_COMMENTS") "$STOCK")"

echo "set_qemu_conf_key: a host configured the wrong way by hand"
WRONG="$WORK_DIR/wrong.conf"
cat > "$WRONG" << 'EOF'
user = "libvirt-qemu"
group   =    "kvm"
dynamic_ownership = 0
security_driver = "apparmor"
EOF
chmod 600 "$WRONG"
# This fixture is the one that exercises the rewrite path (the stock file has no
# uncommented assignments, so it appends instead). A permissive umask is forced
# for it: qemu.conf holds VNC/SPICE passwords and TLS material, and the rewrite
# must carry the original 0600 across rather than inherit whatever the caller's
# umask would give a fresh temp file — under a strict umask that bug hides.
check "the wrong values are corrected" changed "$(umask 022; write_keys "$WRONG")"
check "0600 mode survives the rewrite path" 600 "$(stat -c %a "$WRONG")"
check "dynamic_ownership = 0 is turned back on" 'dynamic_ownership = 1' "$(grep '^dynamic_ownership' "$WRONG")"
check "AppArmor is left enabled" 'security_driver = "apparmor"' "$(grep '^security_driver' "$WRONG")"
check "and then it settles" unchanged "$(write_keys "$WRONG")"

echo "set_qemu_conf_key: duplicate assignments (libvirt honors the last)"
DUPES="$WORK_DIR/dupes.conf"
printf 'user = "root"\nuser = "libvirt-qemu"\ngroup = "root"\ndynamic_ownership = 1\n' > "$DUPES"
chmod 600 "$DUPES"
# The effective value is the second line, so this file is NOT already correct —
# reading only the first would silently skip the fix.
check "a trailing wrong duplicate is caught" changed "$(write_keys "$DUPES")"
check "duplicates collapse to one line" 1 "$(grep -c '^user' "$DUPES")"
check "and the surviving value is ours" 'user = "root"' "$(grep '^user' "$DUPES")"
check "collapsing converges" unchanged "$(write_keys "$DUPES")"

echo "set_qemu_conf_key: values are data, not sed patterns"
ODD="$WORK_DIR/odd.conf"
printf 'user = "a|b&c"\n' > "$ODD"
# shellcheck disable=SC2034  # read by set_qemu_conf_key, sourced from install.sh
LIBVIRT_QEMU_CONF="$ODD"
set_qemu_conf_key user '"root"' >/dev/null
check "a value with | and & is replaced verbatim" 'user = "root"' "$(grep '^user' "$ODD")"

# --- version_ge --------------------------------------------------------------
# The libvirt floor. A wrong answer here either strands a supported host or
# admits one whose checkpoints will fail.

echo "version_ge: the libvirt 11.5 floor"
ge() { if version_ge "$1" "$2"; then echo yes; else echo no; fi; }
check "10.0.0 is below 11.5.0 (Ubuntu 24.04)"      no  "$(ge 10.0.0 11.5.0)"
check "11.5.0 exactly meets the floor"             yes "$(ge 11.5.0 11.5.0)"
check "11.5 with an implied patch meets it"        yes "$(ge 11.5 11.5.0)"
check "12.0.0 clears it (Ubuntu 26.04)"            yes "$(ge 12.0.0 11.5.0)"
check "11.4.99 does not clear it"                  no  "$(ge 11.4.99 11.5.0)"
check "9.10.0 compares numerically, not lexically" no  "$(ge 9.10.0 11.5.0)"
check "a non-numeric version is refused"           no  "$(ge abc 11.5.0)"
check "an empty version is refused"                no  "$(ge '' 11.5.0)"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "install.sh: $CASES checks passed"
else
  echo "install.sh: $FAILURES of $CASES checks FAILED" >&2
fi
exit $((FAILURES > 0))
