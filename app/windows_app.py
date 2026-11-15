#!/usr/bin/env python3
"""Small Windows front end for the shared Session Keeper Python core."""
import importlib
import json
import locale
import os
from pathlib import Path
import subprocess
import sys
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
APPDATA = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
LOCALAPPDATA = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
SETTINGS_DIR = APPDATA / "SessionKeeper"
PATHS_FILE = SETTINGS_DIR / "paths.json"
INSTALL_FILE = SETTINGS_DIR / "install.json"


def load_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def bootstrap():
    settings = load_json(PATHS_FILE, {}) or {}
    if settings.get("app_dir"):
        os.environ.setdefault("CSV_APP_DIR", settings["app_dir"])
    claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    vault = Path(os.environ.get("CSV_VAULT") or claude_home / "session-vault")
    os.environ.setdefault("CSV_VAULT", str(vault))
    os.environ.setdefault("CSV_TOOL_CONFIG", str(vault / "config.json"))
    os.environ.setdefault("CSV_LANG", locale.getlocale()[0] or "en")

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

    SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
    INSTALL_FILE.write_text(json.dumps({
        "gui_command": gui_command,
        "gui_executable": gui_command[0],
        "core_executable": str(core_exe),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    return vault, core_exe


VAULT_DIR = None
CORE_EXE = None
core = None


def command_for_core(args):
    if getattr(sys, "frozen", False):
        return [str(CORE_EXE)] + list(args)
    return [sys.executable, str(CORE_EXE)] + list(args)


def tr(zh, en):
    language = (locale.getlocale()[0] or "").lower()
    return zh if language.startswith(("zh", "chinese")) else en


class SessionKeeperWindow:
    def __init__(self, root):
        self.root = root
        self.root.title(tr("Claude 换号恢复", "Session Keeper for Claude"))
        self.root.geometry("620x520")
        self.root.minsize(560, 460)
        self.status = {}

        body = ttk.Frame(root, padding=18)
        body.pack(fill="both", expand=True)

        header = ttk.Frame(body)
        header.pack(fill="x", pady=(0, 14))
        ttk.Label(header, text=tr("Claude 换号恢复", "Session Keeper for Claude"),
                  font=("Segoe UI", 16, "bold")).pack(anchor="w")
        ttk.Label(header, text=tr("切换 Claude 账号后恢复 Code 对话",
                                  "Restore Code chats after switching Claude accounts"),
                  foreground="#555555").pack(anchor="w", pady=(3, 0))

        self.path_text = tk.StringVar()
        self.account_text = tk.StringVar()
        self.vault_text = tk.StringVar()
        info = ttk.LabelFrame(body, text=tr("状态", "Status"), padding=12)
        info.pack(fill="x", pady=(0, 12))
        ttk.Label(info, textvariable=self.path_text, wraplength=560).pack(anchor="w")
        ttk.Label(info, textvariable=self.account_text).pack(anchor="w", pady=(6, 0))
        ttk.Label(info, textvariable=self.vault_text).pack(anchor="w", pady=(3, 0))

        self.choose_button = ttk.Button(info, text=tr("选择 Claude 数据文件夹…", "Choose Claude data folder…"),
                                        command=self.choose_data_folder)
        self.choose_button.pack(anchor="w", pady=(9, 0))

        actions = ttk.Frame(body)
        actions.pack(fill="x", pady=(0, 8))
        self.restore_button = ttk.Button(actions, text=tr("恢复对话…", "Restore chats…"), command=self.restore)
        self.restore_button.pack(side="left", padx=(0, 6))
        self.backup_button = ttk.Button(actions, text=tr("立即备份", "Back up now"), command=lambda: self.run_core(["backup"]))
        self.backup_button.pack(side="left", padx=6)
        self.undo_button = ttk.Button(actions, text=tr("撤销", "Undo"), command=self.undo)
        self.undo_button.pack(side="left", padx=6)
        self.vault_button = ttk.Button(actions, text=tr("打开备份文件夹", "Open vault"), command=self.open_vault)
        self.vault_button.pack(side="right")

        self.auto_var = tk.BooleanVar(value=False)
        self.auto_toggle = ttk.Checkbutton(body, text=tr("登录期间每分钟自动备份并检测换号",
                                                       "Back up and check for account switches every minute while signed in"),
                                           variable=self.auto_var, command=self.toggle_auto)
        self.auto_toggle.pack(anchor="w", pady=(3, 10))

        ttk.Label(body, text=tr("活动记录", "Activity")).pack(anchor="w")
        self.log = tk.Text(body, height=10, wrap="word", state="disabled", font=("Consolas", 9))
        self.log.pack(fill="both", expand=True, pady=(4, 0))
        self.root.after(200, self.refresh)

    def write_log(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text.rstrip() + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def run_core(self, args):
        try:
            result = subprocess.run(command_for_core(args), capture_output=True, text=True,
                                    timeout=180, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except (OSError, subprocess.SubprocessError) as exc:
            messagebox.showerror(tr("运行失败", "Couldn't run command"), str(exc))
            return None
        output = result.stdout.strip()
        if result.stderr.strip():
            output = (output + "\n" + result.stderr.strip()).strip()
        if output:
            self.write_log(output)
        if result.returncode != 0:
            messagebox.showerror(tr("操作失败", "Operation failed"), output or str(result.returncode))
        self.refresh()
        return result

    def refresh(self):
        try:
            result = subprocess.run(command_for_core(["status", "--json"]), capture_output=True, text=True,
                                    timeout=30, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            self.status = json.loads(result.stdout) if result.returncode == 0 else {}
        except (OSError, subprocess.SubprocessError, ValueError):
            self.status = {}

        ready = bool(self.status.get("dataPathReady"))
        root = self.status.get("dataRoot") or ""
        if ready:
            self.path_text.set(tr("数据目录：", "Data folder: ") + root)
        else:
            self.path_text.set(tr("未找到 Claude 数据目录。请选择包含 claude-code-sessions 和 config.json 的文件夹。",
                                  "Claude data folder not found. Choose a folder containing claude-code-sessions and config.json."))
        accounts = self.status.get("accounts", [])
        current = self.status.get("currentAccount") or tr("未知", "unknown")
        self.account_text.set(tr("当前账号：", "Current account: ") + str(current)[:12]
                              + tr(f"    账号目录：{len(accounts)} 个", f"    Account folders: {len(accounts)}"))
        self.vault_text.set(tr("保险库：", "Vault: ") + str(self.status.get("vaultSessions", 0))
                            + tr(" 个对话", " chats"))
        self.auto_var.set(bool(self.status.get("autoBackup")))
        for widget in (self.restore_button, self.backup_button, self.undo_button, self.auto_toggle):
            widget.configure(state="normal" if ready else "disabled")
        self.undo_button.configure(state="normal" if ready and self.status.get("canUndo") else "disabled")
        if ready and self.status.get("claudeRunning"):
            self.write_log(tr("提示：恢复或撤销前请先退出 Claude。", "Tip: quit Claude before restoring or undoing."))
        if ready:
            self.root.after(3000, self.check_pending_switch)

    def choose_data_folder(self):
        folder = filedialog.askdirectory(title=tr("选择 Claude 数据文件夹", "Choose Claude data folder"))
        if not folder:
            return
        if os.path.basename(folder).lower() == "claude-code-sessions":
            folder = os.path.dirname(folder)
        config_path = os.path.join(folder, "config.json")
        sessions_path = os.path.join(folder, "claude-code-sessions")
        if not os.path.isfile(config_path) or not os.path.isdir(sessions_path):
            messagebox.showwarning(tr("目录结构不匹配", "Folder doesn't match"),
                                   tr("所选目录需要同时包含 config.json 和 claude-code-sessions。",
                                      "The selected folder must contain config.json and claude-code-sessions."))
            return
        PATHS_FILE.parent.mkdir(parents=True, exist_ok=True)
        PATHS_FILE.write_text(json.dumps({"app_dir": folder}, ensure_ascii=False, indent=2), encoding="utf-8")
        os.environ["CSV_APP_DIR"] = folder
        import importlib
        importlib.reload(core)
        self.write_log(tr("已保存 Claude 数据目录。", "Claude data folder saved."))
        self.refresh()

    def restore(self):
        if self.status.get("claudeRunning"):
            messagebox.showinfo(tr("先退出 Claude", "Quit Claude first"),
                                tr("请先正常退出 Claude，再点恢复。完成后可以重新打开 Claude。",
                                   "Quit Claude normally, then retry. You can reopen it after the restore."))
            return
        if messagebox.askyesno(tr("恢复对话？", "Restore chats?"),
                               tr("会先备份现有列表，再把备份恢复到本机各个 Claude 账号。",
                                  "The current lists will be backed up first, then restored to this computer's Claude accounts.")):
            self.run_core(["sync", "--all"])

    def undo(self):
        if self.status.get("claudeRunning"):
            messagebox.showinfo(tr("先退出 Claude", "Quit Claude first"),
                                tr("请先正常退出 Claude，再点撤销。", "Quit Claude normally, then retry Undo."))
            return
        if messagebox.askyesno(tr("撤销上次操作？", "Undo the last action?")):
            self.run_core(["rollback"])

    def toggle_auto(self):
        action = "uninstall-agent" if self.status.get("autoBackup") else "install-agent"
        self.run_core([action])

    def open_vault(self):
        try:
            os.startfile(str(VAULT_DIR))
        except OSError as exc:
            messagebox.showerror(tr("无法打开文件夹", "Couldn't open folder"), str(exc))

    def check_pending_switch(self):
        pending = load_json(core.PENDING_FILE)
        if not pending:
            return
        try:
            os.remove(core.PENDING_FILE)
        except OSError:
            pass
        count = pending.get("missing", 0)
        if messagebox.askyesno(tr("检测到账号切换", "Account switch detected"),
                               tr(f"当前账号缺少 {count} 个之前的对话。现在恢复吗？",
                                  f"This account is missing {count} previous chat(s). Restore now?")):
            self.restore()


def main():
    if os.name != "nt":
        raise SystemExit("The Windows UI must be run on Windows.")
    global VAULT_DIR, CORE_EXE, core
    VAULT_DIR, CORE_EXE = bootstrap()
    core = importlib.import_module("claude_sessions")
    root = tk.Tk()
    SessionKeeperWindow(root)
    root.mainloop()


if __name__ == "__main__":
    main()
