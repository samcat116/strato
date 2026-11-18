#!/usr/bin/env python3
import importlib.util
import json
import re
import os
import subprocess
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("package-release")
discovery = load("single-nic-discover")


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sha = "a" * 40
        self.binary = self.root / "agent"
        self.binary.write_text(f'#!/bin/sh\necho "main-{self.sha[:12]} ({self.sha})"\n')
        self.binary.chmod(0o755)

    def package(self, arch="x86_64", sha=None, output=None):
        release.package(self.binary, arch, sha or self.sha, 72, 1000, output or self.root)

    def test_packages_current_protocol_major_from_authoritative_source(self):
        source = ROOT.parents[1] / "shared/Sources/StratoShared/AgentProtocolCompatibility.swift"
        result = subprocess.run(
            ["python3", str(ROOT / "package-release.py"), "wire-version", "--source", str(source)],
            check=True, capture_output=True, text=True)
        major = release.current_wire_version(source)
        self.assertEqual(result.stdout, f"{major}\n")
        release.package(self.binary, "arm64", self.sha, major, 1000, self.root)
        metadata = json.loads((self.root / "agent-linux-arm64.json").read_text())
        self.assertEqual(metadata["workloadWireVersion"], major)

    def test_protocol_major_tracks_future_values(self):
        source = self.root / "AgentProtocolCompatibility.swift"
        source.write_text("public enum AgentProtocolCompatibility {\n    public static let major: UInt32 = 9\n}\n")
        self.assertEqual(release.current_wire_version(source), 9)

    def test_protocol_major_rejects_missing_ambiguous_and_invalid_values(self):
        source = self.root / "AgentProtocolCompatibility.swift"
        declaration = "    public static let major: UInt32 = 1\n"
        for content in ("", "public static let currentVersion = 72\n", declaration * 2,
                        declaration.replace("= 1", "= 0"), declaration.replace("= 1", "= -1"),
                        declaration.replace("= 1", "= 4294967296"),
                        declaration.replace("= 1", "= otherConstant")):
            with self.subTest(content=content):
                source.write_text(content)
                with self.assertRaises(ValueError):
                    release.current_wire_version(source)

    def test_release_script_rejects_missing_major_before_building(self):
        # Execute the production shell entry point with only identity commands
        # stubbed. The obsolete WireProtocol sed lookup would continue to build.
        checkout = self.root / "checkout"
        tools = self.root / "tools"
        tools.mkdir()
        (checkout / "deploy/agent").mkdir(parents=True)
        (checkout / "agent/Sources/StratoAgentRuntime").mkdir(parents=True)
        source_dir = checkout / "shared/Sources/StratoShared"
        source_dir.mkdir(parents=True)
        (source_dir / "AgentProtocolCompatibility.swift").write_text("// missing major\n")
        (checkout / "deploy/agent/package-release.py").write_text((ROOT / "package-release.py").read_text())
        for name, output in (("git", self.sha), ("uname", "x86_64")):
            tool = tools / name
            tool.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n")
            tool.chmod(0o755)
        result = subprocess.run(["bash", str(ROOT / "build-release.sh"), "x86_64", "out"],
                                cwd=checkout, capture_output=True, text=True,
                                env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                                     "GITHUB_SHA": self.sha, "SWIFTPM_CACHE_PATH": str(self.root / "cache")})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected exactly one positive UInt32", result.stderr)
        self.assertFalse((checkout / "agent/Sources/StratoAgentRuntime/CompiledBuildInfo.swift").exists())

    def test_deterministic_archive_and_manifest_contract(self):
        self.package()
        other = self.root / "other"
        self.package(output=other)
        name = "strato-agent-linux-x86_64.tar.gz"
        self.assertEqual((self.root / name).read_bytes(), (other / name).read_bytes())
        with tarfile.open(self.root / name) as archive:
            self.assertEqual(archive.getnames(), ["strato-agent"])
            self.assertEqual(archive.getmember("strato-agent").mode, 0o755)
            self.assertEqual(archive.extractfile("strato-agent").read(), self.binary.read_bytes())
        self.package("arm64")
        release.manifest(self.root, "samcat116/strato")
        manifest = json.loads((self.root / "agent-manifest.json").read_text())
        self.assertEqual(manifest["version"], "main-aaaaaaaaaaaa")
        self.assertEqual(manifest["gitSHA"], self.sha)
        self.assertEqual(manifest["workloadWireVersion"], 72)
        self.assertEqual([a["arch"] for a in manifest["assets"]], ["x86_64", "arm64"])
        self.assertTrue(all(a["agentBinaryPath"] == "strato-agent" for a in manifest["assets"]))

    def test_main_deployments_keep_the_commit_identity(self):
        # Container environment takes precedence over CompiledBuildInfo. Check
        # both backend and frontend image builds, not just the bare-host probe.
        workflow = (ROOT.parents[1] / ".github/workflows/main-build.yaml").read_text()
        image_versions = re.findall(r"^            STRATO_VERSION=(.*)$", workflow, re.M)
        self.assertEqual(image_versions, ["${{ steps.meta.outputs.version }}"] * 2)
        compose = (ROOT.parents[1] / "deploy/compose/docker-compose.yml").read_text()
        self.assertIsNone(re.search(r"^\s+STRATO_VERSION:", compose, re.M))
        helm = (ROOT.parents[1] / "helm/strato-control-plane/templates/deployment.yaml").read_text()
        self.assertNotIn("- name: STRATO_VERSION", helm)

    def test_rejects_wrong_binary_identity(self):
        with self.assertRaises(ValueError):
            self.package(sha="b" * 40)

    def test_requires_both_platforms(self):
        self.package()
        with self.assertRaises(FileNotFoundError):
            release.manifest(self.root, "samcat116/strato")

    def test_rejects_platform_identity_mismatch_and_corruption(self):
        self.package()
        self.package("arm64")
        part = self.root / "agent-linux-arm64.json"
        original = part.read_text()
        part.write_text(original.replace('"workloadWireVersion": 72', '"workloadWireVersion": 73'))
        with self.assertRaises(ValueError):
            release.manifest(self.root, "samcat116/strato")
        part.write_text(original)
        archive = self.root / "strato-agent-linux-arm64.tar.gz"
        archive.write_bytes(b"truncated")
        with self.assertRaises(ValueError):
            release.manifest(self.root, "samcat116/strato")

    def test_discovery_reports_failures_and_never_permits_migration(self):
        calls = []

        def run(argv):
            calls.append(argv)
            return {"exitCode": None, "error": "unavailable"}

        report = discovery.collect("ens18", run=run, config_root=self.root)
        self.assertFalse(report["migrationSupported"])
        self.assertIn("incomplete discovery: link", report["blockers"])
        self.assertIn("no readable persistent Netplan configuration", report["blockers"])
        self.assertTrue(all("apply" not in argv and "add-port" not in argv for argv in calls))
        self.assertIn(["ip", "-j", "-6", "route", "show", "table", "all"], calls)

    def test_discovery_refuses_names_before_running_commands(self):
        for interface in ("../ens18", "ens18;reboot", "-x", "a" * 16):
            with self.assertRaises(ValueError):
                discovery.collect(interface, run=lambda _: self.fail("ran a command"))

    def test_discovery_exposes_competing_managers_and_foreign_config(self):
        (self.root / "foreign.yaml").symlink_to(self.binary)
        (self.root / "host.yaml").write_text("network: {version: 2}\n")
        report = discovery.collect("ens18", run=lambda _: {"exitCode": 0, "stdout": "active\n"},
                                   config_root=self.root)
        self.assertFalse(report["migrationSupported"])
        self.assertIn("competing network manager: networkManager", report["blockers"])
        self.assertIn("unsupported Netplan entry: foreign.yaml", report["blockers"])
        self.assertEqual(len(report["netplanFiles"]), 1)


if __name__ == "__main__":
    unittest.main()
