#!/usr/bin/env python3
"""Claude Code statusline hook for Session Keeper.

Claude Code passes session JSON on stdin with every update. For Pro/Max accounts it includes
official rate limits (rate_limits.five_hour / seven_day: used_percentage, resets_at).
We keep only those fields (no tokens, no transcript) and print a short status text.
"""
import json
import os
import sys
import time

VAULT = os.environ.get("CSV_VAULT") or os.path.join(os.path.expanduser("~"), ".claude", "session-vault")
OUT = os.path.join(VAULT, "statusline-usage.jsonl")


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    rl = data.get("rate_limits") or {}
    rec = {"t": int(time.time() * 1000), "session": data.get("session_id")}
    for k in ("five_hour", "seven_day"):
        w = rl.get(k) or {}
        if "used_percentage" in w or "resets_at" in w:
            rec[k] = {"used": w.get("used_percentage"), "resets_at": w.get("resets_at")}
    if "five_hour" in rec or "seven_day" in rec:
        os.makedirs(VAULT, exist_ok=True)
        with open(OUT, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        fh, sd = rec.get("five_hour", {}).get("used"), rec.get("seven_day", {}).get("used")
        print(f"5h {fh if fh is not None else '–'}% · 7d {sd if sd is not None else '–'}%")
    else:
        print("")


if __name__ == "__main__":
    main()
