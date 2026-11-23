"""Exact mode guards: off by default, rate limit, activity gate, offline skip, network lock, token never stored."""
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
    usage_hits = []
    egress_ip = "203.0.113.7"

    def do_GET(self):
        if self.path.startswith("/cdn-cgi/trace"):
            out = f"fl=1\nip={Handler.egress_ip}\nts=1\n".encode()
            ctype = "text/plain"
        else:
            Handler.usage_hits.append({k.lower(): v for k, v in self.headers.items()})
            out = json.dumps({"five_hour": {"utilization": 37.0, "resets_at": "2099-01-01T05:00:00+00:00"},
                              "seven_day": {"utilization": 64.0, "resets_at": "2099-01-05T17:00:00+00:00"}}).encode()
            ctype = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


class ExactModeTests(unittest.TestCase):
    def setUp(self):
        Handler.usage_hits, Handler.egress_ip = [], "203.0.113.7"
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.tmp = tempfile.TemporaryDirectory()
        b = self.base = Path(self.tmp.name)
        (b / "vault").mkdir()
        (b / "projects" / "p").mkdir(parents=True)
        (b / "creds.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": TOKEN,
                                                                    "expiresAt": int(time.time() * 1000) + 3600_000}}))
        (b / "claude.json").write_text(json.dumps({"oauthAccount": {"organizationUuid": "org-x",
                                                                    "emailAddress": "x@example.com"}}))
        self.vault = b / "vault"
        port = self.srv.server_port
        self.env = dict(os.environ, CSV_VAULT=str(self.vault), CSV_CREDENTIALS_FILE=str(b / "creds.json"),
                        CSV_CLAUDE_JSON=str(b / "claude.json"), CSV_CLAUDE_JSON_BACKUPS=str(b / "none"),
                        CSV_USAGE_URL=f"http://127.0.0.1:{port}/api/oauth/usage",
                        CSV_EGRESS_URL=f"http://127.0.0.1:{port}/cdn-cgi/trace", CSV_LOCAL_SIG="wifi-A",
                        CSV_USAGE_SRC=str(b / "none.json"), CSV_PROJECTS=str(b / "projects"),
                        CSV_SESS_ROOT=str(b / "none"), CSV_APP_CONFIG=str(b / "none.json"),
                        CSV_IGNORE_RUNNING="1", CSV_LANG="en")

    def tearDown(self):
        self.srv.shutdown()
        self.tmp.cleanup()

    def core(self, *args, **env):
        r = subprocess.run([sys.executable, str(CORE), *args], env=dict(self.env, **env),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def live(self, *args, **env):
        return json.loads(self.core("live", "--json", *args, **env))

    def make_due(self):
        """Pretend the 10-minute interval has passed."""
        p = self.vault / "live-status.json"
        st = json.loads(p.read_text())
        st["lastAttempt"] = st["nextAt"] = 0
        st["lastOk"] = int(time.time() * 1000) - 20 * 60 * 1000
        p.write_text(json.dumps(st))

    def touch_transcript(self):
        (self.base / "projects" / "p" / "s.jsonl").write_text("{}\n")

    def test_off_by_default(self):
        self.live()
        self.assertEqual(Handler.usage_hits, [])

    def test_reads_exact_numbers_and_never_stores_token(self):
        st = self.live("--enable", "on")
        self.assertTrue(st["ok"])
        self.assertEqual(st["fiveHour"], 37.0)
        self.assertEqual(st["lockedIp"], "203.0.*.*")
        h = Handler.usage_hits[0]
        self.assertEqual(h.get("anthropic-beta"), "oauth-2025-04-20")
        self.assertTrue(h.get("user-agent", "").startswith("session-keeper/"))
        self.live()                                    # within 10 minutes: no request
        self.assertEqual(len(Handler.usage_hits), 1)
        for p in self.vault.rglob("*"):
            if p.is_file():
                self.assertNotIn(TOKEN, p.read_text(errors="ignore"), p.name)
        acc = {a["org"]: a for a in json.loads(self.core("usage", "--json"))["accounts"]}
        self.assertTrue(acc["org-x"]["weeklyResetExact"])
        self.assertEqual(acc["org-x"]["weekly"], 64)

    def test_no_request_when_idle_then_reads_after_activity(self):
        self.live("--enable", "on")
        self.make_due()
        self.live()                                    # nothing used since the last read
        self.assertEqual(len(Handler.usage_hits), 1)
        self.touch_transcript()
        self.live()
        self.assertEqual(len(Handler.usage_hits), 2)

    def test_network_change_turns_it_off_without_a_request(self):
        self.live("--enable", "on")
        self.make_due()
        self.touch_transcript()
        st = self.live(CSV_LOCAL_SIG="vpn-B")
        self.assertFalse(st["enabled"])
        self.assertEqual(st["error"], "env_changed")
        self.assertEqual(len(Handler.usage_hits), 1)

    def test_egress_ip_change_turns_it_off(self):
        self.live("--enable", "on")
        self.make_due()
        self.touch_transcript()
        Handler.egress_ip = "198.51.100.9"
        st = self.live()
        self.assertFalse(st["enabled"])
        self.assertEqual(st["error"], "env_changed")
        self.assertEqual(len(Handler.usage_hits), 1)

    def test_offline_skips_and_stays_on(self):
        self.live("--enable", "on")
        self.make_due()
        self.touch_transcript()
        st = self.live(CSV_EGRESS_URL="http://127.0.0.1:9/none")
        self.assertTrue(st["enabled"])
        self.assertEqual(st["error"], "offline")
        self.assertEqual(len(Handler.usage_hits), 1)


if __name__ == "__main__":
    unittest.main()
