#!/bin/bash
set -euo pipefail

# Start the site's OVN central: NB ovsdb, SB ovsdb, and ovn-northd.
# --db-*-create-insecure-remote opens the plain-TCP listeners (ptcp:6641 /
# ptcp:6642) that the site's agents and ovn-controllers connect to. Plain TCP
# assumes the site network is trusted (LAN / customer-provided underlay,
# Phase 2 scope); switch to ovn-pki-issued certs and ssl: remotes for anything
# less trusted.
/usr/share/ovn/scripts/ovn-ctl start_northd \
    --db-nb-create-insecure-remote=yes \
    --db-sb-create-insecure-remote=yes

echo "ovn-central up: NB tcp:6641, SB tcp:6642"

# ovn-ctl daemonizes everything; keep the container alive on the logs and die
# if northd does, so the orchestrator restarts the whole unit.
tail -F /var/log/ovn/ovn-northd.log &
TAIL_PID=$!

trap '/usr/share/ovn/scripts/ovn-ctl stop_northd; kill $TAIL_PID 2>/dev/null || true; exit 0' TERM INT

while kill -0 "$(cat /var/run/ovn/ovn-northd.pid 2>/dev/null)" 2>/dev/null; do
    sleep 5
done
echo "ovn-northd exited; shutting down" >&2
kill $TAIL_PID 2>/dev/null || true
exit 1
