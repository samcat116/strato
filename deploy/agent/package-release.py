#!/usr/bin/env python3
"""Package bare-host main agents in the existing agent-manifest v1 contract."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile


def package(binary, arch, sha, wire_version, epoch, output):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("expected a full lowercase commit SHA")
    if arch not in ("x86_64", "arm64") or wire_version <= 0 or epoch < 0:
        raise ValueError("unsupported architecture, wire version or timestamp")
    version = "main-" + sha[:12]
    probe = subprocess.run([str(binary.resolve()), "--version"], check=True,
                           text=True, capture_output=True, timeout=30).stdout.strip()
    if probe != f"{version} ({sha})":
        raise ValueError(f"binary identity mismatch: {probe!r}")
    name = f"strato-agent-linux-{arch}.tar.gz"
    output.mkdir(parents=True, exist_ok=True)
    # No host paths, uid/gid, wall clock or gzip filename in the archive.
    with (output / name).open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=epoch) as zipped:
            with tarfile.open(fileobj=zipped, mode="w") as archive:
                data = binary.read_bytes()
                member = tarfile.TarInfo("strato-agent")
                member.mode, member.mtime, member.size = 0o755, epoch, len(data)
                archive.addfile(member, io.BytesIO(data))
    digest = hashlib.sha256((output / name).read_bytes()).hexdigest()
    (output / (name + ".sha256")).write_text(f"{digest}  {name}\n")
    entry = {"os": "linux", "arch": arch, "asset": name, "sha256": digest,
             "size": (output / name).stat().st_size, "agentBinaryPath": "strato-agent"}
    metadata = {"schemaVersion": 1, "version": version, "gitSHA": sha,
                "workloadWireVersion": wire_version, "assets": [entry]}
    (output / f"agent-linux-{arch}.json").write_text(json.dumps(metadata, indent=2) + "\n")


def manifest(directory, repository):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("expected OWNER/REPO")
    merged = None
    for arch in ("x86_64", "arm64"):
        part = json.loads((directory / f"agent-linux-{arch}.json").read_text())
        if merged is None:
            merged = {key: part[key] for key in
                      ("schemaVersion", "version", "gitSHA", "workloadWireVersion")}
            merged["assets"] = []
        if any(part[key] != merged[key] for key in
               ("schemaVersion", "version", "gitSHA", "workloadWireVersion")):
            raise ValueError("platform build identities differ")
        asset, = part["assets"]
        name = f"strato-agent-linux-{arch}.tar.gz"
        if asset["arch"] != arch or asset["os"] != "linux" or asset["asset"] != name:
            raise ValueError("platform asset mismatch")
        data = (directory / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != asset["sha256"] or len(data) != asset["size"]:
            raise ValueError("archive does not match metadata")
        if (directory / (name + ".sha256")).read_text() != f'{asset["sha256"]}  {name}\n':
            raise ValueError("checksum sidecar does not match metadata")
        asset["url"] = (f'https://github.com/{repository}/releases/download/'
                        f'{merged["version"]}/{name}')
        merged["assets"].append(asset)
    (directory / "agent-manifest.json").write_text(json.dumps(merged, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("package")
    pack.add_argument("--binary", type=Path, required=True)
    pack.add_argument("--arch", required=True)
    pack.add_argument("--sha", required=True)
    pack.add_argument("--wire-version", type=int, required=True)
    pack.add_argument("--epoch", type=int, required=True)
    pack.add_argument("--output", type=Path, required=True)
    merge = commands.add_parser("manifest")
    merge.add_argument("--directory", type=Path, required=True)
    merge.add_argument("--repository", required=True)
    args = vars(parser.parse_args())
    command = args.pop("command")
    (package if command == "package" else manifest)(**args)
