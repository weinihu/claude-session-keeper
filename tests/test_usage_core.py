"""Usage: emails per account, current account, exact reset times from transcripts."""
import datetime as dt
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
H = 3600 * 1000


def iso(ms):
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc).isoformat().replace("+00:00", "Z")


class UsageCoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        b = Path(self.tmp.name)
        self.now = int(time.time() * 1000)
        app, vault, proj = b / "Claude", b / "vault", b / "projects" / "-demo"
        for p in (app / "claude-code-sessions" / "acc" / "org-a", vault, proj, b / "nobackups"):
            p.mkdir(parents=True)
        (app / "config.json").write_text(json.dumps({"lastKnownAccountUuid": "acc"}))
        now = self.now
        # A signed in 30 h ago and hit the weekly limit; B signed in 2 h ago (latest sample = current)
        samples = [
            {"t": now - 30 * H + 5 * 60000, "org": "org-a", "u": {"fh": 40, "sd": 90}},
            {"t": now - 29 * H, "org": "org-a", "u": {"fh": 60, "sd": 100}},
            {"t": now - 28 * H, "org": "org-a", "u": {"fh": 70, "sd": 100}},
            {"t": now - 2 * H + 5 * 60000, "org": "org-b", "u": {"fh": 10, "sd": 20}},
            {"t": now - 1 * H, "org": "org-b", "u": {"fh": 30, "sd": 22}},
        ]
        (app / "plan-usage-history.json").write_text(json.dumps({"version": 2, "samples": samples}))
        self.weekly_reset_a = now + 2 * 24 * H      # Claude said: A's week resets in 2 days
        lines = [
            {"type": "attachment", "timestamp": iso(now - 30 * H), "userEmail": 1,
             "rendered": "# userEmail\nThe user's email address is a@example.com. Use it only..."},
            {"type": "attachment", "timestamp": iso(now - 29 * H - 10 * 60000), "userEmail": 1,
             "rendered": "The user's email address is a@example.com."},
            {"type": "assistant", "timestamp": iso(now - 29 * H),
             "apiErrorParams": {"rate_limit_info": {"rateLimitType": "seven_day", "status": "rejected",
                                                    "resetsAt": (self.weekly_reset_a - 7 * 24 * H) // 1000}}},
            {"type": "attachment", "timestamp": iso(now - 2 * H), "userEmail": 1,
             "rendered": "The user's email address is b@example.com."},
            {"type": "attachment", "timestamp": iso(now - 1 * H - 10 * 60000), "userEmail": 1,
             "rendered": "The user's email address is b@example.com."},
        ]
        (proj / "s.jsonl").write_text("\n".join(json.dumps(x) for x in lines) + "\n")
        self.env = dict(os.environ, CSV_APP_DIR=str(app), CSV_VAULT=str(vault),
                        CSV_SESS_ROOT=str(app / "claude-code-sessions"), CSV_APP_CONFIG=str(app / "config.json"),
                        CSV_PROJECTS=str(b / "projects"), CSV_USAGE_SRC=str(app / "plan-usage-history.json"),
                        CSV_CLAUDE_JSON=str(b / "none.json"), CSV_CLAUDE_JSON_BACKUPS=str(b / "nobackups"),
                        CSV_IGNORE_RUNNING="1", CSV_LANG="en")

    def tearDown(self):
        self.tmp.cleanup()

    def usage(self):
        r = subprocess.run([sys.executable, str(CORE), "usage", "--json"], env=self.env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return {a["org"]: a for a in json.loads(r.stdout)["accounts"]}

    def test_emails_current_and_exact_weekly_reset(self):
        acc = self.usage()
        self.assertEqual(acc["org-a"]["email"], "a@example.com")
        self.assertEqual(acc["org-b"]["email"], "b@example.com")
        self.assertTrue(acc["org-b"]["current"])
        self.assertFalse(acc["org-a"]["current"])
        # the weekly reset Claude reported a week ago repeats every 7 days
        self.assertTrue(acc["org-a"]["weeklyResetExact"])
        self.assertEqual(acc["org-a"]["weeklyResetAt"] // 1000, self.weekly_reset_a // 1000)
        self.assertIn("week", acc["org-a"]["weeklyReset"]["week"])
        # B never hit a limit: no exact time, but still an estimate
        self.assertFalse(acc["org-b"]["weeklyResetExact"])

    def test_second_run_reads_only_new_lines(self):
        self.usage()
        events = json.loads((Path(self.env["CSV_VAULT"]) / "transcript-events.json").read_text())
        self.assertTrue(events["files"])
        self.usage()   # must not duplicate events
        again = json.loads((Path(self.env["CSV_VAULT"]) / "transcript-events.json").read_text())
        self.assertEqual(len(events["emails"]), len(again["emails"]))


if __name__ == "__main__":
    unittest.main()
