"""End-to-end account switch: A -> B -> A, with the extra folders and edits the real app produces."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "claude_sessions.py"
DAY = 86400 * 1000


class RestoreFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        b = Path(self.tmp.name)
        self.app, self.vault, self.projects = b / "Claude", b / "vault", b / "projects"
        self.proj_dir = b / "work" / "demo"
        self.proj_dir.mkdir(parents=True)
        self.sess = self.app / "claude-code-sessions"
        self.base = int(time.time() * 1000) - 3 * DAY
        self.env = dict(os.environ, CSV_APP_DIR=str(self.app), CSV_VAULT=str(self.vault),
                        CSV_SESS_ROOT=str(self.sess), CSV_APP_CONFIG=str(self.app / "config.json"),
                        CSV_PROJECTS=str(self.projects), CSV_USAGE_SRC=str(b / "none-usage.json"),
                        CSV_TOOL_CONFIG=str(b / "tool-config.json"), CSV_CLAUDE_JSON=str(b / "none.json"),
                        CSV_CLAUDE_JSON_BACKUPS=str(b / "nobackups"), CSV_IGNORE_RUNNING="1",
                        CSV_NO_GUI="1", CSV_LANG="en")
        (b / "nobackups").mkdir()
        (b / "tool-config.json").write_text(json.dumps({"rebuild_orphans": False}))
        self.sign_in("accA", "orgA")
        for i, name in enumerate(["X", "Z", "W"]):
            self.chat("accA", "orgA", name, self.base + i * 1000)

    def tearDown(self):
        self.tmp.cleanup()

    # -- fake Claude app --------------------------------------------------------------
    def sign_in(self, acc, org):
        (self.sess / acc / org).mkdir(parents=True, exist_ok=True)
        self.app.mkdir(parents=True, exist_ok=True)
        (self.app / "config.json").write_text(json.dumps(
            {"lastKnownAccountUuid": acc, "sshTransportFlagLastAnswer": {"accountUuid": acc, "orgUuid": org}}))

    def transcript(self, cid, age_ms=DAY):
        d = self.projects / __import__("re").sub(r"[^A-Za-z0-9]", "-", str(self.proj_dir))
        d.mkdir(parents=True, exist_ok=True)
        p = d / f"{cid}.jsonl"
        p.write_text(json.dumps({"type": "user", "cwd": str(self.proj_dir), "message": {"content": "hi"}}) + "\n")
        t = time.time() - age_ms / 1000
        os.utime(p, (t, t))

    def chat(self, acc, org, name, at, cid=None, **extra):
        cid = cid or f"cli-{name}"
        self.transcript(cid)
        meta = {"sessionId": f"local_{name}", "cliSessionId": cid, "cwd": str(self.proj_dir),
                "title": name, "createdAt": at, "lastActivityAt": at, **extra}
        self.write(acc, org, meta)
        return meta

    def write(self, acc, org, meta):
        p = self.sess / acc / org / f"{meta['sessionId']}.json"
        p.write_text(json.dumps(meta))

    def read(self, acc, org):
        out = {}
        for p in (self.sess / acc / org).glob("local_*.json"):
            m = json.loads(p.read_text())
            out[m["sessionId"][6:]] = m
        return out

    def run_core(self, *args):
        r = subprocess.run([sys.executable, str(CORE), *args], env=self.env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def pending(self):
        p = self.vault / "pending-switch.json"
        if not p.exists():
            return None
        data = json.loads(p.read_text())
        p.unlink()
        return data

    # -- the flow ---------------------------------------------------------------------
    def test_switch_cycle(self):
        self.run_core("auto")                       # first run: remember the current state
        self.run_core("auto")
        self.assertIsNone(self.pending())

        # switch to B; the app also leaves a stray A/orgB folder with one chat in it
        self.sign_in("accB", "orgB")
        (self.sess / "accA" / "orgB").mkdir(parents=True)
        self.write("accA", "orgB", json.loads((self.sess / "accA" / "orgA" / "local_X.json").read_text()))
        self.run_core("auto")
        self.assertEqual(self.pending()["missing"], 3)
        self.run_core("sync", "--all")
        self.assertEqual(set(self.read("accB", "orgB")), {"X", "Z", "W"})

        # work in B: continue X (Claude forks a new transcript), rename W, delete Z, start Y
        x = self.read("accB", "orgB")["X"]
        self.transcript("cli-X2")
        x.update(cliSessionId="cli-X2", priorCliSessionIds=["cli-X"], lastActivityAt=self.base + DAY)
        self.write("accB", "orgB", x)
        w = self.read("accB", "orgB")["W"]
        time.sleep(1.1)
        w["title"] = "W renamed"
        self.write("accB", "orgB", w)
        (self.sess / "accB" / "orgB" / "local_Z.json").unlink()
        self.chat("accB", "orgB", "Y", self.base + DAY + 5000)
        # the app tidies its stray folder: not a deletion by you
        (self.sess / "accA" / "orgB" / "local_X.json").unlink()
        self.run_core("auto")
        deleted = json.loads((self.vault / "deleted.json").read_text())
        self.assertEqual(set(deleted), {"local_Z"})

        # back to A
        self.sign_in("accA", "orgA")
        self.run_core("auto")
        self.assertEqual(self.pending()["missing"], 2)      # Y is new, X moved on; the rename alone doesn't count
        self.run_core("sync", "--all")
        a = self.read("accA", "orgA")
        self.assertEqual(set(a), {"X", "W", "Y"})
        self.assertEqual(a["X"]["cliSessionId"], "cli-X2")
        self.assertEqual(a["W"]["title"], "W renamed")
        # nothing left to do, and a second restore changes nothing
        out = self.run_core("restore", "--all", "--dry-run")
        self.assertNotIn("[dry run]", out)

        # undo the last restore puts A back as it was
        self.run_core("rollback")
        a = self.read("accA", "orgA")
        self.assertEqual(set(a), {"X", "W"})
        self.assertEqual(a["X"]["cliSessionId"], "cli-X")

    def test_waits_while_a_chat_is_running(self):
        self.run_core("auto")
        self.sign_in("accB", "orgB")
        self.transcript("cli-live", age_ms=10 * 1000)           # a chat answered 10 seconds ago
        self.run_core("auto")
        self.assertIsNone(self.pending())
        self.transcript("cli-live", age_ms=5 * 60 * 1000)       # quiet for 5 minutes
        self.run_core("auto")
        self.assertEqual(self.pending()["missing"], 3)

    def test_many_vanishing_at_once_is_not_a_delete(self):
        for i in range(6):
            self.chat("accA", "orgA", f"M{i}", self.base + 10000 + i)
        self.run_core("auto")
        self.run_core("auto")
        for i in range(6):
            (self.sess / "accA" / "orgA" / f"local_M{i}.json").unlink()
        self.run_core("auto")
        deleted = json.loads((self.vault / "deleted.json").read_text()) if (self.vault / "deleted.json").exists() else {}
        self.assertEqual(deleted, {})
        self.assertTrue((self.vault / "sessions" / "local_M0.json").exists())

    def test_restore_targets_the_folder_claude_shows(self):
        self.run_core("auto")
        self.sign_in("accB", "orgB")
        stray = self.sess / "accB" / "orgA"
        stray.mkdir(parents=True)
        (stray / "local_q.json").write_text(json.dumps({"sessionId": "local_q"}))   # newer, but not shown
        self.run_core("sync")
        self.assertEqual(set(self.read("accB", "orgB")), {"X", "Z", "W"})


if __name__ == "__main__":
    unittest.main()
