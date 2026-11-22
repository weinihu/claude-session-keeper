"""Create a fake Claude data folder + vault for screenshots and UI smoke tests.

Usage: python tests/make_demo.py <dir> [zh|en]
Prints the environment variables (KEY=VALUE per line) that point the core at the demo data.
"""
import json
import os
import sys
import time
import uuid

D = os.path.abspath(sys.argv[1])
lang = sys.argv[2] if len(sys.argv) > 2 else "zh"
now = int(time.time() * 1000)
H = 3600 * 1000
ACC = "7c1e2f40-1111-4a2b-9c3d-000000000001"
O1, O2, O3, O4 = (f"{c * 8}-0000-4000-8000-00000000000{c}" for c in "abcd")

app = os.path.join(D, "Claude")
sess = os.path.join(app, "claude-code-sessions", ACC, O1)
vault = os.path.join(D, "vault")
projects = os.path.join(D, "projects")
for p in (sess, os.path.join(vault, "sessions"), projects, os.path.join(D, "nobackups")):
    os.makedirs(p, exist_ok=True)

chats = [("web-app", "Fix login redirect loop", 1), ("api", "Rate limiter design", 3),
         ("blog", "Draft: launch post", 8), ("cli-tool", "Release v2.0 checklist", 20)]
for i, (proj, title, hrs) in enumerate(chats):
    cwd = os.path.join(D, "Projects", proj)
    os.makedirs(cwd, exist_ok=True)
    cid, sid, t = str(uuid.uuid4()), "local_" + str(uuid.uuid4()), now - hrs * H
    m = {"sessionId": sid, "cliSessionId": cid, "cwd": cwd, "createdAt": t - H, "lastActivityAt": t,
         "title": title, "model": "claude-opus-5-5", "isArchived": False}
    if i < 2:
        json.dump(m, open(os.path.join(sess, sid + ".json"), "w"))
    json.dump(dict(m, _vault={"fromAccount": ACC}), open(os.path.join(vault, "sessions", sid + ".json"), "w"))
    pd = os.path.join(projects, "".join(c if c.isalnum() else "-" for c in cwd))
    os.makedirs(pd, exist_ok=True)
    open(os.path.join(pd, cid + ".jsonl"), "w").write(json.dumps({"type": "user", "cwd": cwd, "message": {"content": title}}) + "\n")

json.dump({"lastKnownAccountUuid": ACC}, open(os.path.join(app, "config.json"), "w"))
samples = []
for org, seq in [(O2, [(-120, 0, 0), (-118, 30, 6), (-9, 100, 100)]), (O3, [(-60, 0, 0), (-58, 20, 4), (-30, 100, 38)]),
                 (O1, [(-100, 0, 0), (-99, 10, 3), (-3, 40, 47), (-1, 72, 52)]), (O4, [(-26, 0, 20)])]:
    samples += [{"t": now + h * H, "org": org, "u": {"fh": fh, "sd": sd}} for h, fh, sd in seq]
json.dump({"version": 2, "samples": sorted(samples, key=lambda x: x["t"])},
          open(os.path.join(app, "plan-usage-history.json"), "w"))
json.dump({"oauthAccount": {"organizationUuid": O1, "emailAddress": "alex.work@example.com"}},
          open(os.path.join(D, "claude.json"), "w"))
names = {"zh": ("工作号", "个人号", "副业号"), "en": ("Work", "Personal", "Side project")}[lang]
json.dump({O1: {"name": names[0], "email": "alex.work@example.com"},
           O2: {"name": names[1], "email": "alex.chen@example.com"},
           O3: {"name": names[2], "email": "studio.alex@example.com"}},
          open(os.path.join(vault, "accounts.json"), "w"), ensure_ascii=False)
cfg = json.load(open(os.path.join(os.path.dirname(__file__), "..", "config.default.json")))
json.dump(cfg, open(os.path.join(vault, "config.json"), "w"))
open(os.path.join(vault, "last-run"), "w").close()

env = {"CSV_APP_DIR": app, "CSV_VAULT": vault, "CSV_SESS_ROOT": os.path.join(app, "claude-code-sessions"),
       "CSV_APP_CONFIG": os.path.join(app, "config.json"), "CSV_PROJECTS": projects,
       "CSV_USAGE_SRC": os.path.join(app, "plan-usage-history.json"), "CSV_CLAUDE_JSON": os.path.join(D, "claude.json"),
       "CSV_CLAUDE_JSON_BACKUPS": os.path.join(D, "nobackups"), "CSV_IGNORE_RUNNING": "1", "CSV_LANG": lang}
for k, v in env.items():
    print(f"{k}={v}")
