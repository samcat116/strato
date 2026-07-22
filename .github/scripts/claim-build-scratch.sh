#!/usr/bin/env bash
# Claim a warm SwiftPM build scratch slot for the duration of this job and
# export its path as BUILD_SCRATCH_ROOT.
#
# Runner pods are ephemeral, so $RUNNER_TOOL_CACHE starts empty on every job
# and a --scratch-path pointed at it is always cold. The github_runner Ansible
# role in samcat116/homelab mounts a persistent hostPath holding a pool of
# interchangeable slot directories and advertises it through two env vars:
#
#   RUNNER_BUILD_SCRATCH_ROOT   toolchain-keyed root, e.g.
#                               /cache/build-scratch/6.3.2-noble-r1
#   RUNNER_BUILD_SCRATCH_SLOTS  number of slots in each pool
#
# A single shared tree would not work: SwiftPM takes an exclusive lock on a
# scratch directory, so concurrent jobs would serialize behind each other.
# Each job therefore claims one whole slot with flock and keeps it until the
# pod exits. Slots are scanned in order so the low-numbered ones absorb most
# of the traffic and stay hot, rather than usage spreading evenly and leaving
# every tree half-cold.
#
# Callers pass a pool name to keep unrelated jobs off each other's trees --
# the packages job and the control-plane job build disjoint component sets, so
# sharing a pool would mean each repeatedly landing on a slot warmed for the
# other. Component subdirectories live inside the claimed slot.
#
# Every failure path degrades to a pod-local cold scratch dir rather than
# failing the build: this can make CI faster, never redder.
set -euo pipefail

pool="${1:?usage: claim-build-scratch.sh <pool-name>}"
fallback="${RUNNER_TOOL_CACHE:-/tmp}/strato-swift-build"

use_fallback() {
    echo "$1; using pod-local $fallback (cold)"
    mkdir -p "$fallback"
    echo "BUILD_SCRATCH_ROOT=$fallback" >>"$GITHUB_ENV"
}

root="${RUNNER_BUILD_SCRATCH_ROOT:-}"
slots="${RUNNER_BUILD_SCRATCH_SLOTS:-0}"

# The mount can be absent (a GitHub-hosted runner, or a pod predating the role
# change) and the directory can exist but be unwritable if the hostPath was
# created by root instead of the runner uid.
if [ -z "$root" ]; then
    use_fallback "no shared build scratch advertised by the runner"
    exit 0
fi
if ! mkdir -p "$root/$pool" 2>/dev/null || [ ! -w "$root/$pool" ]; then
    use_fallback "shared build scratch $root is not writable"
    exit 0
fi
if ! command -v flock >/dev/null 2>&1; then
    use_fallback "flock unavailable, cannot claim a slot safely"
    exit 0
fi

for i in $(seq 0 $((slots - 1))); do
    slot="$root/$pool/slot-$i"
    mkdir -p "$slot" || continue

    # $$ keeps this private to the claiming process. Without it, concurrent
    # claimants sharing a $RUNNER_TEMP all observe whichever one actually won
    # the lock and every one of them concludes it owns the slot.
    held="${RUNNER_TEMP:-/tmp}/scratch-slot-$pool-$i.$$.held"
    rm -f "$held"

    # `flock -n` exits non-zero immediately when the slot is taken, and runs
    # the -c command only once the lock is held -- so the marker file, not the
    # exit status, is what proves acquisition (the holder never exits while we
    # are looking). nohup + & detaches it so the lock outlives this step; the
    # kernel releases it when the pod dies, which also means a cancelled job
    # cannot strand a slot.
    nohup flock -n "$slot/.lock" -c "touch '$held'; sleep 86400" >/dev/null 2>&1 &
    holder=$!

    for _ in $(seq 1 50); do
        [ -e "$held" ] && break
        # flock exited without touching the marker => the slot was busy.
        kill -0 "$holder" 2>/dev/null || break
        sleep 0.1
    done

    if [ -e "$held" ]; then
        echo "claimed $slot (holder pid $holder)"
        echo "BUILD_SCRATCH_ROOT=$slot" >>"$GITHUB_ENV"
        echo "BUILD_SCRATCH_HOLDER_PID=$holder" >>"$GITHUB_ENV"
        exit 0
    fi
done

# More concurrent jobs than slots. Building cold beats queueing behind another
# job's whole build, so take the pod-local path and move on.
use_fallback "all $slots slots in $root/$pool are busy"
