"""Exact mode: reads official usage with Claude Code's token, rate-limited, never stores the token."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "claude_sessions.py"
TOKEN = "sk-ant-oat-TEST-SECRET-123"


class Handler(http.server.BaseHTTPRequestHandler):
    hits = []

    def do_GET(self):
        Handler.hits.append({k.lower(): v for k, v in self.headers.items()})
        body = {"five_hour": {"utilization": 37.0, "resets_at": "2099-01-01T05:00:00+00:00"},
                "seven_day": {"utilization": 64.0, "resets_at": "2099-01-05T17:00:00+00:00"}}
        out = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


class ExactModeTests(unittest.TestCase):
    def setUp(self):
        Handler.hits = []
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.tmp = tempfile.TemporaryDirectory()
        b = Path(self.tmp.name)
        (b / "vault").mkdir()
        (b / "creds.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": TOKEN,
                                                                    "expiresAt": int(time.time() * 1000) + 3600_000}}))
        (b / "claude.json").write_text(json.dumps({"oauthAccount": {"organizationUuid": "org-x",
                                                                    "emailAddress": "x@example.com"}}))
        self.vault = b / "vault"
        self.env = dict(os.environ, CSV_VAULT=str(self.vault), CSV_CREDENTIALS_FILE=str(b / "creds.json"),
                        CSV_CLAUDE_JSON=str(b / "claude.json"), CSV_CLAUDE_JSON_BACKUPS=str(b / "none"),
                        CSV_USAGE_URL=f"http://127.0.0.1:{self.srv.server_port}/api/oauth/usage",
                        CSV_USAGE_SRC=str(b / "none.json"), CSV_PROJECTS=str(b / "none"),
                        CSV_SESS_ROOT=str(b / "none"), CSV_APP_CONFIG=str(b / "none.json"),
                        CSV_IGNORE_RUNNING="1", CSV_LANG="en")

    def tearDown(self):
        self.srv.shutdown()
        self.tmp.cleanup()

    def core(self, *args):
        r = subprocess.run([sys.executable, str(CORE), *args], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_off_by_default(self):
        self.core("live", "--json")
        self.assertEqual(Handler.hits, [])

    def test_reads_exact_numbers_and_never_stores_token(self):
        st = json.loads(self.core("live", "--enable", "on", "--json"))
        self.assertTrue(st["ok"])
        self.assertEqual(st["fiveHour"], 37.0)
        self.assertEqual(len(Handler.hits), 1)
        h = Handler.hits[0]
        self.assertEqual(h.get("anthropic-beta"), "oauth-2025-04-20")
        self.assertTrue(h.get("user-agent", "").startswith("session-keeper/"))
        # rate limit: a second call within 5 minutes does not hit the server
        self.core("live", "--json")
        self.assertEqual(len(Handler.hits), 1)
        # the token is nowhere in the vault
        for p in self.vault.rglob("*"):
            if p.is_file():
                self.assertNotIn(TOKEN, p.read_text(errors="ignore"), p.name)
        # usage marks the signed-in account's numbers as exact
        acc = {a["org"]: a for a in json.loads(self.core("usage", "--json"))["accounts"]}
        self.assertTrue(acc["org-x"]["weeklyResetExact"])
        self.assertEqual(acc["org-x"]["weekly"], 64)


if __name__ == "__main__":
    unittest.main()
