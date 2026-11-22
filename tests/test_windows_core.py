import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "claude_sessions.py"


class WindowsCoreSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.app = self.base / "Claude"
        self.sessions = self.app / "claude-code-sessions"
        self.account = self.sessions / "account-a" / "org-a"
        self.projects = self.base / "claude" / "projects"
        self.vault = self.base / "claude" / "session-vault"
        self.account.mkdir(parents=True)
        self.projects.mkdir(parents=True)
        (self.app / "config.json").write_text(
            json.dumps({"lastKnownAccountUuid": "account-a"}), encoding="utf-8")
        (self.account / "local_session-a.json").write_text(json.dumps({
            "sessionId": "session-a",
            "cliSessionId": "cli-a",
            "title": "Example",
            "cwd": str(self.base),
            "createdAt": 1,
            "lastActivityAt": 2,
        }), encoding="utf-8")
        self.env = os.environ.copy()
        self.env.update({
            "CSV_APP_DIR": str(self.app),
            "CSV_SESS_ROOT": str(self.sessions),
            "CSV_APP_CONFIG": str(self.app / "config.json"),
            "CSV_PROJECTS": str(self.projects),
            "CSV_VAULT": str(self.vault),
            "CSV_TOOL_CONFIG": str(self.vault / "config.json"),
            "CSV_IGNORE_RUNNING": "1",
        })
        (self.vault).mkdir(parents=True)
        (self.vault / "config.json").write_text("{}", encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def run_core(self, *args):
        return subprocess.run([sys.executable, str(CORE), *args], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def test_status_reads_a_configured_windows_style_data_root(self):
        result = self.run_core("status", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        status = json.loads(result.stdout)
        self.assertTrue(status["dataPathReady"])
        self.assertEqual(status["currentAccount"], "account-a")
        self.assertEqual(status["accounts"][0]["sessions"], 1)

    def test_backup_copies_session_metadata_into_vault(self):
        result = self.run_core("backup")
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = self.vault / "sessions" / "session-a.json"
        self.assertTrue(saved.exists())
        self.assertEqual(json.loads(saved.read_text(encoding="utf-8"))["title"], "Example")


if __name__ == "__main__":
    unittest.main()
