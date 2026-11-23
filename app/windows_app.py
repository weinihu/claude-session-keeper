#!/usr/bin/env python3
"""Claude 换号助手 / Session Keeper for Claude — Windows front end.

Same pages as the macOS app (Overview, Usage, Chats, Settings), built with tkinter so it ships
as a single .exe. All the work is done by the shared core, claude_sessions.py.
"""
import importlib
import json
import locale
import os
from pathlib import Path
import subprocess
import sys
import queue
import threading
import time
import webbrowser
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
APPDATA = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
SETTINGS_DIR = APPDATA / "SessionKeeper"
PATHS_FILE = SETTINGS_DIR / "paths.json"
INSTALL_FILE = SETTINGS_DIR / "install.json"
VERSION = "1.2.0"
GITHUB_URL = "https://github.com/weinihu/claude-session-keeper"
AD_URL = "https://tutu8.shop"

# ------------------------------------------------------------------ look & feel
BG = "#F7F5F2"
SIDEBAR = "#EFEAE5"
CARD = "#FFFFFF"
BORDER = "#E8E2DC"
TEXT = "#211D1A"
MUTED = "#7B726B"
FAINT = "#ADA49C"
BRAND = "#E5764A"
BRAND_SOFT = "#FBE7DD"
TRACK = "#EEEAE6"
AVATAR_COLORS = ["#E5764A", "#5C8CD9", "#6BAE73", "#9E73CC", "#D99E40", "#4DA6B3"]


def load_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def is_zh():
    lang = (os.environ.get("CSV_LANG") or locale.getlocale()[0] or "").lower()
    return lang.startswith(("zh", "chinese"))


def tr(zh, en):
    return zh if is_zh() else en


def font(size=10, weight="normal"):
    family = "Microsoft YaHei UI" if is_zh() else "Segoe UI"
    if os.name != "nt":
        family = "PingFang SC" if is_zh() else "Helvetica Neue"
    return (family, size, weight)


def usage_color(v):
    v = v or 0
    return "#E0483E" if v >= 90 else ("#EE9334" if v >= 60 else "#4CB561")


def short_time(ms):
    if not ms:
        return "—"
    t = time.localtime(ms / 1000)
    if time.strftime("%Y%m%d", t) == time.strftime("%Y%m%d"):
        return time.strftime("%H:%M", t)
    return time.strftime(tr("%m月%d日 %H:%M", "%b %d, %H:%M"), t)


# ------------------------------------------------------------------ bootstrap (from the preview by Codex)
def bootstrap():
    settings = load_json(PATHS_FILE, {}) or {}
    if settings.get("app_dir"):
        os.environ.setdefault("CSV_APP_DIR", settings["app_dir"])
    claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    vault = Path(os.environ.get("CSV_VAULT") or claude_home / "session-vault")
    os.environ.setdefault("CSV_VAULT", str(vault))
    os.environ.setdefault("CSV_TOOL_CONFIG", str(vault / "config.json"))
    os.environ.setdefault("CSV_LANG", "zh" if is_zh() else "en")

    if getattr(sys, "frozen", False):
        core_exe = Path(sys.executable).with_name("SessionKeeperCore.exe")
        os.environ.setdefault("CSV_CORE_EXE", str(core_exe))
        gui_command = [sys.executable]
    else:
        core_exe = ROOT_DIR / "claude_sessions.py"
        gui_command = [sys.executable, str(Path(__file__).resolve())]

    vault.mkdir(parents=True, exist_ok=True)
    config_path = vault / "config.json"
    if not config_path.exists():
        bundled = Path(getattr(sys, "_MEIPASS", ROOT_DIR)) / "config.default.json"
        if bundled.exists():
            config_path.write_bytes(bundled.read_bytes())

    if os.name == "nt":
        SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
        INSTALL_FILE.write_text(json.dumps({
            "gui_command": gui_command,
            "gui_executable": gui_command[0],
            "core_executable": str(core_exe),
        }, ensure_ascii=False, indent=2), encoding="utf-8")
    return vault, core_exe


VAULT_DIR = None
CORE_EXE = None


def command_for_core(args):
    if getattr(sys, "frozen", False):
        return [str(CORE_EXE)] + list(args)
    return [sys.executable, str(CORE_EXE)] + list(args)


def run_core(args, timeout=180):
    """Run the core and return (returncode, output)."""
    env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
    try:
        r = subprocess.run(command_for_core(args), capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=timeout, env=env,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except (OSError, subprocess.SubprocessError) as exc:
        return -1, str(exc)
    out = (r.stdout or "").strip()
    if (r.stderr or "").strip():
        out = (out + "\n" + r.stderr.strip()).strip()
    return r.returncode, out


def core_json(args):
    code, out = run_core(args, timeout=60)
    if code != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


# ------------------------------------------------------------------ small widgets
def card(parent, **kw):
    f = tk.Frame(parent, bg=CARD, highlightbackground=BORDER, highlightthickness=1, **kw)
    return f


def label(parent, text, size=10, weight="normal", color=TEXT, bg=CARD, **kw):
    return tk.Label(parent, text=text, font=font(size, weight), fg=color, bg=bg, anchor="w", justify="left", **kw)


def avatar(parent, text, size=32, bg=CARD):
    c = tk.Canvas(parent, width=size, height=size, bg=bg, highlightthickness=0)
    letter = "?" if not text else text[:1].upper()
    color = AVATAR_COLORS[sum(ord(ch) for ch in (text or "?")) % len(AVATAR_COLORS)] if text != "?" else "#9E73CC"
    c.create_oval(1, 1, size - 1, size - 1, fill=color, outline=color)
    c.create_text(size / 2, size / 2, text=letter, fill="white", font=font(int(size * 0.36), "bold"))
    return c


def ring(parent, value, size=56, width=6, estimated=False, bg=CARD):
    c = tk.Canvas(parent, width=size, height=size, bg=bg, highlightthickness=0)
    pad = width / 2 + 1
    c.create_oval(pad, pad, size - pad, size - pad, outline=TRACK, width=width)
    v = max(0, min(100, value or 0))
    if value is not None and v > 0:
        c.create_arc(pad, pad, size - pad, size - pad, start=90, extent=-3.6 * v if v < 100 else -359.9,
                     style="arc", outline=usage_color(v), width=width)
    c.create_text(size / 2, size / 2, text="—" if value is None else f"{value}%",
                  fill=MUTED if estimated else TEXT, font=font(int(size * 0.2), "bold"))
    return c


def bar(parent, value, width=90, estimated=False, bg=CARD):
    h = 6
    c = tk.Canvas(parent, width=width, height=h, bg=bg, highlightthickness=0)

    def pill(x1, color):
        c.create_rectangle(h / 2, 0, max(h / 2, x1 - h / 2), h, fill=color, outline=color)
        c.create_oval(0, 0, h, h, fill=color, outline=color)
        c.create_oval(x1 - h, 0, x1, h, fill=color, outline=color)

    pill(width, TRACK)
    if value is not None:
        v = max(0, min(100, value))
        color = usage_color(v) if not estimated else "#C9C2BB"
        pill(max(h, width * v / 100), color)
    return c


def button(parent, text, command, primary=False, bg=CARD, state="normal"):
    b = tk.Button(parent, text=text, command=command, font=font(10, "bold" if primary else "normal"),
                  fg="white" if primary else TEXT, bg=BRAND if primary else "#F1EDE9",
                  activebackground="#D4653B" if primary else "#E6E0DA",
                  activeforeground="white" if primary else TEXT,
                  relief="flat", bd=0, padx=14, pady=6, cursor="hand2", state=state,
                  disabledforeground=FAINT, highlightthickness=0)
    return b


def tag(parent, text, bg=CARD):
    return tk.Label(parent, text=text, font=font(8, "bold"), fg=BRAND, bg=BRAND_SOFT, padx=6, pady=1)


class Scrollable(tk.Frame):
    """A vertically scrolling page."""

    def __init__(self, parent):
        super().__init__(parent, bg=BG)
        self.canvas = tk.Canvas(self, bg=BG, highlightthickness=0)
        self.sb = tk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.inner = tk.Frame(self.canvas, bg=BG)
        self.win = self.canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self.canvas.configure(yscrollcommand=self.sb.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        self.sb.pack(side="right", fill="y")
        self.inner.bind("<Configure>", lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas.bind("<Configure>", self._center)
        self.canvas.bind_all("<MouseWheel>", lambda e: self.canvas.yview_scroll(int(-e.delta / 120), "units"))

    def _center(self, e):
        w = min(e.width, 880)
        self.canvas.itemconfigure(self.win, width=w)
        self.canvas.coords(self.win, max(0, (e.width - w) // 2), 0)


# ------------------------------------------------------------------ main window
PAGES = [("overview", "概览", "Overview", "▦"), ("usage", "额度", "Usage", "◔"),
         ("chats", "对话", "Chats", "☰"), ("guide", "使用指南", "Guide", "?"), ("settings", "设置", "Settings", "⚙")]


class App:
    def __init__(self, root):
        self.root = root
        self.status, self.usage, self.rules = {}, {}, {}
        self.page = os.environ.get("CSV_PAGE") or "overview"
        self.busy = False
        self.refreshed_at = None
        self.ticks = 0
        self.log_lines = []
        self.inbox = queue.Queue()          # results from worker threads, applied on the Tk thread
        root.title(tr("Claude 换号助手", "Session Keeper for Claude"))
        root.geometry("1000x700")
        root.minsize(900, 600)
        root.configure(bg=BG)
        icon = Path(getattr(sys, "_MEIPASS", ROOT_DIR / "app")) / "icon.png"
        if not icon.exists():
            icon = ROOT_DIR / "docs" / "icon.png"
        self.icon_img = None
        if icon.exists():
            try:
                self.icon_img = tk.PhotoImage(file=str(icon)).subsample(8, 8)
                root.iconphoto(True, tk.PhotoImage(file=str(icon)))
            except tk.TclError:
                self.icon_img = None

        self.sidebar = tk.Frame(root, bg=SIDEBAR, width=230)
        self.sidebar.pack(side="left", fill="y")
        self.sidebar.pack_propagate(False)
        self.content = tk.Frame(root, bg=BG)
        self.content.pack(side="left", fill="both", expand=True)
        self.build_sidebar()
        self.root.after(50, self.pump)
        self.refresh()
        self.root.after(4000, self.poll)

    def pump(self):
        """Run callbacks queued by worker threads (Tk may only be touched from its own thread)."""
        try:
            while True:
                self.inbox.get_nowait()()
        except queue.Empty:
            pass
        self.root.after(50, self.pump)

    def later(self, fn):
        self.inbox.put(fn)

    # ---------------------------------------------------------------- data
    def refresh(self, rerender=True):
        def work():
            st = core_json(["status", "--json"]) or {}
            us = core_json(["usage", "--json"]) or {}
            vault = Path(os.environ.get("CSV_VAULT", ""))
            cfg = load_json(vault / "config.json", {}) or {}
            self.later(lambda: self._apply(st, us, cfg.get("keep_rules") or {}, rerender))
        threading.Thread(target=work, daemon=True).start()

    def _apply(self, st, us, rules, rerender):
        self.status, self.usage, self.rules = st, us, rules
        self.refreshed_at = time.strftime("%H:%M:%S")
        self.build_sidebar()
        if rerender:
            self.render()
        self.check_pending_switch()

    def poll(self):
        self.check_pending_switch()
        self.ticks += 1
        if self.ticks % 8 == 0 and not self.busy:      # every ~30 s
            self.refresh()
        self.root.after(4000, self.poll)

    def run_action(self, args, after=None):
        if self.busy:
            return
        self.busy = True
        self.build_sidebar()

        def work():
            code, out = run_core(args)
            def done():
                self.busy = False
                if out:
                    self.log_lines.append(out)
                if code != 0:
                    messagebox.showerror(tr("操作没有完成", "Didn't finish"), out or str(code))
                if after:
                    after()
                self.refresh()
            self.later(done)
        threading.Thread(target=work, daemon=True).start()

    # ---------------------------------------------------------------- sidebar
    def build_sidebar(self):
        for w in self.sidebar.winfo_children():
            w.destroy()
        head = tk.Frame(self.sidebar, bg=SIDEBAR)
        head.pack(fill="x", padx=14, pady=(18, 14))
        if self.icon_img:
            tk.Label(head, image=self.icon_img, bg=SIDEBAR).pack(side="left", padx=(0, 10))
        t = tk.Frame(head, bg=SIDEBAR)
        t.pack(side="left")
        label(t, tr("Claude 换号助手", "Session Keeper"), 10, "bold", bg=SIDEBAR).pack(anchor="w")
        label(t, tr("对话不丢 · 额度清楚", "for Claude"), 8, color=MUTED, bg=SIDEBAR).pack(anchor="w")

        for key, zh, en, glyph in PAGES:
            sel = key == self.page
            row = tk.Frame(self.sidebar, bg=BRAND_SOFT if sel else SIDEBAR, cursor="hand2")
            row.pack(fill="x", padx=10, pady=1)
            for w in (tk.Label(row, text=glyph, font=font(11), fg=BRAND if sel else MUTED,
                               bg=row["bg"], width=2),
                      tk.Label(row, text=tr(zh, en), font=font(10, "bold" if sel else "normal"),
                               fg=BRAND if sel else TEXT, bg=row["bg"], anchor="w")):
                w.pack(side="left", padx=(8, 4), pady=7)
                w.bind("<Button-1>", lambda e, k=key: self.go(k))
            row.bind("<Button-1>", lambda e, k=key: self.go(k))

        foot = tk.Frame(self.sidebar, bg="#E7E1DB")
        foot.pack(side="bottom", fill="x", padx=12, pady=12)
        on = bool(self.status.get("autoBackup"))
        dot = tk.Canvas(foot, width=8, height=8, bg=foot["bg"], highlightthickness=0)
        dot.create_oval(0, 0, 8, 8, fill="#4CB561" if on else FAINT, outline="")
        dot.pack(side="left", padx=(10, 6), pady=10)
        txt = tr("自动备份已开启", "Auto backup on") if on else tr("自动备份已关闭", "Auto backup off")
        if self.busy:
            txt = tr("处理中…", "Working…")
        label(foot, txt, 9, bg=foot["bg"]).pack(side="left", pady=10)

    def go(self, key):
        self.page = key
        self.build_sidebar()
        self.render()

    # ---------------------------------------------------------------- pages
    def render(self):
        for w in self.content.winfo_children():
            w.destroy()
        page = Scrollable(self.content)
        page.pack(fill="both", expand=True)
        body = tk.Frame(page.inner, bg=BG)
        body.pack(fill="both", expand=True, padx=26, pady=22)
        if not self.status.get("dataPathReady", True):
            self.data_missing_banner(body)
        getattr(self, "page_" + self.page)(body)

    def header(self, parent, title, subtitle, action=None):
        h = tk.Frame(parent, bg=BG)
        h.pack(fill="x", pady=(0, 16))
        t = tk.Frame(h, bg=BG)
        t.pack(side="left")
        label(t, title, 18, "bold", bg=BG).pack(anchor="w")
        label(t, subtitle, 10, color=MUTED, bg=BG).pack(anchor="w")
        if action:
            button(h, action[0], action[1], bg=BG).pack(side="right")
            if self.refreshed_at:
                label(h, tr("已刷新 ", "Refreshed ") + self.refreshed_at, 9, color=MUTED, bg=BG).pack(side="right", padx=10)

    def data_missing_banner(self, parent):
        b = tk.Frame(parent, bg="#FDF0E1")
        b.pack(fill="x", pady=(0, 14))
        label(b, tr("没找到 Claude 的数据文件夹。请在「设置」里选择包含 claude-code-sessions 和 config.json 的文件夹。",
                    "Claude's data folder wasn't found. Choose the folder containing claude-code-sessions and config.json in Settings."),
              10, bg="#FDF0E1", wraplength=620).pack(side="left", padx=12, pady=10)
        button(b, tr("去选择", "Choose"), lambda: self.go("settings"), bg="#FDF0E1").pack(side="right", padx=10)

    def accounts(self):
        return self.usage.get("accounts") or []

    @staticmethod
    def title_of(a):
        return a.get("name") if a.get("named") else (a.get("email") or a.get("name") or "?")

    @staticmethod
    def sub_of(a):
        if a.get("named"):
            return a.get("email") or tr("邮箱待识别，登录一次即可", "Email unknown — sign in once")
        return tr("点名字可以起个名字", "Click the name to rename") if a.get("email") else \
            tr("邮箱待识别，登录一次即可", "Email unknown — sign in once")

    def page_overview(self, p):
        self.header(p, tr("概览", "Overview"),
                    tr("换号不丢对话，每个号的额度一眼看清", "Switch accounts without losing chats — see every account's usage"),
                    (tr("⟳ 刷新", "⟳ Refresh"), self.refresh))
        cur = next((a for a in self.accounts() if a.get("current")), None)
        c = card(p)
        c.pack(fill="x")
        top = tk.Frame(c, bg=CARD)
        top.pack(fill="x", padx=18, pady=(16, 12))
        avatar(top, "?" if not cur or (not cur.get("email") and not cur.get("named")) else self.title_of(cur), 48).pack(side="left")
        info = tk.Frame(top, bg=CARD)
        info.pack(side="left", padx=12)
        row = tk.Frame(info, bg=CARD)
        row.pack(anchor="w")
        label(row, self.title_of(cur) if cur else (str(self.status.get("currentAccount") or "—")[:8]), 14, "bold").pack(side="left")
        tag(row, tr("当前登录", "Signed in")).pack(side="left", padx=8)
        label(info, (cur.get("email") if cur and cur.get("named") else (self.sub_of(cur) if cur else
              tr("登录后会自动记录邮箱", "Email is recorded after you sign in"))), 10, color=MUTED).pack(anchor="w")
        if cur:
            for lab, v, est in ((tr("每周", "Weekly"), cur.get("weekly"), cur.get("weeklyEstimated")),
                                (tr("5 小时", "5-hour"), cur.get("fiveHour"), cur.get("fiveHourEstimated"))):
                g = tk.Frame(top, bg=CARD)
                g.pack(side="right", padx=6)
                ring(g, v, 56, 6, est).pack()
                label(g, lab, 8, color=MUTED).pack()
        tk.Frame(c, bg=BORDER, height=1).pack(fill="x", padx=18)
        bot = tk.Frame(c, bg=CARD)
        bot.pack(fill="x", padx=18, pady=12)
        n = next((x.get("sessions", 0) for x in self.status.get("accounts", []) if x.get("current")), 0)
        label(bot, tr(f"侧边栏里有 {n} 个对话", f"{n} chats in the sidebar"), 10, color=MUTED).pack(side="left")
        button(bot, tr("恢复所有对话", "Restore all chats"), self.restore, primary=True).pack(side="right")

        h = tk.Frame(p, bg=BG)
        h.pack(fill="x", pady=(20, 8))
        label(h, tr("账号一览", "All accounts"), 12, "bold", bg=BG).pack(side="left")
        lk = label(h, tr("查看额度详情 ›", "Usage details ›"), 10, color=BRAND, bg=BG, cursor="hand2")
        lk.pack(side="right")
        lk.bind("<Button-1>", lambda e: self.go("usage"))
        lst = card(p)
        lst.pack(fill="x")
        if not self.accounts():
            label(lst, tr("还没有额度记录。在 Claude 里打开一次 Code 标签页后再看。", "No usage yet. Open the Code tab in Claude once."),
                  10, color=MUTED).pack(anchor="w", padx=16, pady=14)
        for i, a in enumerate(self.accounts()):
            if i:
                tk.Frame(lst, bg=BORDER, height=1).pack(fill="x", padx=(58, 0))
            r = tk.Frame(lst, bg=CARD)
            r.pack(fill="x", padx=14, pady=9)
            avatar(r, "?" if not a.get("email") and not a.get("named") else self.title_of(a), 30).pack(side="left")
            t = tk.Frame(r, bg=CARD)
            t.pack(side="left", padx=10)
            tr_ = tk.Frame(t, bg=CARD)
            tr_.pack(anchor="w")
            label(tr_, self.title_of(a), 10, "bold").pack(side="left")
            if a.get("current"):
                tag(tr_, tr("当前", "Current")).pack(side="left", padx=6)
            label(t, a.get("email") if a.get("named") and a.get("email") else self.sub_of(a), 9, color=MUTED).pack(anchor="w")
            sw = tk.Frame(r, bg=CARD, width=64, height=34)
            sw.pack(side="right", padx=(12, 0))
            sw.pack_propagate(False)            # same width with or without the button, so bars line up
            if not a.get("current"):
                button(sw, tr("切换", "Switch"), lambda acc=a: self.switch_to(acc)).pack()
            for lab, v, est in ((tr("周", "Wk"), a.get("weekly"), a.get("weeklyEstimated")),
                                ("5h", a.get("fiveHour"), a.get("fiveHourEstimated"))):
                f = tk.Frame(r, bg=CARD)
                f.pack(side="right", padx=(14, 0))
                label(f, lab, 8, color=MUTED).pack(side="left", padx=(0, 6))
                bar(f, v, 70, est).pack(side="left")
                label(f, "—" if v is None else f"{v}%", 9, width=5).pack(side="left", padx=(6, 0))

        stats = tk.Frame(p, bg=BG)
        stats.pack(fill="x", pady=(16, 0))
        size = self.status.get("vaultBytes", 0)
        human = f"{size / 1e6:.1f} MB" if size >= 1e6 else f"{size / 1e3:.0f} KB"
        for i, (val, lab) in enumerate(((self.status.get("vaultSessions", 0), tr("已备份对话", "Chats in vault")),
                                        (len(self.accounts()) or self.status.get("orgCount", 0), tr("账号", "Accounts")),
                                        (human, tr("备份占用", "Vault size")))):
            s = card(stats)
            s.pack(side="left", fill="x", expand=True, padx=(0 if i == 0 else 10, 0))
            label(s, str(val), 15, "bold").pack(anchor="w", padx=14, pady=(10, 0))
            label(s, lab, 9, color=MUTED).pack(anchor="w", padx=14, pady=(0, 10))

        self.ad_card(p)
        if self.log_lines:
            lg = card(p)
            lg.pack(fill="x", pady=(16, 0))
            label(lg, tr("活动记录", "Activity"), 11, "bold").pack(anchor="w", padx=16, pady=(12, 4))
            label(lg, "\n".join(self.log_lines[-8:]), 9, color=MUTED, wraplength=640).pack(anchor="w", padx=16, pady=(0, 12))

    def page_usage(self, p):
        self.header(p, tr("额度", "Usage"),
                    tr("每个账号的 5 小时额度和每周额度，以及下一次重置时间", "5-hour and weekly limits, and when each resets"),
                    (tr("⟳ 刷新", "⟳ Refresh"), self.refresh))
        if not self.accounts():
            c = card(p)
            c.pack(fill="x")
            label(c, tr("还没有额度记录。在 Claude 里打开一次 Code 标签页后点刷新。",
                        "No usage recorded yet. Open the Code tab in Claude once, then Refresh."),
                  10, color=MUTED).pack(anchor="w", padx=16, pady=14)
        for a in self.accounts():
            cur = a.get("current")
            c = tk.Frame(p, bg=CARD, highlightbackground=BRAND if cur else BORDER,
                         highlightthickness=2 if cur else 1)
            c.pack(fill="x", pady=(0, 12))
            top = tk.Frame(c, bg=CARD)
            top.pack(fill="x", padx=16, pady=(14, 10))
            avatar(top, "?" if not a.get("email") and not a.get("named") else self.title_of(a), 36).pack(side="left")
            t = tk.Frame(top, bg=CARD)
            t.pack(side="left", padx=10)
            row = tk.Frame(t, bg=CARD)
            row.pack(anchor="w")
            nm = label(row, self.title_of(a) + "  ✎", 11, "bold", cursor="hand2")
            nm.pack(side="left")
            nm.bind("<Button-1>", lambda e, acc=a: self.rename(acc))
            if cur:
                tag(row, tr("当前登录", "Signed in")).pack(side="left", padx=8)
            label(t, self.sub_of(a), 9, color=MUTED if a.get("named") else FAINT).pack(anchor="w")
            side = tk.Frame(top, bg=CARD)
            side.pack(side="right", anchor="n")
            if not cur:
                button(side, tr("⇄ 切换到这个号", "⇄ Switch to this"), lambda acc=a: self.switch_to(acc)).pack(anchor="e")
            label(side, (tr("Claude 记录于 ", "recorded ") + short_time(a.get("updatedAt"))) if a.get("updatedAt")
                  else tr("暂无用量记录", "no usage yet"), 8, color=FAINT).pack(anchor="e", pady=(4, 0))

            blocks = tk.Frame(c, bg=CARD)
            blocks.pack(fill="x", padx=16, pady=(0, 14))
            blocks.columnconfigure(0, weight=1, uniform="b")
            blocks.columnconfigure(1, weight=1, uniform="b")
            specs = [
                (tr("5 小时额度", "5-hour limit"), a.get("fiveHour"), a.get("fiveHourEstimated"), a.get("fiveHourReset"),
                 tr("下次恢复", "Resets"),
                 tr("现在可用 · 开始使用后 5 小时内恢复", "Available · resets 5 h after you start")
                 if a.get("fiveHour") is not None else tr("暂无数据", "no data")),
                (tr("每周额度", "Weekly limit"), a.get("weekly"), a.get("weeklyEstimated"), a.get("weeklyReset"),
                 tr("下次重置", "Resets"),
                 tr("重置时间未知 · 碰到一次每周限额后就能算准", "Unknown until the weekly limit is hit once")
                 if a.get("weekly") is not None else tr("暂无数据", "no data")),
            ]
            for col, (title, v, est, r, word, idle) in enumerate(specs):
                b = tk.Frame(blocks, bg="#F8F6F4")
                b.grid(row=0, column=col, sticky="nsew", padx=(0, 10) if col == 0 else (10, 0))
                head = tk.Frame(b, bg="#F8F6F4")
                head.pack(fill="x", padx=12, pady=(10, 4))
                label(head, title, 10, "bold", bg="#F8F6F4").pack(side="left")
                label(head, "—" if v is None else f"{v}%", 15, "bold", bg="#F8F6F4",
                      color=MUTED if (v is None or est) else usage_color(v)).pack(side="right")
                bar(b, v, 300, est, bg="#F8F6F4").pack(anchor="w", padx=12)
                if r:
                    line = tk.Frame(b, bg="#F8F6F4")
                    line.pack(anchor="w", padx=12, pady=(6, 0))
                    label(line, f"{word} {r['when']}", 9, "bold", bg="#F8F6F4").pack(side="left")
                    ok = r.get("exact")
                    tk.Label(line, text=tr("精确", "exact") if ok else tr("估计", "est."), font=font(7, "bold"),
                             fg="#3E9B52" if ok else MUTED, bg="#E3F3E6" if ok else "#ECE8E4", padx=4).pack(side="left", padx=6)
                    label(b, f"{r['week']} · {r['in']}", 9, color=MUTED, bg="#F8F6F4").pack(anchor="w", padx=12, pady=(2, 10))
                else:
                    label(b, idle, 9, color=MUTED, bg="#F8F6F4", wraplength=300).pack(anchor="w", padx=12, pady=(6, 10))
        label(p, "ⓘ " + tr("数据来自 Claude 在本机的记录，不联网、不读取 token：用量来自 Claude App，邮箱和精确的重置时间来自 Claude Code 的对话记录。标「精确」的是 Claude 自己给出的时间，标「估计」的是推算的。",
                          "Everything comes from Claude's own records on this computer — no network, no tokens. \"Exact\" times were reported by Claude; \"est.\" ones are inferred."),
              9, color=MUTED, bg=BG, wraplength=640).pack(anchor="w", pady=(4, 0))

    def page_chats(self, p):
        self.header(p, tr("对话", "Chats"), tr("备份、恢复和整理 Claude Code 的对话列表", "Back up, restore and tidy your Claude Code chats"))
        lst = card(p)
        lst.pack(fill="x")
        rules_on = bool(self.rules.get("enabled"))
        rows = [
            ("⬇", tr("恢复到当前账号", "Restore to this account"), tr("把所有账号的对话加进当前账号的侧边栏。", "Add chats from every account to this account's sidebar."),
             tr("恢复", "Restore"), self.restore, True, True),
            ("⛁", tr("立即备份", "Back up now"), tr("后台每分钟会自动备份，这里可以手动再来一次。", "Runs every minute in the background; run it now by hand."),
             tr("备份", "Back up"), lambda: self.run_action(["backup"]), False, True),
            ("✦", tr("清理旧对话", "Clean up old chats"),
             tr("按下面的保留规则，从所有账号里移除旧对话。", "Remove old chats from every account using the rule below.") if rules_on
             else tr("先打开下面的保留规则。", "Turn on the keep rule below first."),
             tr("清理…", "Clean up…"), self.prune, False, rules_on),
            ("↶", tr("撤销上次操作", "Undo last action"), tr("撤销上一次「恢复」或「清理」。", "Undo the last restore or cleanup."),
             tr("撤销", "Undo"), self.undo, False, bool(self.status.get("canUndo"))),
        ]
        for i, (glyph, title, detail, btn, cmd, primary, enabled) in enumerate(rows):
            if i:
                tk.Frame(lst, bg=BORDER, height=1).pack(fill="x", padx=(56, 0))
            r = tk.Frame(lst, bg=CARD)
            r.pack(fill="x", padx=14, pady=11)
            tk.Label(r, text=glyph, font=font(12), fg=BRAND, bg=BRAND_SOFT, width=3, height=1).pack(side="left")
            t = tk.Frame(r, bg=CARD)
            t.pack(side="left", padx=12)
            label(t, title, 10, "bold").pack(anchor="w")
            label(t, detail, 9, color=MUTED).pack(anchor="w")
            button(r, btn, cmd, primary=primary, state="normal" if enabled and not self.busy else "disabled").pack(side="right")

        label(p, tr("保留规则", "Keep rule"), 12, "bold", bg=BG).pack(anchor="w", pady=(20, 8))
        k = card(p)
        k.pack(fill="x")
        self.keep_on = tk.BooleanVar(value=rules_on)
        self.keep_days = tk.IntVar(value=int(self.rules.get("max_age_days") or 3))
        self.keep_per = tk.IntVar(value=int(self.rules.get("max_per_project") or 2))
        top = tk.Frame(k, bg=CARD)
        top.pack(fill="x", padx=16, pady=12)
        t = tk.Frame(top, bg=CARD)
        t.pack(side="left")
        label(t, tr("只保留最近的对话", "Keep only recent chats"), 10, "bold").pack(anchor="w")
        label(t, tr("恢复时只带这些对话过去，「清理旧对话」也按这个规则。", "Restore brings only these; Clean up uses the same rule."),
              9, color=MUTED).pack(anchor="w")
        tk.Checkbutton(top, variable=self.keep_on, command=self.save_rules, bg=CARD, activebackground=CARD,
                       text=tr("开启", "On"), font=font(10)).pack(side="right")
        if rules_on:
            tk.Frame(k, bg=BORDER, height=1).pack(fill="x", padx=16)
            sp = tk.Frame(k, bg=CARD)
            sp.pack(fill="x", padx=16, pady=12)
            label(sp, tr("最近", "Last"), 10).pack(side="left")
            tk.Spinbox(sp, from_=1, to=90, width=4, textvariable=self.keep_days, command=self.save_rules,
                       font=font(10)).pack(side="left", padx=6)
            label(sp, tr("天，每个项目最多", "days, up to"), 10).pack(side="left")
            tk.Spinbox(sp, from_=1, to=20, width=4, textvariable=self.keep_per, command=self.save_rules,
                       font=font(10)).pack(side="left", padx=6)
            label(sp, tr("个对话", "chats per project"), 10).pack(side="left")

    def page_guide(self, p):
        self.header(p, tr("使用指南", "Guide"), tr("三分钟看懂怎么用", "Everything in three minutes"))
        sections = [
            (tr("平时：什么都不用做", "Day to day: nothing to do"), [
                tr("后台每分钟自动备份一次对话列表和额度记录，只在有变化时才写入。", "A background job backs up chat lists and usage every minute."),
                tr("页面每 30 秒自动刷新；想马上看最新的，点右上角「刷新」。", "Pages refresh every 30 s; press Refresh for the latest.")]),
            (tr("换号：三步", "Switching accounts: three steps"), [
                tr("在「额度」或「概览」里，对要换的号点「切换」，邮箱会自动复制。", "Click Switch on the account you want — its email is copied."),
                tr("在 Claude 左下角点头像 → 退出登录，再用这个邮箱登录，打开一次 Code 标签页。", "In Claude: avatar → Log out, sign in with that email, open the Code tab once."),
                tr("一分钟内会自动倒数 10 秒，把之前的对话恢复到这个号（可以取消）。", "Within a minute your chats are restored automatically after a 10-second countdown (cancelable).")]),
            (tr("额度怎么看", "Reading the usage"), [
                tr("百分比来自 Claude 自己的记录，「Claude 记录于」就是数据的时间；没登录的号显示上次登录时的情况。",
                   "Percentages come from Claude's own record — \"recorded\" shows how fresh it is."),
                tr("「精确」的重置时间是 Claude 自己报出来的；每周额度每周固定时间重置。「估计」的是推算的。",
                   "\"Exact\" reset times were reported by Claude; weekly resets repeat every week. \"Est.\" ones are inferred.")]),
            (tr("规则和安全", "Rules and safety"), [
                tr("只读写本机文件，不联网，不读取、不保存、不调换任何登录凭证或 token。换号由你自己在 Claude 里登录完成。",
                   "Local files only: never reads, stores or swaps credentials or tokens. You always sign in yourself."),
                tr("不提供「快到限额就自动换号」：用多个账号绕开单个账号的用量限制，可能违反 Anthropic 的使用条款。",
                   "No auto-switch before the limit: using several accounts to get around usage limits may break Anthropic's terms."),
                tr("每次恢复和清理之前都会拍快照，可以一键撤销。", "Every restore and cleanup takes a snapshot first; Undo puts things back.")]),
        ]
        for i, (title, items) in enumerate(sections, 1):
            c = card(p)
            c.pack(fill="x", pady=(0, 12))
            r = tk.Frame(c, bg=CARD)
            r.pack(fill="x", padx=16, pady=14)
            tk.Label(r, text=str(i), font=font(11, "bold"), fg="white", bg=BRAND, width=2).pack(side="left", anchor="n")
            t = tk.Frame(r, bg=CARD)
            t.pack(side="left", padx=12, fill="x", expand=True)
            label(t, title, 11, "bold").pack(anchor="w", pady=(0, 6))
            for it in items:
                label(t, "• " + it, 10, color=MUTED, wraplength=560).pack(anchor="w", pady=1)

    def switch_to(self, a):
        email = a.get("email") or ""
        if email:
            self.root.clipboard_clear()
            self.root.clipboard_append(email)
        messagebox.showinfo(tr("切换到 ", "Switch to ") + (email or self.title_of(a)),
                            tr("邮箱已复制到剪贴板。\n\n1. 在 Claude 左下角点头像 → 退出登录\n2. 用这个邮箱登录（粘贴即可）\n3. 打开一次 Code 标签页\n\n本工具会在一分钟内提醒你把对话恢复到这个号。\n\n为了你的账号安全，本工具不保存、不调换任何登录凭证。",
                               "The email is on your clipboard.\n\n1. In Claude: avatar (bottom left) → Log out\n2. Sign in with this email (paste it)\n3. Open the Code tab once\n\nWithin a minute this app will offer to restore your chats.\n\nThis app never stores or swaps sign-in credentials."))

    def page_settings(self, p):
        self.header(p, tr("设置", "Settings"), tr("后台任务、数据位置和关于", "Background job, data folders and about"))
        a = card(p)
        a.pack(fill="x")
        r = tk.Frame(a, bg=CARD)
        r.pack(fill="x", padx=16, pady=12)
        t = tk.Frame(r, bg=CARD)
        t.pack(side="left")
        label(t, tr("自动备份 + 换号提醒", "Auto backup + switch alert"), 10, "bold").pack(anchor="w")
        label(t, tr("每分钟备份一次对话列表和额度记录；发现换号会提醒你恢复。",
                    "Backs up chat lists and usage every minute; prompts you after an account switch."), 9, color=MUTED).pack(anchor="w")
        on = bool(self.status.get("autoBackup"))
        button(r, tr("关闭", "Turn off") if on else tr("开启", "Turn on"),
               lambda: self.run_action(["uninstall-agent" if on else "install-agent"]), primary=not on).pack(side="right")

        cfg_path = Path(os.environ.get("CSV_VAULT", "")) / "config.json"
        cfg = load_json(cfg_path, {}) or {}
        ar = cfg.get("auto_restore", True)
        tk.Frame(a, bg=BORDER, height=1).pack(fill="x", padx=16)
        r2 = tk.Frame(a, bg=CARD)
        r2.pack(fill="x", padx=16, pady=12)
        t2 = tk.Frame(r2, bg=CARD)
        t2.pack(side="left")
        label(t2, tr("换号后自动恢复对话", "Restore chats automatically after a switch"), 10, "bold").pack(anchor="w")
        label(t2, tr("检测到换号后倒数 10 秒自动恢复，期间可以取消。关掉后改为弹窗询问。",
                     "After a switch, restores after a 10-second countdown (cancelable). Off: ask first."), 9, color=MUTED).pack(anchor="w")

        def toggle_ar():
            c = load_json(cfg_path, {}) or {}
            c["auto_restore"] = not c.get("auto_restore", True)
            cfg_path.write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding="utf-8")
            self.render()
        button(r2, tr("关闭", "Turn off") if ar else tr("开启", "Turn on"), toggle_ar, primary=not ar).pack(side="right")

        d = card(p)
        d.pack(fill="x", pady=(12, 0))
        for title, path, btn, cmd in (
                (tr("Claude 数据文件夹", "Claude data folder"), self.status.get("dataRoot") or tr("未找到", "not found"),
                 tr("选择…", "Choose…"), self.choose_data_folder),
                (tr("保险库（备份）", "Vault (backups)"), str(VAULT_DIR or ""), tr("打开", "Open"), self.open_vault)):
            r = tk.Frame(d, bg=CARD)
            r.pack(fill="x", padx=16, pady=10)
            t = tk.Frame(r, bg=CARD)
            t.pack(side="left")
            label(t, title, 10, "bold").pack(anchor="w")
            label(t, path, 9, color=MUTED).pack(anchor="w")
            button(r, btn, cmd).pack(side="right")

        ab = card(p)
        ab.pack(fill="x", pady=(12, 0))
        r = tk.Frame(ab, bg=CARD)
        r.pack(fill="x", padx=16, pady=12)
        if self.icon_img:
            tk.Label(r, image=self.icon_img, bg=CARD).pack(side="left", padx=(0, 10))
        t = tk.Frame(r, bg=CARD)
        t.pack(side="left")
        label(t, tr("Claude 换号助手", "Session Keeper for Claude"), 11, "bold").pack(anchor="w")
        label(t, tr("版本 ", "Version ") + VERSION, 9, color=MUTED).pack(anchor="w")
        gh = label(r, "GitHub ›", 10, color=BRAND, cursor="hand2")
        gh.pack(side="right")
        gh.bind("<Button-1>", lambda e: webbrowser.open(GITHUB_URL))
        label(ab, tr("只读写本机文件，不碰登录信息、token 和账号设置；除了你主动打开的广告，本工具不联网。恢复和清理前都会自动拍快照，可以一键撤销。\n与 Anthropic 无关。Claude 是 Anthropic, PBC 的商标。",
                     "Local files only: no network, never touches sign-in, tokens or account settings. Every restore and cleanup takes a snapshot first.\nNot affiliated with Anthropic. Claude is a trademark of Anthropic, PBC."),
              9, color=MUTED, wraplength=600).pack(anchor="w", padx=16, pady=(0, 12))
        self.ad_card(p)

    def ad_card(self, p):
        """Sponsor banner, clearly labelled. Nothing is loaded until you open it."""
        bg = "#FFF3EC"
        ad = tk.Frame(p, bg=bg, highlightbackground="#F4CDB8", highlightthickness=1)
        ad.pack(fill="x", pady=(16, 0))
        r = tk.Frame(ad, bg=bg)
        r.pack(fill="x", padx=18, pady=16)
        logo = tk.Canvas(r, width=60, height=60, bg=bg, highlightthickness=0)
        logo.create_oval(2, 2, 58, 58, fill=BRAND, outline=BRAND)
        logo.create_text(30, 31, text="⚡", fill="white", font=font(20, "bold"))
        logo.pack(side="left")
        t = tk.Frame(r, bg=bg)
        t.pack(side="left", padx=14)
        top = tk.Frame(t, bg=bg)
        top.pack(anchor="w")
        tk.Label(top, text=tr("广告", "Ad"), font=font(8, "bold"), fg="white", bg=BRAND, padx=6).pack(side="left")
        label(top, "  tutu8.shop", 13, "bold", bg=bg).pack(side="left")
        label(t, tr("AI 会员代充值 —— 作者自营的充值网站", "AI subscription top-ups — the author's own shop"), 10, color=MUTED, bg=bg).pack(anchor="w", pady=(2, 6))
        chips = tk.Frame(t, bg=bg)
        chips.pack(anchor="w")
        for c in (tr("AI 会员代充", "AI subscription top-up"), tr("作者自营", "Run by the author"), tr("非 Anthropic 官方", "Not affiliated with Anthropic")):
            tk.Label(chips, text=c, font=font(8), fg=BRAND, bg="#FBE0D2", padx=6, pady=1).pack(side="left", padx=(0, 6))
        btns = tk.Frame(r, bg=bg)
        btns.pack(side="right")
        button(btns, tr("去看看 ↗", "Visit ↗"), lambda: webbrowser.open(AD_URL), primary=True, bg=bg).pack(fill="x")
        button(btns, tr("预览", "Preview"), lambda: webbrowser.open(AD_URL), bg=bg).pack(fill="x", pady=(6, 0))

    # ---------------------------------------------------------------- actions
    def claude_running_guard(self):
        if self.status.get("claudeRunning"):
            messagebox.showinfo(tr("先退出 Claude", "Quit Claude first"),
                                tr("请先完全退出 Claude（包括右下角托盘里的图标），再点一次。完成后重新打开 Claude 即可。",
                                   "Quit Claude completely (including the tray icon), then try again. Reopen Claude afterwards."))
            return True
        return False

    def restore(self, confirm=True):
        if self.claude_running_guard():
            return
        if not confirm:
            self.run_action(["sync", "--all"])
            return
        if messagebox.askyesno(tr("恢复对话？", "Restore chats?"),
                               tr("会先备份现有列表，再把所有对话恢复到本机的 Claude 账号。完成后打开 Claude 就能看到。",
                                  "Current lists are backed up first, then every chat is restored to this computer's Claude accounts.")):
            self.run_action(["sync", "--all"])

    def undo(self):
        if self.claude_running_guard():
            return
        if messagebox.askyesno(tr("撤销上次操作？", "Undo the last action?"),
                               tr("撤销上一次「恢复」或「清理」。", "Undo the last restore or cleanup.")):
            self.run_action(["rollback"])

    def prune(self):
        data = core_json(["prune", "--json"]) or {}
        n = data.get("count", 0)
        if not n:
            messagebox.showinfo(tr("不需要清理", "Nothing to clean up"), tr("所有对话都符合保留规则。", "Every chat matches the keep rule."))
            return
        if self.claude_running_guard():
            return
        items = "\n".join(f"· {x.get('project')} | {x.get('title')}" for x in (data.get("items") or [])[:12])
        if messagebox.askyesno(tr(f"清理 {n} 个旧对话？", f"Clean up {n} old chats?"),
                               tr("将从所有账号的列表里移除：\n", "Will be removed from every account:\n") + items +
                               tr("\n\n之后可以点「撤销」找回。", "\n\nYou can Undo afterwards.")):
            self.run_action(["prune"])

    def save_rules(self):
        vault = Path(os.environ.get("CSV_VAULT", ""))
        path = vault / "config.json"
        cfg = load_json(path, {}) or {}
        kr = cfg.get("keep_rules") or {}
        try:
            kr.update({"enabled": bool(self.keep_on.get()), "max_age_days": int(self.keep_days.get()),
                       "max_per_project": int(self.keep_per.get())})
        except (tk.TclError, ValueError):
            return
        cfg["keep_rules"] = kr
        path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
        self.rules = kr
        self.render()

    def rename(self, a):
        name = simpledialog.askstring(tr("给这个账号起个名字", "Name this account"),
                                      tr("例如：工作号（只保存在本机）", "e.g. Work (stored on this computer only)"),
                                      initialvalue=a.get("name") if a.get("named") else "", parent=self.root)
        if name is not None:
            self.run_action(["usage", "--rename", a["org"], name])

    def choose_data_folder(self):
        folder = filedialog.askdirectory(title=tr("选择 Claude 数据文件夹", "Choose Claude data folder"))
        if not folder:
            return
        if os.path.basename(folder).lower() == "claude-code-sessions":
            folder = os.path.dirname(folder)
        if not os.path.isfile(os.path.join(folder, "config.json")) or \
                not os.path.isdir(os.path.join(folder, "claude-code-sessions")):
            messagebox.showwarning(tr("文件夹不对", "Wrong folder"),
                                   tr("所选文件夹需要同时包含 config.json 和 claude-code-sessions。",
                                      "The folder must contain config.json and claude-code-sessions."))
            return
        PATHS_FILE.parent.mkdir(parents=True, exist_ok=True)
        PATHS_FILE.write_text(json.dumps({"app_dir": folder}, ensure_ascii=False, indent=2), encoding="utf-8")
        os.environ["CSV_APP_DIR"] = folder
        self.log_lines.append(tr("已保存 Claude 数据文件夹。", "Claude data folder saved."))
        self.refresh()

    def open_vault(self):
        try:
            if os.name == "nt":
                os.startfile(str(VAULT_DIR))
            else:
                subprocess.run(["open", str(VAULT_DIR)])
        except OSError as exc:
            messagebox.showerror(tr("无法打开文件夹", "Couldn't open folder"), str(exc))

    def check_pending_switch(self):
        path = Path(os.environ.get("CSV_VAULT", "")) / "pending-switch.json"
        pending = load_json(path)
        if not pending or self.busy:
            return
        try:
            os.remove(path)
        except OSError:
            pass
        count = pending.get("missing", 0)
        self.root.deiconify()
        self.root.lift()
        cfg = load_json(Path(os.environ.get("CSV_VAULT", "")) / "config.json", {}) or {}
        if cfg.get("auto_restore", True):
            self.auto_restore_countdown(count)
        elif messagebox.askyesno(tr("检测到你换了账号", "You switched accounts"),
                                 tr(f"当前账号里缺少 {count} 个之前的对话。现在恢复吗？",
                                    f"This account is missing {count} of your chats. Restore now?")):
            self.restore()

    def auto_restore_countdown(self, count, seconds=10):
        """Restore by itself after a short countdown; the user can cancel or go now."""
        win = tk.Toplevel(self.root, bg=BRAND)
        win.title(tr("检测到你换了账号", "You switched accounts"))
        win.attributes("-topmost", True)
        win.resizable(False, False)
        box = tk.Frame(win, bg=BRAND)
        box.pack(padx=22, pady=18)
        label(box, tr("检测到你换了账号", "You switched accounts"), 13, "bold", color="white", bg=BRAND).pack(anchor="w")
        msg = label(box, "", 10, color="white", bg=BRAND)
        msg.pack(anchor="w", pady=(4, 12))
        row = tk.Frame(box, bg=BRAND)
        row.pack(anchor="e")
        state = {"left": seconds, "done": False}

        def finish(go):
            if state["done"]:
                return
            state["done"] = True
            win.destroy()
            if go:
                self.restore(confirm=False)
            else:
                self.log_lines.append(tr("已取消自动恢复。需要时可以在「概览」点「恢复所有对话」。",
                                         "Automatic restore canceled."))
                self.render()

        tk.Button(row, text=tr("取消", "Cancel"), command=lambda: finish(False), font=font(10), relief="flat",
                  bg="#F3A47F", fg="white", activebackground="#F0B394", bd=0, padx=14, pady=5).pack(side="left", padx=(0, 8))
        tk.Button(row, text=tr("立即恢复", "Restore now"), command=lambda: finish(True), font=font(10, "bold"), relief="flat",
                  bg="white", fg=BRAND, activebackground="#FFF1EA", bd=0, padx=14, pady=5).pack(side="left")

        def tick():
            if state["done"]:
                return
            msg.configure(text=tr(f"{state['left']} 秒后自动把 {count} 个对话恢复到这个号。\n请先完全退出 Claude（含右下角托盘图标）。",
                                  f"Restoring {count} chats to this account in {state['left']} s.\nQuit Claude completely first (including the tray icon)."))
            if state["left"] <= 0:
                finish(True)
                return
            state["left"] -= 1
            win.after(1000, tick)
        tick()


def main():
    if os.name != "nt" and not os.environ.get("CSV_ALLOW_NON_WINDOWS"):
        raise SystemExit("The Windows UI must be run on Windows.")
    global VAULT_DIR, CORE_EXE
    VAULT_DIR, CORE_EXE = bootstrap()
    importlib.import_module("claude_sessions")
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
