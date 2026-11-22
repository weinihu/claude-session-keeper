// Session Keeper for Claude — macOS UI.
// The work is done by claude_sessions.py, which ships inside the app bundle and is installed
// to ~/.claude/session-vault/ on launch (background jobs cannot read scripts inside /Applications
// on external volumes, and the vault copy is what the launchd job runs).
import SwiftUI
import AppKit

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let vaultDir = env["CSV_VAULT"] ?? (home + "/.claude/session-vault")
let script = vaultDir + "/claude_sessions.py"
let configPath = vaultDir + "/config.json"
let claudeBundleID = "com.anthropic.claudefordesktop"
let isZH = (Locale.preferredLanguages.first ?? "").hasPrefix("zh")

/// Pick the Chinese or English string based on the system language.
func L(_ zh: String, _ en: String) -> String { isZH ? zh : en }

struct Status: Decodable {
    struct Account: Decodable { let account: String; let sessions: Int; let current: Bool }
    let currentAccount: String?
    let claudeRunning: Bool
    let accounts: [Account]
    let orgCount: Int?
    let vaultSessions: Int
    let orphans: Int
    let vaultBytes: Int
    let autoBackup: Bool
    let lastBackupAt: Double?
    let canUndo: Bool
}

struct Usage: Decodable {
    struct Account: Decodable, Identifiable {
        let org: String
        let name: String
        let named: Bool
        let current: Bool
        let updatedAt: Double
        let fiveHour: Int?
        let fiveHourEstimated: Bool
        let fiveHourResetAt: Double?
        let weekly: Int?
        let weeklyEstimated: Bool
        let weeklyResetAt: Double?
        var id: String { org }
    }
    let accounts: [Account]
    let sourceFound: Bool
}

struct KeepRules: Equatable {
    var enabled = false
    var days = 3
    var perProject = 2
}

@MainActor
final class Model: ObservableObject {
    @Published var status: Status?
    @Published var log = ""
    @Published var busy = false
    @Published var error: String?
    @Published var confirmRestore = false
    @Published var switchMissing = 0
    @Published var showSwitch = false
    @Published var confirmUndo = false
    @Published var confirmPrune = false
    @Published var pruneSummary = ""
    @Published var pruneCount = 0
    @Published var rules = KeepRules()
    @Published var usage: Usage?
    @Published var renameOrg: String?
    @Published var renameText = ""
    @Published var showRename = false

    // MARK: install / python

    /// Copy the bundled script into the vault (and the default config if there is none).
    /// On the very first launch also turn on the background job.
    func installIfNeeded() async {
        let fm = FileManager.default
        guard let bundled = Bundle.main.path(forResource: "claude_sessions", ofType: "py") else { return }
        try? fm.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)
        let firstRun = !fm.fileExists(atPath: script)
        if !fm.contentsEqual(atPath: bundled, andPath: script) {
            try? fm.removeItem(atPath: script)
            try? fm.copyItem(atPath: bundled, toPath: script)
        }
        if !fm.fileExists(atPath: configPath),
           let def = Bundle.main.path(forResource: "config.default", ofType: "json") {
            try? fm.copyItem(atPath: def, toPath: configPath)
        }
        if firstRun && env["CSV_VAULT"] == nil {
            let (_, out) = await python(["install-agent"])
            append(out)
        }
    }

    func python(_ args: [String]) async -> (Int32, String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [script] + args
            var e = ProcessInfo.processInfo.environment
            e["CSV_LANG"] = isZH ? "zh" : "en"
            p.environment = e
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                return (-1, L("无法运行 python3：", "Couldn't run python3: ") + error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    func refresh() async {
        let (code, out) = await python(["status", "--json"])
        if code == 0, let s = try? JSONDecoder().decode(Status.self, from: Data(out.utf8)) {
            status = s; error = nil
            loadRules()
            await loadUsage()
            checkPendingSwitch()
        } else if out.contains("xcode-select") || out.contains("developer tools") {
            error = L("需要先安装 Apple 命令行工具：在终端运行 xcode-select --install，装好后重新打开本 App。",
                      "Apple's Command Line Tools are required: run xcode-select --install in Terminal, then reopen this app.")
        } else {
            error = L("读取状态失败：\n", "Couldn't read status:\n") + out
        }
    }

    // MARK: usage (read from the Claude app's own local record — no network, no tokens)

    func loadUsage() async {
        let (code, out) = await python(["usage", "--json"])
        if code == 0, let u = try? JSONDecoder().decode(Usage.self, from: Data(out.utf8)) { usage = u }
    }

    func startRename(_ a: Usage.Account) {
        renameOrg = a.org
        renameText = a.named ? a.name : ""
        showRename = true
    }

    func saveRename() async {
        guard let org = renameOrg else { return }
        _ = await python(["usage", "--rename", org, renameText])
        await loadUsage()
    }

    // MARK: keep rules (stored in the vault's config.json)

    func loadRules() {
        guard let data = FileManager.default.contents(atPath: configPath),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kr = cfg["keep_rules"] as? [String: Any] else { return }
        var r = KeepRules()
        r.enabled = kr["enabled"] as? Bool ?? false
        r.days = kr["max_age_days"] as? Int ?? 3
        r.perProject = kr["max_per_project"] as? Int ?? 2
        if r != rules { rules = r }
    }

    func saveRules(_ r: KeepRules) {
        rules = r
        var cfg: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cfg = obj }
        var kr = cfg["keep_rules"] as? [String: Any] ?? [:]
        kr["enabled"] = r.enabled
        kr["max_age_days"] = r.days
        kr["max_per_project"] = r.perProject
        cfg["keep_rules"] = kr
        if let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: configPath))
        }
    }

    // MARK: account switch prompt

    /// The background job leaves pending-switch.json and opens this app when it sees an account switch.
    func checkPendingSwitch() {
        let path = vaultDir + "/pending-switch.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? FileManager.default.removeItem(atPath: path)
        if let acc = obj["account"] as? String, acc != status?.currentAccount { return }
        switchMissing = obj["missing"] as? Int ?? 0
        if switchMissing > 0 && !busy { showSwitch = true; NSApp.activate(ignoringOtherApps: true) }
    }

    func append(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { log += (log.isEmpty ? "" : "\n") + t }
    }

    // MARK: Claude app control

    var claudeApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID)
    }

    func quitClaude() async -> Bool {
        let apps = claudeApps
        if apps.isEmpty { return true }
        append(L("正在退出 Claude…", "Quitting Claude…"))
        apps.forEach { $0.terminate() }
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if claudeApps.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000_000); return true }
        }
        append(L("Claude 没能在 60 秒内退出（可能弹出了确认框），请手动退出后再试。",
                 "Claude didn't quit within 60 seconds (maybe a confirmation dialog?). Quit it manually and try again."))
        return false
    }

    func openClaude() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            append(L("已重新打开 Claude。", "Reopened Claude."))
        }
    }

    /// Quit Claude → run → reopen Claude.
    func runWithClaudeClosed(_ args: [String]) async {
        busy = true; defer { busy = false }
        let wasRunning = !claudeApps.isEmpty
        guard await quitClaude() else { return }
        let (_, out) = await python(args)
        append(out)
        if wasRunning || args.first == "sync" { openClaude() }
        await refresh()
    }

    /// Dry-run the cleanup first and show what would be deleted.
    func preparePrune() async {
        busy = true; defer { busy = false }
        let (_, out) = await python(["prune", "--json"])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            append(out); return
        }
        let items = obj["items"] as? [[String: Any]] ?? []
        pruneCount = obj["count"] as? Int ?? 0
        if pruneCount == 0 {
            append(L("所有对话都符合保留规则，不需要清理。", "Every chat matches the keep rules — nothing to clean up."))
            return
        }
        let lines = items.prefix(12).map { "· \($0["project"] as? String ?? "") | \($0["title"] as? String ?? "")" }
        pruneSummary = lines.joined(separator: "\n")
            + (items.count > 12 ? L("\n…还有 \(items.count - 12) 个", "\n…and \(items.count - 12) more") : "")
        confirmPrune = true
    }

    func run(_ args: [String]) async {
        busy = true; defer { busy = false }
        let (_, out) = await python(args)
        append(out)
        await refresh()
    }
}

struct ContentView: View {
    @StateObject var m = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Claude 换号恢复对话", "Session Keeper for Claude")).font(.title2.bold())
                    Text(L("换号后会自动弹出提醒，点「现在恢复」就行",
                           "Switch accounts — your Claude Code chats follow you"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let e = m.error {
                Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }

            usageCard

            if let s = m.status { statusCard(s) }

            Button {
                m.confirmRestore = true
            } label: {
                Label(L("换号后：恢复所有对话", "Restore chats to this account"), systemImage: "tray.and.arrow.down.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).tint(.orange)
            .disabled(m.busy || m.status == nil)

            HStack {
                Button(L("立即备份", "Back up now")) { Task { await m.run(["backup"]) } }
                Button(L("清理旧对话", "Clean up")) { Task { await m.preparePrune() } }
                    .disabled(!m.rules.enabled)
                    .help(L("先在下面打开保留规则", "Turn on the keep rule below first"))
                Button(L("撤销上次操作", "Undo")) { m.confirmUndo = true }
                    .disabled(!(m.status?.canUndo ?? false))
                Spacer()
                Button(L("打开备份文件夹", "Open vault")) { NSWorkspace.shared.open(URL(fileURLWithPath: vaultDir)) }
            }
            .disabled(m.busy)

            rulesCard

            ZStack(alignment: .topLeading) {
                ScrollView {
                    Text(m.log.isEmpty ? L("运行记录会显示在这里", "Activity shows up here") : m.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(m.log.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(8)
                }
                if m.busy { ProgressView().controlSize(.small).padding(8).frame(maxWidth: .infinity, alignment: .trailing) }
            }
            .frame(minHeight: 110)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

            Text(L("只读写本机文件：不联网、不碰登录信息和账号设置。恢复和清理前都会自动留一份快照，可以一键撤销。",
                   "Local files only: no network, never touches sign-in or account settings. Every restore and cleanup takes a snapshot first, so you can undo."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 560)
        .task { await m.installIfNeeded(); await m.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await m.refresh() }
        }
        .alert(L("检测到你换了账号", "You switched accounts"), isPresented: $m.showSwitch) {
            Button(L("现在恢复", "Restore now")) { Task { await m.runWithClaudeClosed(["sync", "--all"]) } }
            Button(L("以后再说", "Later"), role: .cancel) {}
        } message: {
            Text(L("当前账号里缺少 \(m.switchMissing) 个之前的对话。\n\n点「现在恢复」会先退出 Claude，恢复完成后自动重新打开（大约 10 秒）。",
                   "This account is missing \(m.switchMissing) of your chats.\n\nRestore quits Claude, restores, and reopens it (about 10 seconds)."))
        }
        .alert(L("恢复对话到当前账号？", "Restore chats?"), isPresented: $m.confirmRestore) {
            Button(L("开始恢复", "Restore")) { Task { await m.runWithClaudeClosed(["sync", "--all"]) } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("会先退出 Claude（正在进行的对话会中断），恢复完成后自动重新打开。\n\n请确认你已经在 Claude 里登录了新账号，并打开过一次 Code 标签页。",
                   "Claude will quit (running chats are interrupted) and reopen when done.\n\nMake sure you're signed in to the new account and have opened the Code tab once."))
        }
        .alert(L("撤销上次操作？", "Undo the last action?"), isPresented: $m.confirmUndo) {
            Button(L("撤销", "Undo")) { Task { await m.runWithClaudeClosed(["rollback"]) } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("会先退出 Claude，撤销上一次「恢复」或「清理」，然后重新打开 Claude。",
                   "Claude will quit, the last restore or cleanup is undone, then Claude reopens."))
        }
        .alert(L("清理 \(m.pruneCount) 个旧对话？", "Clean up \(m.pruneCount) old chats?"), isPresented: $m.confirmPrune) {
            Button(L("清理", "Clean up"), role: .destructive) { Task { await m.runWithClaudeClosed(["prune"]) } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("每个项目只保留最近 \(m.rules.days) 天内最新的 \(m.rules.perProject) 个对话。\n\n将从所有账号的列表里移除：\n\(m.pruneSummary)\n\n会先退出 Claude，完成后自动重新打开。可以点「撤销上次操作」找回。",
                   "Keeps the newest \(m.rules.perProject) chats from the last \(m.rules.days) days in each project.\n\nWill be removed from every account's list:\n\(m.pruneSummary)\n\nClaude quits and reopens. You can Undo afterwards."))
        }
    }

    var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("各账号额度", "Usage by account")).font(.headline)
                Spacer()
                Button {
                    Task { await m.loadUsage() }
                } label: { Label(L("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                    .controlSize(.small)
            }
            if let u = m.usage, !u.accounts.isEmpty {
                ForEach(u.accounts) { a in usageRow(a) }
                Text(L("数据来自 Claude App 在本机记录的用量。只有当前登录的账号会更新，其他账号显示最后一次登录时的情况；恢复时间是估计值。",
                       "Read from the usage the Claude app records on this Mac. Only the signed-in account updates; others show their last known state. Reset times are estimates."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("还没有额度记录。在 Claude 里打开一次 Code 标签页后点刷新。",
                       "No usage recorded yet. Open the Code tab in Claude once, then press Refresh."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .alert(L("给这个账号起个名字", "Name this account"), isPresented: $m.showRename) {
            TextField(L("例如：工作号", "e.g. Work"), text: $m.renameText)
            Button(L("保存", "Save")) { Task { await m.saveRename() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("方便你分清是哪个号。只保存在本机。", "So you can tell accounts apart. Stored on this Mac only."))
        }
    }

    func usageRow(_ a: Usage.Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { m.startRename(a) } label: {
                    HStack(spacing: 4) {
                        Text(a.name).fontWeight(.semibold)
                        Image(systemName: "pencil").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if a.current {
                    Text(L("当前", "current")).font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2))).foregroundStyle(.orange)
                }
                Spacer()
                Text(L("更新于 ", "as of ") + shortTime(a.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            meter(L("5 小时", "5-hour"), a.fiveHour, estimated: a.fiveHourEstimated,
                  note: a.fiveHourResetAt.map { L("最晚 \(shortTime($0)) 恢复", "resets by \(shortTime($0))") }
                      ?? (a.fiveHourEstimated ? L("已过 5 小时，应已恢复", "over 5 h ago — should be reset") : nil))
            meter(L("每周", "Weekly"), a.weekly, estimated: a.weeklyEstimated,
                  note: a.weeklyResetAt.map { L("约 \(shortTime($0)) 重置", "resets ~\(shortTime($0))") }
                      ?? (a.weeklyEstimated ? L("应已重置", "should be reset") : nil))
        }
        .padding(.vertical, 4)
    }

    func meter(_ label: String, _ value: Int?, estimated: Bool, note: String?) -> some View {
        let v = Double(value ?? 0) / 100
        let color: Color = v >= 0.9 ? .red : (v >= 0.6 ? .orange : .green)
        return HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color.opacity(estimated ? 0.45 : 1))
                    .frame(width: max(value == nil ? 0 : 6, 150 * min(max(v, 0), 1)))
            }
            .frame(width: 150, height: 7)
            Text(value.map { "\($0)%" } ?? "—").font(.caption.monospacedDigit())
                .foregroundStyle(estimated ? .secondary : .primary).frame(width: 40, alignment: .trailing)
            if let n = note { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    func shortTime(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: isZH ? "zh_CN" : "en_US")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : (isZH ? "M月d日 HH:mm" : "MMM d HH:mm")
        return f.string(from: d)
    }

    var rulesCard: some View {
        let r = m.rules
        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { r.enabled }, set: { v in var n = r; n.enabled = v; m.saveRules(n) })) {
                Text(L("只保留最近的对话（恢复和清理都按这个规则）", "Keep only recent chats (used by restore and clean up)"))
            }
            .toggleStyle(.switch).controlSize(.small)
            if r.enabled {
                HStack(spacing: 18) {
                    Stepper(value: Binding(get: { r.days }, set: { v in var n = r; n.days = v; m.saveRules(n) }), in: 1...90) {
                        Text(L("最近 \(r.days) 天", "Last \(r.days) days"))
                    }
                    Stepper(value: Binding(get: { r.perProject }, set: { v in var n = r; n.perProject = v; m.saveRules(n) }), in: 1...20) {
                        Text(L("每个项目最多 \(r.perProject) 个", "Up to \(r.perProject) per project"))
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    func statusCard(_ s: Status) -> some View {
        let cur = s.accounts.first { $0.current }
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            row(L("当前账号", "Current account"), (s.currentAccount.map { String($0.prefix(8)) + "…" } ?? L("未知", "unknown"))
                + L("（列表里 \(cur?.sessions ?? 0) 个对话）", "  (\(cur?.sessions ?? 0) chats in sidebar)"))
            row(L("本机登录过的账号", "Accounts on this Mac"), L("\(s.orgCount ?? s.accounts.count) 个", "\(s.orgCount ?? s.accounts.count)"))
            row(L("已备份的对话", "Chats in vault"), L("\(s.vaultSessions) 个", "\(s.vaultSessions)")
                + (s.orphans > 0 ? L("，另有 \(s.orphans) 个旧对话恢复时会重建", ", plus \(s.orphans) older ones to rebuild") : ""))
            row(L("备份占用空间", "Vault size"), ByteCountFormatter.string(fromByteCount: Int64(s.vaultBytes), countStyle: .file))
            GridRow {
                Text(L("自动备份 + 换号提醒", "Auto backup + switch alert")).foregroundStyle(.secondary)
                HStack {
                    Toggle("", isOn: Binding(get: { s.autoBackup }, set: { on in
                        Task { await m.run([on ? "install-agent" : "uninstall-agent"]) }
                    })).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    if let t = s.lastBackupAt, s.autoBackup {
                        Text(L("每分钟一次，上次：", "every minute, last: ")
                             + Date(timeIntervalSince1970: t / 1000).formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v) }
    }
}

@main
struct KeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(L("Claude 换号恢复", "Session Keeper for Claude")) { ContentView() }
            .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Debug/screenshots: CSV_SNAPSHOT=<path> saves the window as PNG after 4 s and quits.
    func applicationDidFinishLaunching(_ n: Notification) {
        guard let path = env["CSV_SNAPSHOT"] else { return }
        let dark = env["CSV_DARK"] != nil
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if let v = NSApp.windows.first?.contentView,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                let img = NSImage(size: v.bounds.size)
                img.lockFocus()
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white).setFill()
                NSRect(origin: .zero, size: v.bounds.size).fill()
                rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
                img.unlockFocus()
                if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
                    try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
