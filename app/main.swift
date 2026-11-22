// Session Keeper for Claude (Claude 多账号管家) — macOS UI.
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
    @Published var page: Page? = Page(rawValue: env["CSV_PAGE"] ?? "") ?? .overview

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


// MARK: - UI

enum Page: String, CaseIterable, Identifiable {
    case overview, usage, chats, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("概览", "Overview")
        case .usage: return L("额度", "Usage")
        case .chats: return L("对话", "Chats")
        case .settings: return L("设置", "Settings")
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .usage: return "gauge.with.dots.needle.50percent"
        case .chats: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }
}

let brand = Color(red: 0.90, green: 0.46, blue: 0.27)

func usageColor(_ v: Int?) -> Color {
    let x = Double(v ?? 0)
    return x >= 90 ? .red : (x >= 60 ? .orange : .green)
}

func shortTime(_ ms: Double) -> String {
    let d = Date(timeIntervalSince1970: ms / 1000)
    let f = DateFormatter()
    f.locale = Locale(identifier: isZH ? "zh_CN" : "en_US")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : (isZH ? "M月d日 HH:mm" : "MMM d, HH:mm")
    return f.string(from: d)
}

/// Rounded card used everywhere.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07)))
    }
}

/// Circular usage gauge.
struct Ring: View {
    let value: Int?
    var estimated = false
    var size: CGFloat = 64
    var line: CGFloat = 7
    var body: some View {
        let v = min(max(Double(value ?? 0) / 100, 0), 1)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
            Circle().trim(from: 0, to: v)
                .stroke(usageColor(value).opacity(estimated ? 0.5 : 1), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(value.map { "\($0)%" } ?? "—")
                .font(.system(size: size * 0.24, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(estimated ? .secondary : .primary)
        }
        .frame(width: size, height: size)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct ContentView: View {
    @StateObject var m = Model()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let e = m.error { errorBanner(e) }
                    switch m.page ?? .overview {
                    case .overview: overviewPage
                    case .usage: usagePage
                    case .chats: chatsPage
                    case .settings: settingsPage
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("")
        }
        .frame(minWidth: 820, minHeight: 600)
        .tint(brand)
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
        .alert(L("给这个账号起个名字", "Name this account"), isPresented: $m.showRename) {
            TextField(L("例如：工作号", "e.g. Work"), text: $m.renameText)
            Button(L("保存", "Save")) { Task { await m.saveRename() } }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("方便你分清是哪个号。只保存在本机。", "So you can tell accounts apart. Stored on this Mac only."))
        }
    }

    // MARK: sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Claude 多账号管家", "Session Keeper")).font(.system(size: 13, weight: .semibold))
                    Text(L("for Claude", "for Claude")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(Page.allCases) { p in sidebarItem(p) }
            }
            .padding(.horizontal, 10)
            Spacer()

            sidebarStatus.padding(12)
        }
    }

    func sidebarItem(_ p: Page) -> some View {
        let selected = (m.page ?? .overview) == p
        return Button { m.page = p } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).font(.system(size: 14, weight: .medium)).frame(width: 20)
                Text(p.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? brand : Color.primary.opacity(0.8))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? brand.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var sidebarStatus: some View {
        let on = m.status?.autoBackup ?? false
        return HStack(spacing: 8) {
            Circle().fill(on ? Color.green : Color.secondary).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(on ? L("自动备份已开启", "Auto backup on") : L("自动备份已关闭", "Auto backup off"))
                    .font(.caption.weight(.medium))
                if on, let t = m.status?.lastBackupAt {
                    Text(L("上次 ", "last ") + shortTime(t)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if m.busy { ProgressView().controlSize(.small) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
    }

    func errorBanner(_ e: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(e).font(.callout).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    // MARK: overview

    var currentUsage: Usage.Account? { m.usage?.accounts.first { $0.current } }

    var overviewPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L("概览", "Overview"),
                       subtitle: L("对话跟着走 · 额度看得见 · 列表不杂乱", "Chats follow you · Usage at a glance · A tidy sidebar"))

            // hero: current account
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("当前账号", "Signed in as")).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                        Text(currentUsage?.name ?? (m.status?.currentAccount.map { String($0.prefix(8)) + "…" } ?? "—"))
                            .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        let n = m.status?.accounts.first { $0.current }?.sessions ?? 0
                        Text(L("侧边栏里有 \(n) 个对话", "\(n) chats in the sidebar"))
                            .font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    if let u = currentUsage {
                        heroRing(L("5 小时", "5-hour"), u.fiveHour, u.fiveHourEstimated)
                        heroRing(L("每周", "Weekly"), u.weekly, u.weeklyEstimated)
                    }
                }
                Button {
                    m.confirmRestore = true
                } label: {
                    Label(L("恢复所有对话到这个账号", "Restore all chats to this account"), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(brand)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(m.busy || m.status == nil)
                Text(L("换号后用。会先退出 Claude，大约 10 秒后自动重新打开。换号时也会自动弹窗提醒。",
                       "Use after switching accounts. Claude quits and reopens in about 10 seconds. You'll also get a prompt automatically."))
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.97, green: 0.60, blue: 0.36), Color(red: 0.84, green: 0.38, blue: 0.24)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )

            // stat tiles
            HStack(spacing: 12) {
                statTile(L("已备份对话", "Chats in vault"), "\(m.status?.vaultSessions ?? 0)", "tray.full")
                statTile(L("账号", "Accounts"), "\(m.status?.orgCount ?? m.usage?.accounts.count ?? 0)", "person.2")
                statTile(L("备份占用", "Vault size"),
                         ByteCountFormatter.string(fromByteCount: Int64(m.status?.vaultBytes ?? 0), countStyle: .file), "internaldrive")
            }

            // activity
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("活动记录", "Activity")).font(.headline)
                        Spacer()
                        if !m.log.isEmpty {
                            Button(L("清空", "Clear")) { m.log = "" }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    Text(m.log.isEmpty ? L("还没有操作记录。恢复、备份、清理的结果会显示在这里。",
                                           "Nothing yet. Results of restore, backup and cleanup show up here.") : m.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(m.log.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                }
            }
        }
    }

    func heroRing(_ label: String, _ v: Int?, _ est: Bool) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 6)
                Circle().trim(from: 0, to: min(max(Double(v ?? 0) / 100, 0), 1))
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(v.map { "\($0)%" } ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .opacity(est ? 0.75 : 1)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.9))
        }
    }

    func statTile(_ title: String, _ value: String, _ icon: String) -> some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(brand)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(brand.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: usage

    var usagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L("额度", "Usage"),
                       subtitle: L("每个账号的 5 小时额度和每周额度", "5-hour and weekly limits for every account")) {
                Button { Task { await m.loadUsage() } } label: {
                    Label(L("刷新", "Refresh"), systemImage: "arrow.clockwise")
                }
            }
            if let u = m.usage, !u.accounts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(u.accounts) { a in usageCard(a) }
                }
                Label(L("数据来自 Claude App 在本机记录的用量，不联网、不读取 token。只有当前登录的账号会更新，其他账号显示最后一次登录时的情况；恢复时间是估计值。",
                        "Read from the usage the Claude app records on this Mac — no network, no tokens. Only the signed-in account updates; others show their last known state. Reset times are estimates."),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Card {
                    Label(L("还没有额度记录。在 Claude 里打开一次 Code 标签页后点刷新。",
                            "No usage recorded yet. Open the Code tab in Claude once, then press Refresh."),
                          systemImage: "gauge.with.dots.needle.0percent")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    func usageCard(_ a: Usage.Account) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Button { m.startRename(a) } label: {
                        HStack(spacing: 5) {
                            Text(a.name).font(.system(size: 15, weight: .semibold))
                            Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L("改名字", "Rename"))
                    if a.current {
                        Text(L("当前", "Current")).font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(brand.opacity(0.15))).foregroundStyle(brand)
                    }
                    Spacer()
                }
                HStack(alignment: .top, spacing: 18) {
                    gauge(L("5 小时", "5-hour"), a.fiveHour, a.fiveHourEstimated,
                          a.fiveHourResetAt.map { L("最晚 \(shortTime($0)) 恢复", "resets by \(shortTime($0))") }
                              ?? (a.fiveHourEstimated ? L("应已恢复", "should be reset") : L("可正常使用", "available")))
                    gauge(L("每周", "Weekly"), a.weekly, a.weeklyEstimated,
                          a.weeklyResetAt.map { L("约 \(shortTime($0)) 重置", "resets ~\(shortTime($0))") }
                              ?? (a.weeklyEstimated ? L("应已重置", "should be reset") : L("重置时间未知", "reset unknown")))
                }
                Divider()
                Text(L("更新于 ", "As of ") + shortTime(a.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func gauge(_ label: String, _ v: Int?, _ est: Bool, _ note: String) -> some View {
        HStack(spacing: 10) {
            Ring(value: v, estimated: est, size: 58, line: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.callout.weight(.medium))
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: chats

    var chatsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L("对话", "Chats"),
                       subtitle: L("备份、恢复和整理 Claude Code 的对话列表", "Back up, restore and tidy your Claude Code chat list"))
            Card(padding: 0) {
                VStack(spacing: 0) {
                    actionRow("arrow.down.circle", L("恢复到当前账号", "Restore to this account"),
                              L("把所有账号的对话加进当前账号的侧边栏。", "Add chats from every account to this account's sidebar."),
                              L("恢复", "Restore"), prominent: true, enabled: m.status != nil) { m.confirmRestore = true }
                    Divider().padding(.leading, 56)
                    actionRow("externaldrive.badge.checkmark", L("立即备份", "Back up now"),
                              L("后台每分钟会自动备份，这里可以手动再来一次。", "Runs every minute in the background; run it now by hand."),
                              L("备份", "Back up"), enabled: true) { Task { await m.run(["backup"]) } }
                    Divider().padding(.leading, 56)
                    actionRow("sparkles", L("清理旧对话", "Clean up old chats"),
                              m.rules.enabled ? L("按下面的保留规则，从所有账号里移除旧对话。", "Remove old chats from every account using the rule below.")
                                              : L("先打开下面的保留规则。", "Turn on the keep rule below first."),
                              L("清理…", "Clean up…"), enabled: m.rules.enabled) { Task { await m.preparePrune() } }
                    Divider().padding(.leading, 56)
                    actionRow("arrow.uturn.backward", L("撤销上次操作", "Undo last action"),
                              L("撤销上一次「恢复」或「清理」。", "Undo the last restore or cleanup."),
                              L("撤销", "Undo"), enabled: m.status?.canUndo ?? false) { m.confirmUndo = true }
                }
            }
            .disabled(m.busy)

            Text(L("保留规则", "Keep rule")).font(.headline).padding(.top, 4)
            Card {
                let r = m.rules
                VStack(alignment: .leading, spacing: 12) {
                    switchRow(L("只保留最近的对话", "Keep only recent chats"),
                              L("恢复时只带这些对话过去，「清理旧对话」也按这个规则。", "Restore brings only these, and Clean up uses the same rule."),
                              Binding(get: { r.enabled }, set: { v in var n = r; n.enabled = v; m.saveRules(n) }))
                    if r.enabled {
                        Divider()
                        HStack(spacing: 24) {
                            Stepper(value: Binding(get: { r.days }, set: { v in var n = r; n.days = v; m.saveRules(n) }), in: 1...90) {
                                Text(L("最近 \(r.days) 天", "Last \(r.days) days"))
                            }
                            Stepper(value: Binding(get: { r.perProject }, set: { v in var n = r; n.perProject = v; m.saveRules(n) }), in: 1...20) {
                                Text(L("每个项目最多 \(r.perProject) 个", "Up to \(r.perProject) per project"))
                            }
                        }
                    }
                }
            }
        }
    }

    func actionRow(_ icon: String, _ title: String, _ detail: String, _ button: String,
                   prominent: Bool = false, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(brand)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(brand.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if prominent {
                Button(button, action: action).buttonStyle(.borderedProminent).disabled(!enabled)
            } else {
                Button(button, action: action).disabled(!enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    func switchRow(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }

    // MARK: settings

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L("设置", "Settings"), subtitle: L("后台任务、备份位置和关于", "Background job, vault and about"))
            Card {
                let s = m.status
                switchRow(L("自动备份 + 换号提醒", "Auto backup + switch alert"),
                          L("每分钟备份一次对话列表和额度记录；发现换号会弹窗提醒。",
                            "Backs up chat lists and usage every minute; prompts you after an account switch."),
                          Binding(get: { s?.autoBackup ?? false }, set: { on in
                              Task { await m.run([on ? "install-agent" : "uninstall-agent"]) }
                          }))
            }
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("保险库", "Vault"))
                        Text(vaultDir.replacingOccurrences(of: home, with: "~"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(m.status?.vaultBytes ?? 0), countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button(L("在访达中打开", "Show in Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: vaultDir)) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Claude 多账号管家", "Session Keeper for Claude")).font(.headline)
                            Text(L("版本 ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("GitHub", destination: URL(string: "https://github.com/weinihu/claude-session-keeper")!)
                    }
                    Divider()
                    Label(L("只读写本机文件：不联网，不碰登录信息、token 和账号设置。恢复和清理之前都会自动拍快照，可以一键撤销。",
                            "Local files only: no network, never touches sign-in, tokens or account settings. Every restore and cleanup takes a snapshot first, so you can undo."),
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("与 Anthropic 无关。Claude 是 Anthropic, PBC 的商标。", "Not affiliated with Anthropic. Claude is a trademark of Anthropic, PBC."))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

@main
struct KeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(L("Claude 多账号管家", "Session Keeper for Claude")) { ContentView() }
            .defaultSize(width: 900, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Debug/screenshots: CSV_SNAPSHOT=<path> saves the window as PNG after 5 s and quits.
    // CSV_PAGE=overview|usage|chats|settings picks the page.
    func applicationDidFinishLaunching(_ n: Notification) {
        guard let path = env["CSV_SNAPSHOT"] else { return }
        let dark = env["CSV_DARK"] != nil
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if let w = NSApp.windows.first, let v = w.contentView?.superview ?? w.contentView,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                let img = NSImage(size: v.bounds.size)
                img.lockFocus()
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
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
