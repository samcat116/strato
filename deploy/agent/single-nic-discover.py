#!/usr/bin/env python3
"""Read-only single-NIC evidence collection. Never applies or confirms a plan."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def query(argv):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        return {"argv": argv, "exitCode": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"argv": argv, "exitCode": None, "error": str(error)}


def collect(interface, run=query, config_root=Path("/etc/netplan")):
    if not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_.:-]{0,14}", interface):
        raise ValueError("expected a Linux interface name")
    commands = {
        "osRelease": ["cat", "/etc/os-release"],
        "kernel": ["uname", "-a"],
        "link": ["ip", "-j", "-details", "link", "show", "dev", interface],
        "addresses": ["ip", "-j", "address", "show", "dev", interface],
        "routes4": ["ip", "-j", "-4", "route", "show", "table", "all"],
        "routes6": ["ip", "-j", "-6", "route", "show", "table", "all"],
        "rules4": ["ip", "-j", "-4", "rule", "show"],
        "rules6": ["ip", "-j", "-6", "rule", "show"],
        "networkd": ["systemctl", "is-active", "systemd-networkd.service"],
        "networkManager": ["systemctl", "is-active", "NetworkManager.service"],
        "connman": ["systemctl", "is-active", "connman.service"],
        "dhcpcd": ["systemctl", "is-active", "dhcpcd.service"],
        "networkctl": ["networkctl", "--json=short", "status", interface],
        "dns": ["resolvectl", "status", interface],
        "netplan": ["netplan", "get"],
        "ovs": ["ovs-vsctl", "--timeout=5", "--format=json", "list", "Open_vSwitch"],
        "bridges": ["ovs-vsctl", "--timeout=5", "--format=json", "list", "Bridge"],
        "ports": ["ovs-vsctl", "--timeout=5", "--format=json", "list", "Port"],
        "interfaces": ["ovs-vsctl", "--timeout=5", "--format=json", "list", "Interface"],
    }
    evidence = {key: run(argv) for key, argv in commands.items()}
    blockers = ["management-NIC migration/recovery coordinator is not implemented",
                "reserved OVN SNAT address, ownership and inbound confirmation require a reviewed plan"]
    for key, result in evidence.items():
        # systemctl returns 3/4 for inactive/missing services. An unknown service
        # state is still incomplete evidence, never permission to proceed.
        inactive = key in ("networkManager", "connman", "dhcpcd") and (
            result.get("exitCode") in (3, 4) and result.get("stdout", "").strip() in ("inactive", "unknown"))
        if result.get("exitCode") != 0 and not inactive:
            blockers.append(f"incomplete discovery: {key}")
    if evidence["networkd"].get("stdout", "").strip() != "active":
        blockers.append("systemd-networkd is not active")
    for key in ("networkManager", "connman", "dhcpcd"):
        if evidence[key].get("stdout", "").strip() == "active":
            blockers.append(f"competing network manager: {key}")
    configs = []
    for path in sorted(config_root.glob("*")):
        if path.suffix not in (".yaml", ".yml"):
            continue
        if path.is_symlink() or not path.is_file():
            blockers.append(f"unsupported Netplan entry: {path.name}")
            continue
        try:
            configs.append({"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                            "mode": oct(path.stat().st_mode & 0o777)})
        except OSError as error:
            blockers.append(f"cannot inspect Netplan entry {path.name}: {error}")
    if not configs:
        blockers.append("no readable persistent Netplan configuration")
    return {"schemaVersion": 1, "kind": "single-nic-evidence", "interface": interface,
            "collectedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "migrationSupported": False, "blockers": blockers,
            "netplanFiles": configs, "evidence": evidence}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", required=True)
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("discovery requires the Linux host; no host changes were made")
    print(json.dumps(collect(args.interface), indent=2))
    # Success means evidence was collected, never readiness for a cutover.
