// Session Keeper for Claude (Claude 换号助手) — macOS UI.
// The work is done by claude_sessions.py, which ships inside the app bundle and is installed
// to ~/.claude/session-vault/ on launch (background jobs cannot read scripts inside /Applications
// on external volumes, and the vault copy is what the launchd job runs).
import SwiftUI
import AppKit
import WebKit

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
    /// Next reset as described by the core: weekday + date + time, ISO week, countdown.
    struct Reset: Decodable {
        let at: Double
        let exact: Bool
        let when: String
        let week: String
        let inText: String
        enum CodingKeys: String, CodingKey { case at, exact, when, week, inText = "in" }
    }
    struct Account: Decodable, Identifiable {
        let org: String
        let name: String
        let email: String?
        let named: Bool
        let current: Bool
        let updatedAt: Double
        let fiveHour: Int?
        let fiveHourEstimated: Bool
        let fiveHourResetAt: Double?
        let weekly: Int?
        let weeklyEstimated: Bool
        let weeklyResetAt: Double?
        let fiveHourReset: Reset?
        let weeklyReset: Reset?
        var id: String { org }
        /// Main line: the name you gave it, otherwise the full email.
        var title: String { named ? name : (email ?? name) }
        /// Second line: the email under a custom name, or a hint.
        var subtitle: String {
            if named { return email ?? L("邮箱待识别，登录一次即可", "Email unknown — sign in once") }
            return email == nil ? L("邮箱待识别，登录一次即可", "Email unknown — sign in once")
                                : L("点 ✎ 可以起个名字", "Tap ✎ to add a name")
        }
        var avatarText: String { email == nil && !named ? "?" : title }
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
    @Published var refreshing = false
    @Published var refreshedAt: Date?
    @Published var switchTarget: Usage.Account?
    @Published var showSwitchGuide = false
    @Published var autoRestore = true
    @Published var countdown: Int?            // seconds left before an automatic restore
    @Published var showAdPreview = false
    var countdownTask: Task<Void, Never>?
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
        refreshedAt = Date()
    }

    /// Refresh button: status + usage, with visible feedback.
    func manualRefresh() async {
        guard !refreshing else { return }
        refreshing = true
        await refresh()
        try? await Task.sleep(nanoseconds: 300_000_000)
        refreshing = false
    }

    /// Re-read Claude's records every 30 s while the app is open.
    func autoRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !busy && !refreshing { await refresh() }
        }
    }

    /// Guided, credential-free account switch: copy the email, bring Claude forward, show the steps.
    func switchTo(_ a: Usage.Account) {
        if let e = a.email {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(e, forType: .string)
        }
        switchTarget = a
        showSwitchGuide = true
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
        let ar = cfg["auto_restore"] as? Bool ?? true
        if ar != autoRestore { autoRestore = ar }
    }

    func saveAutoRestore(_ on: Bool) {
        autoRestore = on
        var cfg: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cfg = obj }
        cfg["auto_restore"] = on
        if let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// After a switch: count down, then restore by itself (Claude restarts). Cancelable.
    func startAutoRestore(seconds: Int = 10) {
        countdownTask?.cancel()
        countdown = seconds
        NSApp.activate(ignoringOtherApps: true)
        countdownTask = Task { @MainActor in
            while let left = countdown, left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown = (countdown ?? 1) - 1
            }
            if countdown == 0 {
                countdown = nil
                await runWithClaudeClosed(["sync", "--all"])
            }
        }
    }

    func cancelAutoRestore() {
        countdownTask?.cancel()
        countdown = nil
        append(L("已取消自动恢复。需要时可以在「概览」点「恢复所有对话」。", "Automatic restore canceled. Use Restore all chats on Overview anytime."))
    }

    func restoreNow() {
        countdownTask?.cancel()
        countdown = nil
        Task { await runWithClaudeClosed(["sync", "--all"]) }
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
        guard switchMissing > 0 && !busy else { return }
        if autoRestore { startAutoRestore() } else { showSwitch = true; NSApp.activate(ignoringOtherApps: true) }
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
    case overview, usage, chats, guide, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("概览", "Overview")
        case .usage: return L("额度", "Usage")
        case .chats: return L("对话", "Chats")
        case .guide: return L("使用指南", "Guide")
        case .settings: return L("设置", "Settings")
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .usage: return "gauge.with.dots.needle.50percent"
        case .chats: return "bubble.left.and.bubble.right"
        case .guide: return "book"
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
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06)))
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
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

/// Round avatar with the first letter, colour picked from the name.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    static let palette: [Color] = [
        Color(red: 0.90, green: 0.46, blue: 0.27), Color(red: 0.36, green: 0.55, blue: 0.85),
        Color(red: 0.42, green: 0.68, blue: 0.45), Color(red: 0.62, green: 0.45, blue: 0.80),
        Color(red: 0.85, green: 0.62, blue: 0.25), Color(red: 0.30, green: 0.65, blue: 0.70),
    ]
    var body: some View {
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let c = Avatar.palette[h % Avatar.palette.count]
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [c.opacity(0.85), c], startPoint: .top, endPoint: .bottom)))
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(brand.opacity(0.14))).foregroundStyle(brand)
    }
}

/// Horizontal usage bar.
struct Bar: View {
    let value: Int?
    var estimated = false
    var width: CGFloat = 100
    var body: some View {
        let v = min(max(Double(value ?? 0) / 100, 0), 1)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule().fill(usageColor(value).opacity(estimated ? 0.45 : 0.9))
                .frame(width: value == nil ? 0 : max(5, width * v))
        }
        .frame(width: width, height: 6)
    }
}

/// Sponsor slot — clearly labelled as an ad, opens the site in the browser.
/// Sponsor banner — clearly labelled as an ad. Nothing is loaded until you press Preview.
struct AdCard: View {
    @ObservedObject var m: Model
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.55), Color(red: 0.93, green: 0.47, blue: 0.27)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bolt.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            .shadow(color: brand.opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(L("广告", "Ad")).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(brand))
                    Text("tutu8.shop").font(.system(size: 17, weight: .bold))
                }
                Text(L("作者自营的充值网站", "The author's own top-up shop")).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    chip(L("作者自营", "Run by the author"))
                    chip(L("支持本项目", "Supports this project"))
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button { m.showAdPreview = true } label: {
                    Label(L("预览", "Preview"), systemImage: "eye").frame(width: 96)
                }
                .buttonStyle(.bordered)
                Link(destination: URL(string: "https://tutu8.shop")!) {
                    Label(L("去看看", "Visit"), systemImage: "arrow.up.right").frame(width: 96)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [brand.opacity(0.10), brand.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(brand.opacity(0.25)))
        .sheet(isPresented: $m.showAdPreview) { AdPreview(m: m) }
    }

    func chip(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.medium)).foregroundStyle(brand)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(brand.opacity(0.12)))
    }
}

/// In-app preview of the sponsor site (the only time the app touches the network).
struct AdPreview: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("广告", "Ad")).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(brand))
                Text("tutu8.shop").font(.headline)
                Text(L("预览", "preview")).foregroundStyle(.secondary)
                Spacer()
                Link(L("在浏览器中打开", "Open in browser"), destination: URL(string: "https://tutu8.shop")!)
                Button(L("关闭", "Close")) { m.showAdPreview = false }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            WebPreview(url: URL(string: "https://tutu8.shop")!)
        }
        .frame(width: 900, height: 620)
    }
}

struct WebPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // no cookies kept
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.load(URLRequest(url: url))
        return v
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
        HStack(spacing: 0) {
            // fixed-width sidebar: always visible, can't be dragged away
            sidebar
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let n = m.countdown { autoRestoreBanner(n) }
                    if let e = m.error { errorBanner(e) }
                    switch m.page ?? .overview {
                    case .overview: overviewPage
                    case .usage: usagePage
                    case .chats: chatsPage
                    case .guide: guidePage
                    case .settings: settingsPage
                    }
                }
                .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)          // centered column
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 940, minHeight: 620)
        .tint(brand)
        .task { await m.installIfNeeded(); await m.refresh(); await m.autoRefreshLoop() }
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
        .alert(L("切换到 \(m.switchTarget?.email ?? m.switchTarget?.title ?? "")", "Switch to \(m.switchTarget?.email ?? m.switchTarget?.title ?? "")"),
               isPresented: $m.showSwitchGuide) {
            Button(L("打开 Claude", "Open Claude")) { m.openClaude() }
            Button(L("好的", "OK"), role: .cancel) {}
        } message: {
            Text(L("邮箱已复制到剪贴板。\n\n1. 在 Claude 左下角点头像 → 退出登录\n2. 用这个邮箱登录（粘贴即可）\n3. 打开一次 Code 标签页\n\n本工具会在一分钟内自动弹窗，帮你把对话恢复到这个号。\n\n为了你的账号安全，本工具不保存、不调换任何登录凭证。",
                   "The email is on your clipboard.\n\n1. In Claude, click your avatar (bottom left) → Log out\n2. Sign in with this email (just paste it)\n3. Open the Code tab once\n\nWithin a minute this app will offer to restore your chats to that account.\n\nFor your safety, this app never stores or swaps sign-in credentials."))
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
                    Text(L("Claude 换号助手", "Session Keeper")).font(.system(size: 13, weight: .semibold))
                    Text(L("对话不丢 · 额度清楚", "for Claude")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.top, 44).padding(.bottom, 14)

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

    func autoRestoreBanner(_ n: Int) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.35), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(n) / 10).stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(n)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("检测到你换了账号", "You switched accounts")).font(.headline).foregroundStyle(.white)
                Text(L("\(n) 秒后自动把 \(m.switchMissing) 个对话恢复到这个号，Claude 会重启一下。",
                       "Restoring \(m.switchMissing) chats to this account in \(n) s — Claude will restart."))
                    .font(.callout).foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            Button(L("取消", "Cancel")) { m.cancelAutoRestore() }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().stroke(Color.white.opacity(0.6)))
            Button(L("立即恢复", "Restore now")) { m.restoreNow() }
                .buttonStyle(.plain).foregroundStyle(brand).fontWeight(.semibold)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Color.white))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.52, blue: 0.31), Color(red: 0.82, green: 0.38, blue: 0.24)],
                                 startPoint: .leading, endPoint: .trailing)))
        .shadow(color: brand.opacity(0.25), radius: 10, y: 4)
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
                       subtitle: L("换号不丢对话，每个号的额度一眼看清", "Switch accounts without losing chats — see every account's usage at a glance")) {
                refreshControl
            }

            // current account
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 14) {
                        Avatar(name: currentUsage?.avatarText ?? "?", size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(currentUsage?.title ?? (m.status?.currentAccount.map { String($0.prefix(8)) + "…" } ?? "—"))
                                    .font(.system(size: 18, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                Tag(text: L("当前登录", "Signed in"))
                            }
                            Text(currentUsage.map { $0.named ? ($0.email ?? $0.subtitle) : $0.subtitle } ?? L("登录后会自动记录邮箱", "Email is recorded after you sign in"))
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if let u = currentUsage {
                            miniGauge(L("5 小时", "5-hour"), u.fiveHour, u.fiveHourEstimated)
                            miniGauge(L("每周", "Weekly"), u.weekly, u.weeklyEstimated)
                        }
                    }
                    if let u = currentUsage {
                        VStack(alignment: .leading, spacing: 6) {
                            resetLine(L("5 小时", "5-hour"), u.fiveHourReset,
                                      u.fiveHour == nil ? L("暂无数据", "no data") : L("现在可用", "available now"))
                            resetLine(L("每周", "Weekly"), u.weeklyReset, L("重置时间未知", "reset unknown"))
                        }
                    }
                    Divider()
                    HStack(spacing: 12) {
                        let n = m.status?.accounts.first { $0.current }?.sessions ?? 0
                        Label(L("侧边栏里有 \(n) 个对话", "\(n) chats in the sidebar"), systemImage: "bubble.left.and.bubble.right")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button { m.confirmRestore = true } label: {
                            Label(L("恢复所有对话", "Restore all chats"), systemImage: "arrow.down.circle")
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(m.busy || m.status == nil)
                    }
                }
            }

            // all accounts at a glance
            HStack {
                Text(L("账号一览", "All accounts")).font(.headline)
                Spacer()
                Button(L("查看额度详情", "Usage details")) { m.page = .usage }.buttonStyle(.borderless)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    let list = m.usage?.accounts ?? []
                    if list.isEmpty {
                        Text(L("还没有额度记录。在 Claude 里打开一次 Code 标签页后点刷新。", "No usage yet. Open the Code tab in Claude once."))
                            .font(.callout).foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().padding(.leading, 58) }
                        HStack(spacing: 12) {
                            Avatar(name: a.avatarText, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(a.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                    if a.current { Tag(text: L("当前", "Current")) }
                                }
                                Text(a.named ? (a.email ?? a.subtitle)
                                     : (a.email == nil ? a.subtitle
                                        : (a.weeklyReset.map { L("每周 \($0.when) 重置", "weekly resets \($0.when)") } ?? L("每周重置时间未知", "weekly reset unknown"))))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            compactBar(L("5h", "5h"), a.fiveHour, a.fiveHourEstimated)
                            compactBar(L("周", "Wk"), a.weekly, a.weeklyEstimated)
                            Group {
                                if a.current {
                                    Color.clear
                                } else {
                                    Button(L("切换", "Switch")) { m.switchTo(a) }.controlSize(.small)
                                }
                            }
                            .frame(width: 52)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }

            // stats
            HStack(spacing: 12) {
                statTile(L("已备份对话", "Chats in vault"), "\(m.status?.vaultSessions ?? 0)", "tray.full")
                statTile(L("账号", "Accounts"), "\(m.usage?.accounts.count ?? m.status?.orgCount ?? 0)", "person.2")
                statTile(L("备份占用", "Vault size"),
                         ByteCountFormatter.string(fromByteCount: Int64(m.status?.vaultBytes ?? 0), countStyle: .file), "internaldrive")
            }

            AdCard(m: m)

            if !m.log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("活动记录", "Activity")).font(.headline)
                            Spacer()
                            Button(L("清空", "Clear")) { m.log = "" }.buttonStyle(.borderless).font(.caption)
                        }
                        Text(m.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    func miniGauge(_ label: String, _ v: Int?, _ est: Bool) -> some View {
        VStack(spacing: 4) {
            Ring(value: v, estimated: est, size: 54, line: 5)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    func resetLine(_ label: String, _ r: Usage.Reset?, _ idle: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(brand)
            Text(label).font(.caption.weight(.semibold))
            Text(r.map { "\($0.when) · \($0.week) · \($0.inText)" + ($0.exact ? "" : L("（估计）", " (est.)")) } ?? idle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    func compactBar(_ label: String, _ v: Int?, _ est: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            Bar(value: v, estimated: est, width: 70)
            Text(v.map { "\($0)%" } ?? "—").font(.caption.monospacedDigit())
                .foregroundStyle(est ? .secondary : .primary).frame(width: 36, alignment: .trailing)
        }
    }

    func statTile(_ title: String, _ value: String, _ icon: String) -> some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(brand)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(brand.opacity(0.10)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: usage

    var usagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L("额度", "Usage"),
                       subtitle: L("每个账号的 5 小时额度和每周额度，以及下一次重置时间", "5-hour and weekly limits for every account, and when each resets")) {
                refreshControl
            }
            if let u = m.usage, !u.accounts.isEmpty {
                VStack(spacing: 12) {
                    ForEach(u.accounts) { a in usageCard(a) }
                }
                Label(L("数据来自 Claude 在本机的记录，不联网、不读取 token：用量来自 Claude App；邮箱和精确的重置时间来自 Claude Code 的对话记录。标「精确」的是 Claude 自己给出的时间，标「估计」的是推算的。只有当前登录的账号会更新用量。",
                        "Everything comes from Claude's own records on this Mac — no network, no tokens. Usage comes from the Claude app; emails and exact reset times come from Claude Code's transcripts. \"Exact\" times were reported by Claude; \"est.\" ones are inferred. Only the signed-in account updates."),
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
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Avatar(name: a.avatarText, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Button { m.startRename(a) } label: {
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain).help(L("起个名字", "Rename"))
                            if a.current { Tag(text: L("当前登录", "Signed in")) }
                        }
                        Text(a.subtitle).font(.caption).foregroundStyle(a.named && a.email != nil ? .secondary : .tertiary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if !a.current {
                            Button { m.switchTo(a) } label: {
                                Label(L("切换到这个号", "Switch to this"), systemImage: "arrow.left.arrow.right")
                            }
                            .controlSize(.small)
                        }
                        Text(a.updatedAt > 0 ? L("Claude 记录于 ", "recorded ") + shortTime(a.updatedAt) : L("暂无用量记录", "no usage yet"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    limitBlock(L("5 小时额度", "5-hour limit"), a.fiveHour, a.fiveHourEstimated, a.fiveHourReset,
                               resetWord: L("下次恢复", "Resets"),
                               idle: a.fiveHour == nil ? L("暂无数据", "no data")
                                   : L("现在可用 · 开始使用后 5 小时内恢复", "Available · resets 5 h after you start"))
                    limitBlock(L("每周额度", "Weekly limit"), a.weekly, a.weeklyEstimated, a.weeklyReset,
                               resetWord: L("下次重置", "Resets"),
                               idle: a.weekly == nil ? L("暂无数据", "no data")
                                   : L("重置时间未知 · 碰到一次每周限额后就能算准", "Reset time unknown until the weekly limit is hit once"))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(a.current ? brand.opacity(0.45) : .clear, lineWidth: 1.5))
    }

    func limitBlock(_ title: String, _ v: Int?, _ est: Bool, _ r: Usage.Reset?, resetWord: String, idle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(v.map { "\($0)%" } ?? "—")
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(v == nil ? .secondary : (est ? .secondary : usageColor(v)))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(usageColor(v).opacity(est ? 0.45 : 0.9))
                        .frame(width: v == nil ? 0 : max(6, g.size.width * min(max(Double(v ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 7)
            if let r = r {
                HStack(spacing: 6) {
                    Text("\(resetWord) \(r.when)").font(.caption.weight(.medium))
                    Text(r.exact ? L("精确", "exact") : L("估计", "est."))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(r.exact ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15)))
                        .foregroundStyle(r.exact ? Color.green : Color.secondary)
                }
                Text("\(r.week) · \(r.inText)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(idle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
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

    /// Refresh with feedback: spinner while working, then when Claude last recorded usage.
    var refreshControl: some View {
        HStack(spacing: 10) {
            if let t = m.refreshedAt, !m.refreshing {
                Text(L("已刷新 ", "Refreshed ") + t.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await m.manualRefresh() } } label: {
                HStack(spacing: 5) {
                    if m.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    Text(L("刷新", "Refresh"))
                }
            }
            .disabled(m.refreshing)
        }
    }

    // MARK: guide

    var guidePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L("使用指南", "Guide"), subtitle: L("三分钟看懂怎么用", "Everything in three minutes"))
            guideCard("1", L("平时：什么都不用做", "Day to day: nothing to do"), [
                L("后台每分钟自动备份一次对话列表和额度记录，只在有变化时才写入。", "A background job backs up chat lists and usage every minute, writing only when something changed."),
                L("「额度」页每 30 秒自动刷新；想马上看最新的，点右上角「刷新」。", "The Usage page refreshes every 30 s; press Refresh for the latest."),
            ])
            guideCard("2", L("换号：三步", "Switching accounts: three steps"), [
                L("在「额度」或「概览」里，对要换的号点「切换」，邮箱会自动复制。", "In Usage or Overview, click Switch on the account you want — its email is copied for you."),
                L("在 Claude 左下角点头像 → 退出登录，再用这个邮箱登录，打开一次 Code 标签页。", "In Claude: avatar (bottom left) → Log out, sign in with that email, open the Code tab once."),
                L("一分钟内会自动倒数 10 秒，把之前的对话恢复到这个号；想停下就点「取消」。", "Within a minute your chats are restored automatically after a 10-second countdown — Cancel stops it."),
            ])
            guideCard("3", L("额度怎么看", "Reading the usage"), [
                L("百分比来自 Claude App 自己的记录。Claude 通常在你使用或打开它的「用量」面板时更新记录，所以没登录的号显示的是上次登录时的情况。",
                  "Percentages come from the Claude app's own record, which Claude updates while you use it or open its Usage panel — accounts you aren't signed in to show their last known state."),
                L("「精确」的重置时间是 Claude 自己报出来的（碰到限额时）；每周额度每周固定在同一时间重置，见过一次以后每周都准。「估计」的是推算的。",
                  "\"Exact\" reset times were reported by Claude when a limit was hit; the weekly reset repeats at the same time every week. \"Est.\" ones are inferred."),
            ])
            guideCard("4", L("规则和安全", "Rules and safety"), [
                L("只读写本机文件，不联网，不读取、不保存、不调换任何登录凭证或 token。换号永远由你自己在 Claude 里登录完成。",
                  "Local files only: no network, and it never reads, stores or swaps sign-in credentials or tokens. You always sign in yourself in Claude."),
                L("不提供「快到限额就自动换号」这类功能：用多个账号绕开单个账号的用量限制，可能违反 Anthropic 的使用条款，请以条款为准。",
                  "No \"auto-switch before the limit\": using several accounts to get around one account's usage limits may break Anthropic's terms — check them for your case."),
                L("每次恢复和清理之前都会拍快照，在「对话」页点「撤销上次操作」就能回到原样。", "Every restore and cleanup takes a snapshot first; Undo on the Chats page puts things back."),
            ])
        }
    }

    func guideCard(_ n: String, _ title: String, _ items: [String]) -> some View {
        Card(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                Text(n).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(brand))
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    ForEach(items, id: \.self) { t in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 7)
                            Text(t).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: settings

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: L("设置", "Settings"), subtitle: L("后台任务、备份位置和关于", "Background job, vault and about"))
            Card {
                let s = m.status
                VStack(alignment: .leading, spacing: 12) {
                switchRow(L("换号后自动恢复对话", "Restore chats automatically after a switch"),
                          L("检测到换号后倒数 10 秒自动恢复（Claude 会重启），期间可以取消。关掉后改为弹窗询问。",
                            "After a switch, restores on its own after a 10-second countdown (Claude restarts); you can cancel. Off: ask first."),
                          Binding(get: { m.autoRestore }, set: { m.saveAutoRestore($0) }))
                Divider()
                switchRow(L("自动备份 + 换号提醒", "Auto backup + switch alert"),
                          L("每分钟备份一次对话列表和额度记录；发现换号会弹窗提醒。",
                            "Backs up chat lists and usage every minute; prompts you after an account switch."),
                          Binding(get: { s?.autoBackup ?? false }, set: { on in
                              Task { await m.run([on ? "install-agent" : "uninstall-agent"]) }
                          }))
                }
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
                            Text(L("Claude 换号助手", "Session Keeper for Claude")).font(.headline)
                            Text(L("版本 ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link("GitHub", destination: URL(string: "https://github.com/weinihu/claude-session-keeper")!)
                    }
                    Divider()
                    Label(L("只读写本机文件，不碰登录信息、token 和账号设置；除了你主动打开的广告预览，本工具不联网。恢复和清理之前都会自动拍快照，可以一键撤销。",
                            "Local files only: no network, never touches sign-in, tokens or account settings. Every restore and cleanup takes a snapshot first, so you can undo."),
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("与 Anthropic 无关。Claude 是 Anthropic, PBC 的商标。", "Not affiliated with Anthropic. Claude is a trademark of Anthropic, PBC."))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            AdCard(m: m)
        }
    }
}

@main
struct KeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(L("Claude 换号助手", "Session Keeper for Claude")) { ContentView() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 940, height: 660)
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
