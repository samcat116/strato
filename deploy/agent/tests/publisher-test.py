#!/usr/bin/env python3
"""Exercise release failure/retry behavior with a local GitHub CLI fake."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ["FAKE_ROOT"])
p = root / "state.json"
s = json.loads(p.read_text())
a = sys.argv[1:]
s["calls"].append(a)
def done(code=0, output=""):
    p.write_text(json.dumps(s))
    print(output)
    sys.exit(code)
if a[:2] == ["release", "view"]:
    if not s.get("exists"): done(1)
    key = a[a.index("--json")+1]
    done(output=(str(s["draft"]).lower() if key == "isDraft" else s["target"]))
if a[0] == "api":
    if "matching-refs" in a[1]:
        done(output=("refs/tags/main-aaaaaaaaaaaa" if s.get("tagSHA") else ""))
    done(output=s.get("tagSHA", ""))
if a[:2] == ["release", "create"]:
    if s.get("exists"): done(1)
    s.update(exists=True, draft=True, target=a[a.index("--target")+1])
    done()
if a[:2] == ["release", "upload"]:
    for source in a[3:]:
        if source.startswith("--"): continue
        shutil.copyfile(source, root / "remote" / pathlib.Path(source).name)
        if s.pop("failUpload", False): done(1)
    done()
if a[:2] == ["release", "edit"]:
    s["draft"] = False
    s["tagSHA"] = s["target"]
    if s.pop("uncertainEdit", False): done(1)
    done()
if a[:2] == ["release", "download"]:
    name = a[a.index("--pattern")+1]
    source = root / "remote" / name
    if not source.exists(): done(1)
    shutil.copyfile(source, pathlib.Path(a[a.index("--dir")+1]) / name)
    done()
done(99)
'''


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "remote").mkdir()
        (self.root / "bin").mkdir()
        fake = self.root / "bin/gh"
        fake.write_text(FAKE)
        fake.chmod(0o755)
        (self.root / "deploy").mkdir()
        shutil.copytree(ROOT, self.root / "deploy/agent")
        (self.root / "agent-downloads").mkdir()
        for name in ("strato-agent-linux-x86_64.tar.gz", "strato-agent-linux-arm64.tar.gz",
                     "strato-agent-linux-x86_64.tar.gz.sha256", "strato-agent-linux-arm64.tar.gz.sha256",
                     "agent-manifest.json"):
            (self.root / "agent-downloads" / name).write_text("fixture")
        self.write({"calls": []})
        self.env = dict(os.environ, FAKE_ROOT=str(self.root), GITHUB_SHA="a" * 40,
                        GITHUB_REPOSITORY="samcat116/strato",
                        PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])

    def write(self, state):
        (self.root / "state.json").write_text(json.dumps(state))

    def state(self):
        return json.loads((self.root / "state.json").read_text())

    def run_publish(self, succeeds=True):
        result = subprocess.run(["bash", "deploy/agent/publish-main-release.sh"], cwd=self.root,
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)

    def test_draft_without_tag_publishes_and_does_not_move_latest(self):
        self.run_publish()
        state = self.state()
        self.assertFalse(state["draft"])
        self.assertEqual(state["tagSHA"], "a" * 40)
        for call in state["calls"]:
            if call[:2] in (["release", "create"], ["release", "edit"]):
                self.assertIn("--latest=false", call)
                self.assertIn("--prerelease", call)

    def test_published_retry_compares_and_refuses_changed_bytes(self):
        self.run_publish()
        count = len(self.state()["calls"])
        self.run_publish()
        later = self.state()["calls"][count:]
        self.assertFalse(any(c[:2] == ["release", "upload"] for c in later))
        (self.root / "agent-downloads/agent-manifest.json").write_text("different")
        self.run_publish(False)

    def test_partial_upload_remains_draft_and_can_be_repaired(self):
        self.write({"calls": [], "failUpload": True})
        self.run_publish(False)
        self.assertTrue(self.state()["draft"])
        self.run_publish()
        self.assertFalse(self.state()["draft"])

    def test_uncertain_publish_is_read_back_before_retry(self):
        self.write({"calls": [], "uncertainEdit": True})
        self.run_publish(False)
        self.assertFalse(self.state()["draft"])
        count = len(self.state()["calls"])
        self.run_publish()
        self.assertFalse(any(c[:2] == ["release", "edit"] for c in self.state()["calls"][count:]))

    def test_foreign_tag_and_draft_target_are_refused(self):
        for extra in ({"tagSHA": "b" * 40}, {"target": "b" * 40}):
            self.write(dict({"calls": [], "exists": True, "draft": True, "target": "a" * 40}, **extra))
            self.run_publish(False)
            self.assertFalse(any(c[:2] == ["release", "upload"] for c in self.state()["calls"]))


if __name__ == "__main__":
    unittest.main()
