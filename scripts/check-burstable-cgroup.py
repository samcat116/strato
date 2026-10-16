#!/usr/bin/env python3
"""Read-only STR-272 kernel readback scaffold for an owned backend cgroup.

Run after backend create, restart, and adoption using the same ownership path.
This checks effective files only; it does not prove reclaim, OOM containment,
CPU fairness, or the absence of a transient unlimited window.
"""

import argparse
import json
from pathlib import Path
import sys


def check(root, memory_high, memory_max, cpu_weight):
    expected = {
        "memory.high": str(memory_high),
        "memory.max": str(memory_max),
        "cpu.weight": str(cpu_weight),
    }
    applied = {name: (root / name).read_text().strip() for name in expected}
    applied["cpu.max"] = (root / "cpu.max").read_text().strip()
    failures = [
        f"{name}: expected {value}, got {applied[name]}"
        for name, value in expected.items()
        if applied[name] != value
    ]
    if not applied["cpu.max"].split() or applied["cpu.max"].split()[0] != "max":
        failures.append("cpu.max imposes a quota on the shared workload")
    telemetry = {}
    for name in ("memory.events", "memory.pressure", "cpu.stat", "cpu.pressure"):
        telemetry[name] = (root / name).read_text().strip()
    return {"path": str(root), "applied": applied, "telemetry": telemetry, "failures": failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owned-cgroup", required=True, type=Path,
                        help="Exact libvirt- or jailer-owned path; no descendant discovery")
    parser.add_argument("--memory-high", required=True, type=int)
    parser.add_argument("--memory-max", required=True, type=int)
    parser.add_argument("--cpu-weight", required=True, type=int)
    args = parser.parse_args()
    if not 0 < args.memory_high < args.memory_max or not 1 <= args.cpu_weight <= 10000:
        parser.error("Require 0 < memory.high < memory.max and cpu.weight in 1...10000")
    root = args.owned_cgroup.resolve()
    hierarchy = Path("/sys/fs/cgroup")
    if not root.is_relative_to(hierarchy) or root == hierarchy:
        parser.error("Require an owned workload path beneath /sys/fs/cgroup")
    try:
        result = check(root, args.memory_high, args.memory_max, args.cpu_weight)
    except OSError as error:
        print(json.dumps({"path": str(root), "unavailable": str(error)}))
        return 2
    print(json.dumps(result, indent=2))
    return 1 if result["failures"] else 0


if __name__ == "__main__":
    sys.exit(main())
