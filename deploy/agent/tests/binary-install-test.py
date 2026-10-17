#!/usr/bin/env python3
"""Run the real install_binary helper with local transport fixtures."""
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BinaryInstallTests(unittest.TestCase):
    def test_requires_verified_runnable_binary_before_replacing_old_one(self):
        source = (ROOT / "install.sh").read_text()
        helpers = "\n".join(re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S)[0]
                            for name in ("sha256_verify", "install_binary"))
        for mode in ("valid", "missing-checksum", "bad-checksum", "bad-binary"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "bin").mkdir()
                destination = root / "bin/strato-agent"
                destination.write_text("previous-binary")
                archive = root / "fixture.tar.gz"
                payload = b"#!/bin/sh\necho 'main-aaaaaaaaaaaa (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)'\n"
                if mode == "bad-binary":
                    payload = b"#!/bin/sh\nexit 1\n"
                with tarfile.open(archive, "w:gz") as tar:
                    member = tarfile.TarInfo("strato-agent")
                    member.size = len(payload)
                    tar.addfile(member, io.BytesIO(payload))
                name = "strato-agent-linux-x86_64.tar.gz"
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                (root / "fixture.sha256").write_text(f"{digest if mode != 'bad-checksum' else '0'*64}  {name}\n")
                harness = r'''
set -euo pipefail
log() { :; }
warn() { :; }
die() { echo "$*" >&2; exit 1; }
curl() {
  local url="$2" destination="$4"
  if [[ "$url" = *.sha256 ]]; then
    [ "$MODE" != missing-checksum ] || return 22
    cp "$FIXTURE/fixture.sha256" "$destination"
  else
    cp "$FIXTURE/fixture.tar.gz" "$destination"
  fi
}
STRATO_AGENT_BIN=""
VERSION=main-aaaaaaaaaaaa
REPO=samcat116/strato
OS=linux
ARCH=x86_64
BIN_DIR="$FIXTURE/bin"
ASSET=strato-agent-linux-x86_64.tar.gz
'''
                result = subprocess.run(["bash", "-c", harness + helpers + "\ninstall_binary\n"],
                                        env=dict(os.environ, FIXTURE=str(root), MODE=mode),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, mode == "valid", result.stdout + result.stderr)
                self.assertEqual(destination.read_bytes(), payload if mode == "valid" else b"previous-binary")


if __name__ == "__main__":
    unittest.main()
