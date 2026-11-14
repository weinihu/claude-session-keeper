#!/usr/bin/env python3
"""
Claude Session Keeper — keep your Claude Code (desktop app) chats when you switch accounts.

Why chats "disappear":
  * Chat transcripts live in ~/.claude/projects/<encoded-path>/<cliSessionId>.jsonl and are shared
    by every account, so switching accounts never deletes them.
  * The sidebar list lives in
    ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json,
    one per account. A new account starts with an empty list, so the chats look gone.

Commands:
  backup    save every account's chat list into the vault (~/.claude/session-vault/)
  restore   write vault chats into the current account (--all: every account on this Mac);
            rebuilds list entries for orphaned transcripts; follows moved project folders (path_remaps)
  sync      backup + restore (quit Claude first — the app does this for you)
  prune     delete chats that don't match keep_rules (undoable)
  rollback  undo the last restore / prune
  status    show accounts, vault and orphaned transcripts
  auto      what the background job runs every minute: backup + account-switch detection

Python standard library only. Every write is preceded by a snapshot in ~/.claude/session-vault/snapshots/.
Not affiliated with Anthropic. Uses undocumented local files of the Claude desktop app.
"""
import argparse
import copy
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid

HOME = os.path.expanduser("~")
APP_DIR = os.path.join(HOME, "Library", "Application Support", "Claude")
SESS_ROOT = os.environ.get("CSV_SESS_ROOT") or os.path.join(APP_DIR, "claude-code-sessions")
APP_CONFIG = os.environ.get("CSV_APP_CONFIG") or os.path.join(APP_DIR, "config.json")
PROJECTS = os.environ.get("CSV_PROJECTS") or os.path.join(HOME, ".claude", "projects")

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
# 保险库放在主目录：外接硬盘上的文件，后台任务没有权限访问
VAULT = os.environ.get("CSV_VAULT") or os.path.join(HOME, ".claude", "session-vault")
VAULT_SESS = os.path.join(VAULT, "sessions")
VAULT_SNAP = os.path.join(VAULT, "snapshots")
TOOL_CONFIG = os.path.join(TOOL_DIR, "config.json")

# 复制到别的账号时去掉的字段：这些和账号绑定（连接器配置、提示词快照），新账号会自己重新生成。
ACCOUNT_BOUND_FIELDS = ["remoteMcpServersConfig", "promptAppendSnapshot", "toolSurfaceSnapshot"]
# 最后活动时间相同时，只有这些字段变了才算"有改动"（改名、归档、星标、模型等）
MEANINGFUL_FIELDS = ["title", "isArchived", "isStarred", "cliSessionId", "priorCliSessionIds",
                     "model", "effort", "permissionMode"]
RECON_NS = uuid.UUID("6f1c2a52-7d4e-4b8a-9c1e-5a3b2d1e0f99")

DEFAULT_CONFIG = {
    "path_remaps": {},          # 旧项目路径前缀 -> 新路径前缀
    "skip_scheduled": True,     # 不同步定时任务自动产生的会话
    "rebuild_orphans": True,    # 为没有列表记录的旧 transcript 重建条目
    "snapshots_keep": 30,
    # 保留规则：恢复时只带这些对话过去；"按规则清理"会删掉其余的
    "keep_rules": {
        "enabled": False,
        "max_age_days": 3,          # 只保留最近几天有活动的对话
        "max_per_project": 2,       # 每个项目最多保留几个最新的
        "always_keep": {},          # 项目名 -> 标题正则；匹配的对话不受上面限制，每个匹配内容保留最新一个
    },
}


# ---------------------------------------------------------------- i18n
def _is_zh():
    lang = os.environ.get("CSV_LANG") or os.environ.get("LANG") or ""
    if not lang:
        try:
            out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"],
                                 capture_output=True, text=True, timeout=3).stdout
            lang = out.split('"')[1] if '"' in out else out
        except Exception:
            lang = ""
    return lang.lower().startswith("zh")


ZH = _is_zh()


def T(zh, en):
    return zh if ZH else en


# ---------------------------------------------------------------- utils
def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def tool_config():
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(load_json(TOOL_CONFIG, {}) or {})
    return cfg


def encode_project(path):
    """Claude Code 把项目路径编码成目录名：非字母数字一律换成 '-'。"""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def remap_path(path, remaps):
    if not path:
        return path
    for old, new in sorted(remaps.items(), key=lambda kv: -len(kv[0])):
        old = old.rstrip("/")
        if path == old or path.startswith(old + "/"):
            return new.rstrip("/") + path[len(old):]
    return path


def activity(meta):
    return meta.get("lastActivityAt") or meta.get("createdAt") or 0


def fmt_ms(ms):
    if not ms:
        return "-"
    return dt.datetime.fromtimestamp(ms / 1000).strftime("%m-%d %H:%M")


def app_running():
    if os.environ.get("CSV_IGNORE_RUNNING"):
        return False
    r = subprocess.run(["ps", "-axo", "comm"], capture_output=True, text=True)
    return any(line.strip().endswith("/Claude.app/Contents/MacOS/Claude") for line in r.stdout.splitlines())


# ---------------------------------------------------------------- account folders
def account_dirs():
    """返回 [(accountUuid, orgUuid, 路径)]。"""
    out = []
    if not os.path.isdir(SESS_ROOT):
        return out
    for acc in sorted(os.listdir(SESS_ROOT)):
        ap = os.path.join(SESS_ROOT, acc)
        if not os.path.isdir(ap):
            continue
        for org in sorted(os.listdir(ap)):
            op = os.path.join(ap, org)
            if os.path.isdir(op):
                out.append((acc, org, op))
    return out


def current_account():
    return (load_json(APP_CONFIG, {}) or {}).get("lastKnownAccountUuid")


def current_dirs():
    acc = current_account()
    dirs = [d for d in account_dirs() if d[0] == acc]
    if len(dirs) > 1:  # 一个账号多个组织：取最近活跃的那个
        dirs.sort(key=lambda d: os.path.getmtime(d[2]), reverse=True)
        dirs = dirs[:1]
    return acc, dirs


def read_sessions(folder):
    res = {}
    for name in os.listdir(folder):
        if name.startswith("local_") and name.endswith(".json"):
            meta = load_json(os.path.join(folder, name))
            if isinstance(meta, dict) and meta.get("sessionId"):
                res[meta["sessionId"]] = meta
    return res


# ---------------------------------------------------------------- vault
def read_vault():
    res = {}
    if os.path.isdir(VAULT_SESS):
        for name in os.listdir(VAULT_SESS):
            if name.endswith(".json"):
                meta = load_json(os.path.join(VAULT_SESS, name))
                if isinstance(meta, dict) and meta.get("sessionId"):
                    res[meta["sessionId"]] = meta
    return res


DELETED_FILE = os.path.join(VAULT, "deleted.json")
SEEN_FILE = os.path.join(VAULT, "seen.json")


def read_deleted():
    return load_json(DELETED_FILE, {}) or {}


def deleted_cli_ids(deleted):
    ids = set()
    for d in deleted.values():
        ids.add(d.get("cliSessionId"))
        ids.update(d.get("priorCliSessionIds") or [])
    ids.discard(None)
    return ids


def current_seen():
    return {f"{a}/{o}": sorted(read_sessions(f)) for a, o, f in account_dirs()}


def tombstone(sids, vault, reason="在 Claude 里删除"):
    """记下被删除的会话：从保险库和所有账号列表里移除，以后备份、恢复都不会再带回来。"""
    deleted = read_deleted()
    removed = 0
    for sid in sids:
        meta = vault.get(sid) or {}
        deleted[sid] = {"cliSessionId": meta.get("cliSessionId"),
                        "priorCliSessionIds": meta.get("priorCliSessionIds") or [],
                        "title": meta.get("title"), "cwd": meta.get("cwd"),
                        "reason": reason, "at": int(time.time() * 1000)}
        try:
            os.remove(os.path.join(VAULT_SESS, sid + ".json"))
        except OSError:
            pass
        vault.pop(sid, None)
        for _, _, folder in account_dirs():
            path = os.path.join(folder, sid + ".json")
            if os.path.exists(path):
                os.remove(path)
                removed += 1
    write_json(DELETED_FILE, deleted)
    return removed


LOCK_FILE = os.path.join(VAULT, "busy.lock")


class busy_lock:
    """恢复/撤销期间加锁，后台任务看到锁就跳过这一轮，不会把这期间的变化误判成删除。"""
    def __enter__(self):
        os.makedirs(VAULT, exist_ok=True)
        open(LOCK_FILE, "w").close()

    def __exit__(self, *exc):
        try:
            os.remove(LOCK_FILE)
        except OSError:
            pass


def locked():
    try:
        return time.time() - os.path.getmtime(LOCK_FILE) < 600
    except OSError:
        return False


def detect_deletions(vault):
    """对比上一轮：账号目录还在、但里面某个会话文件没了 = 用户在 Claude 里删除了它。"""
    prev = load_json(SEEN_FILE)
    now = current_seen()
    gone = set()
    if isinstance(prev, dict):
        for folder, sids in prev.items():
            if folder not in now:                  # 整个目录没了是退出登录，不算删除
                continue
            if not now[folder] and len(sids) > 3:  # 列表一下子全空了，也当作退出登录
                continue
            gone.update(set(sids) - set(now[folder]))
    if gone:
        removed = tombstone(sorted(gone), vault)
        stamp = dt.datetime.now().strftime("%m-%d %H:%M")
        print(T(f"[{stamp}] 检测到删除了 {len(gone)} 个会话，已同步移除（其他账号里的副本 {removed} 个），以后不会再恢复",
                f"[{stamp}] {len(gone)} chat(s) deleted in Claude — removed {removed} copies from other accounts; they won't be restored again"))
        now = current_seen()
    write_json(SEEN_FILE, now)


def snapshot(reason):
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    dst = os.path.join(VAULT_SNAP, f"{stamp}-{reason}")
    n = 2
    while os.path.exists(dst):  # 同一秒内多次快照：加序号，避免混进上一份
        dst = os.path.join(VAULT_SNAP, f"{stamp}-{reason}-{n}")
        n += 1
    if os.path.isdir(SESS_ROOT):
        shutil.copytree(SESS_ROOT, dst, ignore=shutil.ignore_patterns("waiting-input", "*.tmp"),
                        dirs_exist_ok=True)
    keep = tool_config()["snapshots_keep"]
    snaps = sorted(os.listdir(VAULT_SNAP)) if os.path.isdir(VAULT_SNAP) else []
    for old in snaps[:-keep] if keep > 0 else []:
        shutil.rmtree(os.path.join(VAULT_SNAP, old), ignore_errors=True)
    return dst


def cmd_backup(args, quiet=False):
    vault = read_vault()
    deleted = read_deleted()
    if not getattr(args, "no_detect", False):
        detect_deletions(vault)
        deleted = read_deleted()
    added = updated = 0
    for acc, org, folder in account_dirs():
        for sid, meta in read_sessions(folder).items():
            if sid in deleted:
                continue
            old = vault.get(sid)
            try:
                mtime = os.path.getmtime(os.path.join(folder, sid + ".json"))
            except OSError:
                mtime = 0
            same = old is not None and all(old.get(k) == meta.get(k) for k in MEANINGFUL_FIELDS)
            newer_file = old is not None and mtime > (old.get("_vault") or {}).get("srcMtime", 0)
            if old is None or activity(meta) > activity(old) or (
                    activity(meta) == activity(old) and not same and newer_file):
                rec = copy.deepcopy(meta)
                rec["_vault"] = {"fromAccount": acc, "fromOrg": org, "srcMtime": mtime,
                                 "savedAt": int(time.time() * 1000)}
                write_json(os.path.join(VAULT_SESS, sid + ".json"), rec)
                vault[sid] = rec
                if old is None:
                    added += 1
                else:
                    updated += 1
    if not quiet or added or updated:
        stamp = dt.datetime.now().strftime("%m-%d %H:%M")
        print(T(f"[{stamp}] 备份完成：新增 {added}，更新 {updated}，保险库共 {len(vault)} 个会话",
                f"[{stamp}] Backup done: {added} new, {updated} updated, {len(vault)} chats in vault"))
    return vault


# ---------------------------------------------------------------- transcripts
def scan_transcript(path):
    """从 jsonl 里提取重建会话条目所需的信息。"""
    info = {"cwd": None, "first": None, "last": None, "title": None, "firstPrompt": None,
            "model": None, "prompts": set(), "lastAssistantUuid": None,
            "permissionMode": None, "scheduled": False, "users": 0}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = d.get("type")
            ts = d.get("timestamp")
            if ts and not d.get("isSidechain"):
                info["first"] = info["first"] or ts
                info["last"] = ts
            if t in ("custom-title", "agent-name"):
                info["title"] = d.get("customTitle") or d.get("agentName") or info["title"]
            elif t == "summary" and not info["title"]:
                info["title"] = d.get("summary")
            elif t == "relocated" and d.get("relocatedCwd"):
                info["cwd"] = d["relocatedCwd"]
            if d.get("isSidechain"):
                continue
            if d.get("cwd") and not info["cwd"]:
                info["cwd"] = d["cwd"]
            if t == "user":
                info["users"] += 1
                if d.get("permissionMode"):
                    info["permissionMode"] = d["permissionMode"]
                if d.get("promptId"):
                    info["prompts"].add(d["promptId"])
                content = (d.get("message") or {}).get("content")
                if isinstance(content, list):
                    content = " ".join(c.get("text", "") for c in content
                                       if isinstance(c, dict) and c.get("type") == "text")
                if isinstance(content, str) and info["firstPrompt"] is None and content.strip():
                    if content.lstrip().startswith("<scheduled-task"):
                        info["scheduled"] = True
                    info["firstPrompt"] = content
            elif t == "assistant":
                info["lastAssistantUuid"] = d.get("uuid")
                m = (d.get("message") or {}).get("model")
                if m and not m.startswith("<"):
                    info["model"] = m
    return info


def to_ms(ts):
    if not ts:
        return 0
    try:
        return int(dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return 0


def clean_title(text):
    text = re.sub(r"<[^>]+>", " ", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    return (text[:40] + "…") if len(text) > 40 else (text or "未命名对话")


def all_transcripts():
    """{cliSessionId: jsonl 路径}；同一 id 出现在多个项目目录时取最大的那份。"""
    res = {}
    if not os.path.isdir(PROJECTS):
        return res
    for proj in os.listdir(PROJECTS):
        pdir = os.path.join(PROJECTS, proj)
        if not os.path.isdir(pdir):
            continue
        for name in os.listdir(pdir):
            if name.endswith(".jsonl"):
                cid = name[:-6]
                p = os.path.join(pdir, name)
                if cid not in res or os.path.getsize(p) > os.path.getsize(res[cid]):
                    res[cid] = p
    return res


def referenced_cli_ids(metas):
    ids = set()
    for m in metas:
        if m.get("cliSessionId"):
            ids.add(m["cliSessionId"])
        ids.update(m.get("priorCliSessionIds") or [])
    return ids


def rebuild_orphans(vault, cfg, verbose=True, persist=True):
    """为没有任何会话列表记录的 transcript 生成条目，存进保险库。"""
    transcripts = all_transcripts()
    known = referenced_cli_ids(vault.values()) | deleted_cli_ids(read_deleted())
    made = skipped = 0
    for cid, path in sorted(transcripts.items()):
        if cid in known:
            continue
        info = scan_transcript(path)
        if info["users"] == 0 or not info["cwd"]:
            skipped += 1
            continue
        if info["scheduled"] and cfg["skip_scheduled"]:
            skipped += 1
            continue
        created, last = to_ms(info["first"]), to_ms(info["last"])
        sid = "local_" + str(uuid.uuid5(RECON_NS, cid))
        meta = {
            "sessionId": sid,
            "cliSessionId": cid,
            "cwd": info["cwd"],
            "originCwd": info["cwd"],
            "createdAt": created,
            "lastActivityAt": last,
            "lastTurnEdgeAt": last,
            "model": info["model"] or "claude-opus-5-5",
            "effort": "medium",
            "isArchived": False,
            "title": info["title"] or clean_title(info["firstPrompt"]),
            "titleSource": "auto",
            "permissionMode": info["permissionMode"] or "default",
            "completedTurns": len(info["prompts"]) or info["users"],
            "lastAssistantUuid": info["lastAssistantUuid"],
            "lastAssistantCliSessionId": cid,
            "_vault": {"rebuiltFrom": path, "savedAt": int(time.time() * 1000)},
        }
        if persist:
            write_json(os.path.join(VAULT_SESS, sid + ".json"), meta)
        vault[sid] = meta
        made += 1
        if verbose:
            print(f"  {T('重建', 'rebuilt')}  {fmt_ms(last)}  {meta['title'][:30]:<30}  {info['cwd']}")
    if verbose:
        print(T(f"孤立 transcript 重建：{made} 个（跳过 {skipped} 个空的/定时任务）",
                f"Rebuilt {made} chat(s) from orphaned transcripts ({skipped} empty/scheduled skipped)"))
    return made


def link_transcript(cid, new_cwd, transcripts, dry):
    """项目搬家后，CLI 会到 新路径 对应的目录里找 transcript，这里把它硬链接过去。"""
    src = transcripts.get(cid)
    if not src:
        return False
    dst_dir = os.path.join(PROJECTS, encode_project(new_cwd))
    dst = os.path.join(dst_dir, cid + ".jsonl")
    if os.path.exists(dst):
        return False
    if dry:
        return True
    os.makedirs(dst_dir, exist_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)
    side = src[:-6]  # 同名目录：子代理 transcript、工具结果等
    if os.path.isdir(side) and not os.path.exists(dst[:-6]):
        shutil.copytree(side, dst[:-6], copy_function=_link_or_copy)
    return True


def _link_or_copy(src, dst):
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


# ---------------------------------------------------------------- keep rules
def project_of(meta, cfg):
    return os.path.basename(remap_path(meta.get("cwd") or "", cfg["path_remaps"]).rstrip("/"))


def keep_set(metas, cfg, now_ms=None):
    """按保留规则算出要留下的 sessionId 集合。metas: {sid: meta}"""
    rules = dict(DEFAULT_CONFIG["keep_rules"])
    rules.update(cfg.get("keep_rules") or {})
    if not rules.get("enabled", True):
        return set(metas)
    now_ms = now_ms or int(time.time() * 1000)
    cutoff = now_ms - rules["max_age_days"] * 86400 * 1000
    by_project = {}
    for sid, m in metas.items():
        if m.get("scheduledTaskId") and cfg["skip_scheduled"]:
            continue
        by_project.setdefault(project_of(m, cfg), []).append((activity(m), sid, m))
    keep = set()
    for proj, items in by_project.items():
        items.sort(key=lambda x: x[0], reverse=True)
        pattern = (rules.get("always_keep") or {}).get(proj)
        seen_match = set()
        normal = []
        for act, sid, m in items:
            mt = re.search(pattern, m.get("title") or "") if pattern else None
            if mt:
                if mt.group(0) not in seen_match:   # 每一季只留最新的一个
                    seen_match.add(mt.group(0))
                    keep.add(sid)
            else:
                normal.append((act, sid))
        keep.update(sid for act, sid in normal[:rules["max_per_project"]] if act >= cutoff)
    return keep


def all_known_sessions():
    """保险库 + 所有账号目录里的会话（同一个以最后活动最新的为准）。"""
    metas = dict(read_vault())
    for _, _, folder in account_dirs():
        for sid, m in read_sessions(folder).items():
            if sid not in metas or activity(m) > activity(metas[sid]):
                metas[sid] = m
    deleted = read_deleted()
    return {sid: m for sid, m in metas.items() if sid not in deleted}


def cmd_prune(args):
    """按保留规则清理：所有账号里不符合规则的对话都删掉（先拍快照，可以撤销）。"""
    cfg = tool_config()
    metas = all_known_sessions()
    keep = keep_set(metas, cfg)
    drop = {}
    for _, _, folder in account_dirs():
        for sid in read_sessions(folder):
            if sid not in keep:
                drop.setdefault(sid, []).append(os.path.join(folder, sid + ".json"))
    if args.json:
        items = [{"title": metas.get(sid, {}).get("title"), "project": project_of(metas.get(sid, {}), cfg),
                  "lastActivityAt": activity(metas.get(sid, {}))} for sid in drop]
        print(json.dumps({"count": len(drop), "items": items}, ensure_ascii=False))
        return
    if args.dry_run or not drop:
        for sid in sorted(drop, key=lambda x: activity(metas.get(x, {})), reverse=True):
            m = metas.get(sid, {})
            print(f"  [{T('将删除', 'will delete')}] {fmt_ms(activity(m))}  {project_of(m, cfg)} | {m.get('title')}")
        print(T(f"共 {len(drop)} 个对话不符合保留规则", f"{len(drop)} chat(s) don't match the keep rules")
              + (T("（预演，未删除）", " (dry run, nothing deleted)") if drop else ""))
        return
    if app_running() and not args.force:
        sys.exit(T("Claude 正在运行。请先退出 Claude 再清理。", "Claude is running. Quit Claude first."))
    with busy_lock():
        snap = snapshot("before-prune")
        manifest = [{"path": p, "new": False, "removed": True, "sid": sid,
                     "rel": os.path.relpath(p, SESS_ROOT)} for sid, paths in drop.items() for p in paths]
        vault = read_vault()
        tombstone(list(drop), vault, reason="按保留规则清理")
        write_json(os.path.join(snap, "manifest.json"), {"written": manifest})
        write_json(SEEN_FILE, current_seen())
    print(T(f"已清理 {len(drop)} 个对话（可以撤销）", f"Cleaned up {len(drop)} chat(s) (can be undone)"))


# ---------------------------------------------------------------- restore
def prepare_for_account(meta, acc, cfg):
    out = {k: v for k, v in meta.items() if k != "_vault"}
    from_acc = (meta.get("_vault") or {}).get("fromAccount")
    if from_acc and from_acc != acc:
        for k in ACCOUNT_BOUND_FIELDS:
            out.pop(k, None)
    for key in ("cwd", "originCwd", "gitAnchorsFolderRealpath"):
        if out.get(key):
            out[key] = remap_path(out[key], cfg["path_remaps"])
    if out.get("shellFolders"):
        out["shellFolders"] = [remap_path(p, cfg["path_remaps"]) for p in out["shellFolders"]]
    if out.get("writtenRepositories"):
        out["writtenRepositories"] = [remap_path(p, cfg["path_remaps"]) for p in out["writtenRepositories"]]
    return out


def plan_restore(vault, acc, folder, cfg, transcripts, verbose=False):
    """算出要往这个账号目录写哪些会话：[(sid, 保险库里的原始条目, 处理后的条目, 账号里现有条目或 None)]"""
    existing = read_sessions(folder) if os.path.isdir(folder) else {}
    existing_cli = referenced_cli_ids(existing.values())
    deleted = read_deleted()
    dead_cli = deleted_cli_ids(deleted)
    keep = keep_set({k: v for k, v in vault.items() if k not in deleted}, cfg)
    plan = []
    for sid, meta in sorted(vault.items(), key=lambda kv: activity(kv[1])):
        if sid in deleted or meta.get("cliSessionId") in dead_cli:
            continue
        if sid not in keep:
            continue  # 不符合保留规则（太旧，或者项目里已有更新的对话）
        if meta.get("scheduledTaskId") and cfg["skip_scheduled"]:
            continue
        cur = existing.get(sid)
        if cur is not None and activity(cur) >= activity(meta):
            continue
        if cur is None and meta.get("cliSessionId") in existing_cli:
            continue  # 这个账号已经以别的条目持有同一段对话
        if meta.get("cliSessionId") not in transcripts and not any(
                p in transcripts for p in meta.get("priorCliSessionIds") or []):
            continue  # transcript 已被清理，恢复了也打不开
        out = prepare_for_account(meta, acc, cfg)
        if out.get("cwd") and not os.path.isdir(out["cwd"]):
            if verbose:
                print(f"  {T('跳过（项目目录不存在）', 'skipped (project folder missing)')} {out.get('title')}  {out['cwd']}")
            continue
        plan.append((sid, meta, out, cur))
    return plan


def cmd_restore(args, vault=None):
    with busy_lock():
        _restore(args, vault)


def _restore(args, vault=None):
    cfg = tool_config()
    if not args.dry_run and app_running() and not args.force:
        sys.exit(T("Claude 正在运行。请先退出 Claude 再恢复（App 里的按钮会自动处理），否则 Claude 可能会覆盖恢复结果。确实要继续请加 --force。",
                   "Claude is running. Quit it first (the app's button does this for you), or Claude may overwrite the result. Use --force to override."))
    if vault is None:
        vault = cmd_backup(args)
    if cfg["rebuild_orphans"]:
        rebuild_orphans(vault, cfg, verbose=args.verbose, persist=not args.dry_run)

    if args.target:
        targets = [("target", "target", args.target)]
    elif args.all:
        targets = account_dirs()
        acc = current_account()
        if not any(d[0] == acc for d in targets):
            print(T(f"注意：当前账号 {str(acc)[:8]}… 还没有会话目录。请先在 Claude 里打开一次 Code 标签页，再恢复一次。",
                     f"Note: the current account {str(acc)[:8]}… has no session folder yet. Open the Code tab in Claude once, then restore again."))
    else:
        acc, targets = current_dirs()
        if not targets:
            sys.exit(T(f"找不到当前账号 {acc} 的会话目录。请先用新账号登录 Claude 并打开一次 Code 标签页。",
                       f"No session folder for the current account {acc}. Sign in to Claude and open the Code tab once."))
    snap_dir = None
    manifest = []
    if not args.dry_run:
        snap_dir = snapshot("before-restore")
        print(T("写入前快照：", "Snapshot before writing:"), snap_dir)

    transcripts = all_transcripts()
    linked = 0
    for acc, org, folder in targets:
        wrote = 0
        for sid, meta, out, cur in plan_restore(vault, acc, folder, cfg, transcripts, args.verbose):
            if out.get("cwd") != meta.get("cwd"):
                for cid in [out.get("cliSessionId")] + list(out.get("priorCliSessionIds") or []):
                    if cid and link_transcript(cid, out["cwd"], transcripts, args.dry_run):
                        linked += 1
            if args.dry_run:
                print(f"  [{T('预演', 'dry run')}] {T('更新', 'update') if cur else T('新增', 'add')}  {fmt_ms(activity(out))}  {out.get('title')}")
            else:
                dst = os.path.join(folder, sid + ".json")
                manifest.append({"path": dst, "new": not os.path.exists(dst),
                                 "rel": os.path.relpath(dst, SESS_ROOT) if not args.target else None})
                write_json(dst, out)
            wrote += 1
        print(T(f"账号 {acc[:8]}… / {org[:8]}…：写入 {wrote} 个会话", f"Account {acc[:8]}… / {org[:8]}…: wrote {wrote} chat(s)")
              + (T('（预演，未写入）', ' (dry run)') if args.dry_run else ''))
    if snap_dir and not args.target:
        write_json(os.path.join(snap_dir, "manifest.json"), {"written": manifest})
        write_json(SEEN_FILE, current_seen())
    if linked:
        print(T(f"已为搬家的项目链接 {linked} 份 transcript", f"Linked {linked} transcript(s) for moved projects"))
    if not args.dry_run:
        print(T("完成。重新打开 Claude 后，侧边栏就能看到之前账号的对话，点进去即可继续。",
                "Done. Reopen Claude and your chats from other accounts are in the sidebar — click one to continue."))


def cmd_sync(args):
    vault = cmd_backup(args)
    cmd_restore(args, vault)


# ---------------------------------------------------------------- rollback
def cmd_rollback(args):
    with busy_lock():
        _rollback(args)


def _rollback(args):
    """撤销最近一次恢复：删掉那次新增的条目，被覆盖的条目从快照里拿回来。"""
    if app_running() and not args.force:
        sys.exit(T("Claude 正在运行。请先退出 Claude 再撤销。", "Claude is running. Quit Claude first."))
    snaps = sorted(os.listdir(VAULT_SNAP)) if os.path.isdir(VAULT_SNAP) else []
    for name in reversed(snaps):
        d = os.path.join(VAULT_SNAP, name)
        man = load_json(os.path.join(d, "manifest.json"))
        if not man or os.path.exists(os.path.join(d, "rolled-back")):
            continue
        removed = restored = 0
        untomb = []
        for item in man.get("written", []):
            if item.get("removed"):
                src = os.path.join(d, item["rel"])
                if os.path.exists(src):
                    os.makedirs(os.path.dirname(item["path"]), exist_ok=True)
                    shutil.copy2(src, item["path"])
                    restored += 1
                untomb.append(item["sid"])
            elif item["new"]:
                if os.path.exists(item["path"]):
                    os.remove(item["path"])
                    removed += 1
            elif item.get("rel") and os.path.exists(os.path.join(d, item["rel"])):
                shutil.copy2(os.path.join(d, item["rel"]), item["path"])
                restored += 1
        if untomb:
            deleted = read_deleted()
            for sid in untomb:
                deleted.pop(sid, None)
            write_json(DELETED_FILE, deleted)
        open(os.path.join(d, "rolled-back"), "w").close()
        write_json(SEEN_FILE, current_seen())
        if untomb:
            print(T(f"已撤销：找回 {restored} 个被清理的会话。", f"Undone: brought back {restored} cleaned-up chat(s)."))
        else:
            print(T(f"已撤销：移除 {removed} 个恢复的会话，还原 {restored} 个被更新的会话。", f"Undone: removed {removed} restored chat(s), reverted {restored}."))
        return
    print(T("没有可以撤销的操作。", "Nothing to undo."))


# ---------------------------------------------------------------- status
def status_data():
    acc_now = current_account()
    accounts, all_meta = [], []
    for acc, org, folder in account_dirs():
        s = read_sessions(folder)
        all_meta += s.values()
        accounts.append({"account": acc, "org": org, "sessions": len(s), "current": acc == acc_now})
    vault = read_vault()
    transcripts = all_transcripts()
    known = referenced_cli_ids(list(vault.values()) + all_meta) | deleted_cli_ids(read_deleted())
    size = 0
    for root, _, files in os.walk(VAULT):
        for f in files:
            try:
                size += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    can_undo = False
    if os.path.isdir(VAULT_SNAP):
        for name in os.listdir(VAULT_SNAP):
            d = os.path.join(VAULT_SNAP, name)
            if os.path.exists(os.path.join(d, "manifest.json")) and not os.path.exists(os.path.join(d, "rolled-back")):
                can_undo = True
    log_last = None
    try:
        log_last = int(os.path.getmtime(os.path.join(VAULT, "last-run")) * 1000)
    except OSError:
        pass
    return {
        "currentAccount": acc_now,
        "claudeRunning": app_running(),
        "accounts": accounts,
        "vaultSessions": len(vault),
        "transcripts": len(transcripts),
        "orphans": len([c for c in transcripts if c not in known]),
        "vaultBytes": size,
        "vaultPath": VAULT,
        "autoBackup": os.path.exists(AGENT_PLIST),
        "lastBackupAt": log_last,
        "canUndo": can_undo,
    }


def cmd_status(args):
    if getattr(args, "json", False):
        print(json.dumps(status_data(), ensure_ascii=False))
        return
    cfg = tool_config()
    acc_now = current_account()
    print(f"当前登录账号：{acc_now}")
    print(f"Claude 运行中：{'是' if app_running() else '否'}\n")
    all_meta = []
    for acc, org, folder in account_dirs():
        s = read_sessions(folder)
        all_meta += s.values()
        mark = "  <- 当前" if acc == acc_now else ""
        print(f"账号 {acc} / 组织 {org[:8]}…：{len(s)} 个会话{mark}")
    vault = read_vault()
    print(f"\n保险库：{len(vault)} 个会话  ({VAULT_SESS})")
    transcripts = all_transcripts()
    known = referenced_cli_ids(list(vault.values()) + all_meta) | deleted_cli_ids(read_deleted())
    orphans = [c for c in transcripts if c not in known]
    print(f"transcript 共 {len(transcripts)} 份，其中 {len(orphans)} 份没有任何会话列表记录（sync 时会重建）")
    if cfg["path_remaps"]:
        print("\n路径映射：")
        for o, n in cfg["path_remaps"].items():
            print(f"  {o}  ->  {n}")
    if args.verbose:
        print("\n保险库会话（按最近活动排序）：")
        for m in sorted(vault.values(), key=activity, reverse=True):
            print(f"  {fmt_ms(activity(m))}  {str(m.get('title'))[:36]:<36}  {m.get('cwd')}")


# ---------------------------------------------------------------- auto（后台每分钟跑一次）
STATE_FILE = os.path.join(VAULT, "state.json")
PENDING_FILE = os.path.join(VAULT, "pending-switch.json")
GUI_BUNDLE_ID = "local.claude-session-vault.app"


def trim_log(limit=512 * 1024):
    try:
        if os.path.getsize(LOG_PATH) > limit:
            with open(LOG_PATH, encoding="utf-8", errors="replace") as f:
                tail = f.read()[-limit // 4:]
            with open(LOG_PATH, "w", encoding="utf-8") as f:
                f.write(tail)
    except OSError:
        pass


def cmd_auto(args):
    """备份；如果发现换了账号、而且新账号缺对话，就打开图形界面问要不要恢复。"""
    if locked():
        return
    trim_log()
    cfg = tool_config()
    vault = cmd_backup(args, quiet=True)
    with open(os.path.join(VAULT, "last-run"), "w"):
        pass
    acc = current_account()
    folders = sorted(f"{a}/{o}" for a, o, _ in account_dirs())
    state = load_json(STATE_FILE, {}) or {}
    if "folders" not in state:  # 第一次运行（或旧版状态）：只记下现状
        write_json(STATE_FILE, {"lastAccount": acc, "folders": folders})
        return
    new_folders = [f for f in folders if f not in state["folders"]]
    if acc == state.get("lastAccount") and not new_folders:
        if folders != state["folders"]:   # 有账号目录被删（退出登录）：记下即可
            write_json(STATE_FILE, {"lastAccount": acc, "folders": folders})
        return
    acc_dirs = [d for d in account_dirs() if d[0] == acc]
    if not acc_dirs:            # 新账号还没打开过 Code 标签页，下一分钟再看
        return
    if cfg["rebuild_orphans"]:
        rebuild_orphans(vault, cfg, verbose=False)
    transcripts = all_transcripts()
    missing = max(len(plan_restore(vault, a, f, cfg, transcripts)) for a, _, f in acc_dirs)
    write_json(STATE_FILE, {"lastAccount": acc, "folders": folders})
    stamp = dt.datetime.now().strftime("%m-%d %H:%M")
    print(T(f"[{stamp}] 检测到换号：{str(state.get('lastAccount'))[:8]}… -> {str(acc)[:8]}…，缺 {missing} 个对话",
            f"[{stamp}] Account switch: {str(state.get('lastAccount'))[:8]}… -> {str(acc)[:8]}…, {missing} chat(s) missing"))
    if missing and not getattr(args, "no_open", False):
        write_json(PENDING_FILE, {"account": acc, "missing": missing, "at": int(time.time() * 1000)})
        subprocess.run(["open", "-b", GUI_BUNDLE_ID], capture_output=True)


# ---------------------------------------------------------------- launchd
AGENT_LABEL = "local.claude-session-vault.backup"
AGENT_PLIST = os.path.join(HOME, "Library", "LaunchAgents", AGENT_LABEL + ".plist")
LOG_PATH = os.path.join(HOME, "Library", "Logs", "claude-session-vault.log")


def cmd_install_agent(args):
    seconds = max(60, args.seconds)
    script = os.path.join(VAULT, "claude_sessions.py")
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{AGENT_LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>{script}</string><string>auto</string>
  </array>
  <key>StartInterval</key><integer>{seconds}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>{LOG_PATH}</string>
  <key>StandardErrorPath</key><string>{LOG_PATH}</string>
</dict></plist>
"""
    os.makedirs(os.path.dirname(AGENT_PLIST), exist_ok=True)
    os.makedirs(VAULT, exist_ok=True)
    # 后台任务运行放在主目录里的副本（外接盘上的脚本，后台任务没有权限读取）
    if os.path.abspath(__file__) != script:
        shutil.copy2(os.path.abspath(__file__), script)
        vault_cfg = os.path.join(VAULT, "config.json")
        if os.path.exists(TOOL_CONFIG) and not os.path.exists(vault_cfg):
            shutil.copy2(TOOL_CONFIG, vault_cfg)
    with open(AGENT_PLIST, "w") as f:
        f.write(plist)
    subprocess.run(["launchctl", "unload", AGENT_PLIST], capture_output=True)
    subprocess.run(["launchctl", "load", AGENT_PLIST], check=True)
    if not os.path.exists(STATE_FILE):
        write_json(STATE_FILE, {"lastAccount": current_account(),
                                "folders": sorted(f"{a}/{o}" for a, o, _ in account_dirs())})
    print(T(f"已开启后台自动备份 + 换号检测：每 {seconds} 秒一次", f"Auto backup + switch detection on (every {seconds}s)"))


def cmd_uninstall_agent(args):
    if os.path.exists(AGENT_PLIST):
        subprocess.run(["launchctl", "unload", AGENT_PLIST], capture_output=True)
        os.remove(AGENT_PLIST)
    print(T("已关闭后台自动备份", "Auto backup turned off"))


# ---------------------------------------------------------------- main
def main():
    p = argparse.ArgumentParser(description="Claude 换号恢复对话")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("backup", help="把所有账号的会话列表存进保险库")
    for name, fn_help in (("restore", "把保险库写回当前账号"), ("sync", "backup + restore（换号后用这个）")):
        sp = sub.add_parser(name, help=fn_help)
        sp.add_argument("--all", action="store_true", help="写入本机所有账号，而不只是当前账号")
        sp.add_argument("--dry-run", action="store_true", help="只预演，不写任何东西")
        sp.add_argument("--force", action="store_true", help="Claude 正在运行时也强制写入")
        sp.add_argument("--target", help="写入指定目录（测试用）")
        sp.add_argument("-v", "--verbose", action="store_true")
    sp = sub.add_parser("status", help="查看状态")
    sp.add_argument("-v", "--verbose", action="store_true")
    sp.add_argument("--json", action="store_true")
    sp = sub.add_parser("prune", help="按保留规则清理旧对话")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--json", action="store_true")
    sp.add_argument("--force", action="store_true")
    sp = sub.add_parser("rollback", help="撤销最近一次恢复")
    sp.add_argument("--force", action="store_true")
    sp = sub.add_parser("install-agent", help="安装后台自动备份 + 换号检测")
    sp.add_argument("--seconds", type=int, default=60)
    sp = sub.add_parser("auto", help="后台任务：备份 + 检测换号")
    sp.add_argument("--no-open", action="store_true", help="检测到换号时不打开界面（测试用）")
    sub.add_parser("uninstall-agent", help="卸载后台定时自动备份")
    args = p.parse_args()
    {"backup": cmd_backup, "restore": cmd_restore, "sync": cmd_sync, "status": cmd_status,
     "install-agent": cmd_install_agent, "uninstall-agent": cmd_uninstall_agent,
     "rollback": cmd_rollback, "auto": cmd_auto, "prune": cmd_prune}[args.cmd](args)


if __name__ == "__main__":
    main()
