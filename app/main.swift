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
        /// Main line: always the email (falls back to the name only while the email is unknown).
        var title: String { email ?? name }
        /// Your note for this account, if any.
        var note: String? { named ? name : nil }
        /// Hint shown when there's no note.
        var subtitle: String {
            email == nil ? L("邮箱待识别，登录一次即可", "Email unknown — sign in once")
                         : L("点「备注」可以加个名字", "Click Note to add a name")
        }
        var avatarText: String { email ?? (named ? name : "?") }
    }
    let accounts: [Account]
    let sourceFound: Bool
    /// Opt-in exact mode: official numbers for the account Claude Code is signed in to.
    struct Exact: Decodable {
        let enabled: Bool
        let ok: Bool?
        let error: String?
        let detail: String?
        let email: String?
        let lastOk: Double?
        let autoOffAt: Double?
        let lockedIp: String?
        let count: Int?
    }
    let exact: Exact?
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
    @Published var notifySwitch = true
    @Published var notifyQuota = true
    @Published var quotaAlertAt = 90
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
        if let sl = Bundle.main.path(forResource: "statusline_capture", ofType: "py") {
            let dst = vaultDir + "/statusline_capture.py"
            if !fm.contentsEqual(atPath: sl, andPath: dst) {
                try? fm.removeItem(atPath: dst)
                try? fm.copyItem(atPath: sl, toPath: dst)
            }
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

    func setExactMode(_ on: Bool) async {
        busy = true; defer { busy = false }
        var args = ["live", "--enable", on ? "on" : "off", "--json"]
        if on { args.append("--force") }          // read once right away (first time: Keychain asks)
        _ = await python(args)
        await loadUsage()
    }

    func startRename(_ a: Usage.Account) {
        renameOrg = a.org
        renameText = a.named ? a.name : ""
        showRename = true
    }

    func saveRename() async {
        guard let org = renameOrg else { return }
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await python(["usage", "--rename", org, text])     // empty = delete the note
        showRename = false
        await loadUsage()
    }

    func deleteNote() async {
        renameText = ""
        await saveRename()
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
        let ns = cfg["notify_switch"] as? Bool ?? true
        if ns != notifySwitch { notifySwitch = ns }
        let nq = cfg["notify_quota"] as? Bool ?? true
        if nq != notifyQuota { notifyQuota = nq }
        let qa = cfg["quota_alert_at"] as? Int ?? 90
        if qa != quotaAlertAt { quotaAlertAt = qa }
    }

    /// Write one key into the vault's config.json (the background job reads it every minute).
    func saveSetting(_ key: String, _ value: Any) {
        var cfg: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cfg = obj }
        cfg[key] = value
        if let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: configPath))
        }
        loadRules()
    }

    /// Send a sample notification so you can see what the reminders look like.
    func testReminder() async {
        _ = await python(["notify-test"])
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

// MARK: - Design tokens
// One spacing scale, one type scale, nested radii that stay concentric, one ambient shadow.

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let page: CGFloat = 32
}

enum Radius {
    static let card: CGFloat = 16                 // outer cards
    static let inset: CGFloat = 8                 // card edge → panel inside it
    static let panel: CGFloat = card - inset      // 8: inner corner = outer corner − gap
    static let small: CGFloat = 12                // banners and boxes that aren't nested
    static let control: CGFloat = 8               // buttons, icon tiles, sidebar rows
}

enum TypeScale {
    static let page = Font.system(size: 26, weight: .bold)
    static let pageSub = Font.system(size: 13)
    static let section = Font.system(size: 15, weight: .semibold)
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
}

/// Blue-grey ambient tone for shadows: softer and more see-through than black.
let shadowTone = Color(red: 0.22, green: 0.29, blue: 0.42)

extension View {
    func ambientShadow() -> some View {
        self.shadow(color: shadowTone.opacity(0.09), radius: 24, x: 0, y: 10)
            .shadow(color: shadowTone.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

/// Filled buttons that keep their colour when the window isn't focused:
/// the primary action is always the one brand-coloured button in its group.
struct FilledButton: ButtonStyle {
    var primary = true
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        FilledButtonBody(configuration: configuration, primary: primary, large: large)
    }
}

private struct FilledButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let primary: Bool
    let large: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)     // button labels never wrap
            .font(.system(size: large ? 13.5 : 12.5, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, large ? Space.l : Space.m)
            .padding(.vertical, large ? Space.s + 1 : 5)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(primary ? AnyShapeStyle(LinearGradient(colors: [brand.opacity(0.92), brand], startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(0.06))))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(primary ? Color.clear : Color.primary.opacity(0.08)))
            .shadow(color: primary && enabled ? brand.opacity(0.28) : .clear, radius: 6, y: 2)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}

extension ButtonStyle where Self == FilledButton {
    static var primary: FilledButton { FilledButton() }
    static var primaryLarge: FilledButton { FilledButton(primary: true, large: true) }
    static var secondary: FilledButton { FilledButton(primary: false) }
}

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
    var padding: CGFloat = Space.l
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Color.primary.opacity(0.06)))
            .ambientShadow()
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
        HStack(spacing: Space.xxl) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.55), Color(red: 0.93, green: 0.47, blue: 0.27)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bolt.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            .shadow(color: brand.opacity(0.35), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Text(L("广告", "Ad")).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(brand))
                    Text("tutu8.shop").font(.system(size: 17, weight: .bold))
                }
                Text(L("AI 会员代充值 —— 作者自营的充值网站", "AI subscription top-ups — the author's own shop"))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: Space.s) {
                    chip(L("AI 会员代充", "AI subscription top-up"))
                    chip(L("作者自营", "Run by the author"))
                    chip(L("非 Anthropic 官方", "Not affiliated with Anthropic"))
                }
            }
            Spacer()
            VStack(spacing: Space.s) {
                Button { m.showAdPreview = true } label: {
                    Label(L("预览", "Preview"), systemImage: "eye").frame(width: 96)
                }
                .buttonStyle(.secondary)
                Link(destination: URL(string: "https://tutu8.shop")!) {
                    Label(L("去看看", "Visit"), systemImage: "arrow.up.right").frame(width: 96)
                }
                .buttonStyle(.primary)
            }
        }
        .padding(Space.xl)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(LinearGradient(colors: [brand.opacity(0.10), brand.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(brand.opacity(0.25)))
        .sheet(isPresented: $m.showAdPreview) { AdPreview(m: m) }
    }

    func chip(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.medium)).foregroundStyle(brand)
            .padding(.horizontal, Space.s).padding(.vertical, 3)
            .background(Capsule().fill(brand.opacity(0.12)))
    }
}

/// In-app preview of the sponsor site (the only time the app touches the network).
struct AdPreview: View {
    @ObservedObject var m: Model
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Text(L("广告", "Ad")).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(brand))
                Text("tutu8.shop").font(TypeScale.section)
                Text(L("AI 会员代充 · 预览", "AI top-ups · preview")).foregroundStyle(.secondary)
                Spacer()
                Link(L("在浏览器中打开", "Open in browser"), destination: URL(string: "https://tutu8.shop")!)
                Button(L("关闭", "Close")) { m.showAdPreview = false }.keyboardShortcut(.cancelAction)
            }
            .padding(Space.m)
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
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(TypeScale.page)
                Text(subtitle).font(TypeScale.pageSub).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: Space.xxl) {
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
                .padding(.horizontal, Space.page).padding(.top, 40).padding(.bottom, Space.page)
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
        .sheet(isPresented: $m.showRename) { noteSheet }
    }

    var noteSheet: some View {
        let target = m.usage?.accounts.first { $0.org == m.renameOrg }
        return VStack(alignment: .leading, spacing: Space.m) {
            Text(L("账号备注", "Account note")).font(.title3.bold())
            Text(target?.email ?? "").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            TextField(L("例如：工作号（留空 = 删除备注）", "e.g. Work (leave empty to delete)"), text: $m.renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await m.saveRename() } }
            Text(L("只保存在本机。清空后保存，或点「删除备注」，就会删掉。", "Stored on this Mac only. Save it empty, or click Delete note, to remove it."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if target?.named == true {
                    Button(role: .destructive) { Task { await m.deleteNote() } } label: { Text(L("删除备注", "Delete note")) }
                }
                Spacer()
                Button(L("取消", "Cancel")) { m.showRename = false }.keyboardShortcut(.cancelAction)
                Button(L("保存", "Save")) { Task { await m.saveRename() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.primary)
            }
        }
        .padding(Space.xxl)
        .frame(width: 420)
    }

    func noteChip(_ a: Usage.Account) -> some View {
        Button { m.startRename(a) } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: a.note == nil ? "plus" : "tag").font(.system(size: 9, weight: .semibold))
                Text(a.note ?? L("备注", "Note")).font(.caption.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, Space.s).padding(.vertical, 2)
            .background(Capsule().fill(a.note == nil ? Color.secondary.opacity(0.10) : brand.opacity(0.12)))
            .foregroundStyle(a.note == nil ? Color.secondary : brand)
        }
        .buttonStyle(.plain)
        .help(a.note == nil ? L("添加备注", "Add a note") : L("修改或删除备注", "Edit or delete the note"))
    }

    // MARK: sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Claude 换号助手", "Session Keeper")).font(.system(size: 13, weight: .semibold))
                    Text(L("对话不丢 · 额度清楚", "for Claude")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Space.l).padding(.top, 44).padding(.bottom, Space.l)

            VStack(spacing: 2) {
                ForEach(Page.allCases) { p in sidebarItem(p) }
            }
            .padding(.horizontal, Space.m)
            Spacer()

            sidebarStatus.padding(Space.m)
        }
    }

    func sidebarItem(_ p: Page) -> some View {
        let selected = (m.page ?? .overview) == p
        return Button { m.page = p } label: {
            HStack(spacing: Space.m) {
                Image(systemName: p.icon).font(.system(size: 14, weight: .medium)).frame(width: 20)
                Text(p.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? brand : Color.primary.opacity(0.8))
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(selected ? brand.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var sidebarStatus: some View {
        let on = m.status?.autoBackup ?? false
        return VStack(alignment: .leading, spacing: Space.m) {
            if let u = currentUsage {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(L("当前账号", "Signed in")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(u.title).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle).help(u.title)
                    HStack(spacing: Space.s) {
                        Text("5h").font(.caption2).foregroundStyle(.secondary)
                        Bar(value: u.fiveHour, estimated: u.fiveHourEstimated, width: 44)
                        Text(L("周", "wk")).font(.caption2).foregroundStyle(.secondary)
                        Bar(value: u.weekly, estimated: u.weeklyEstimated, width: 44)
                    }
                }
                Divider()
            }
            HStack(spacing: Space.s) {
                Circle().fill(on ? Color.green : Color.secondary).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(on ? L("自动备份 · 换号提醒开启", "Backup & reminders on") : L("后台任务已关闭", "Background job off"))
                        .font(.caption.weight(.medium))
                    if on, let t = m.status?.lastBackupAt {
                        Text(L("上次 ", "last ") + shortTime(t)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    func autoRestoreBanner(_ n: Int) -> some View {
        HStack(spacing: Space.m) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.35), lineWidth: 3)
                Circle().trim(from: 0, to: CGFloat(n) / 10).stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(n)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("检测到你换了账号", "You switched accounts")).font(TypeScale.section).foregroundStyle(.white)
                Text(L("\(n) 秒后自动把 \(m.switchMissing) 个对话恢复到这个号，Claude 会重启一下。",
                       "Restoring \(m.switchMissing) chats to this account in \(n) s — Claude will restart."))
                    .font(.callout).foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            Button(L("取消", "Cancel")) { m.cancelAutoRestore() }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, Space.m).padding(.vertical, 6)
                .background(Capsule().stroke(Color.white.opacity(0.6)))
            Button(L("立即恢复", "Restore now")) { m.restoreNow() }
                .buttonStyle(.plain).foregroundStyle(brand).fontWeight(.semibold)
                .padding(.horizontal, Space.l).padding(.vertical, 6)
                .background(Capsule().fill(Color.white))
        }
        .padding(Space.l)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.52, blue: 0.31), Color(red: 0.82, green: 0.38, blue: 0.24)],
                                 startPoint: .leading, endPoint: .trailing)))
        .shadow(color: brand.opacity(0.25), radius: 10, y: 4)
    }

    func errorBanner(_ e: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(e).font(.callout).textSelection(.enabled)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    // MARK: overview

    var currentUsage: Usage.Account? { m.usage?.accounts.first { $0.current } }

    var overviewPage: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            PageHeader(title: L("概览", "Overview"),
                       subtitle: L("换号不丢对话，每个号的额度一眼看清", "Switch accounts without losing chats — see every account's usage at a glance")) {
                refreshControl
            }
            heroCard
            accountsList
            AdCard(m: m)
            if !m.log.isEmpty { activityCard }
        }
    }

    /// The signed-in account: who, how much is left, when it resets, and the restore button.
    var heroCard: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Space.l) {
                    Avatar(name: currentUsage?.avatarText ?? "?", size: 52)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(L("当前登录", "Signed in")).font(.caption.weight(.semibold)).foregroundStyle(brand)
                        Text(currentUsage?.title ?? (m.status?.currentAccount.map { String($0.prefix(8)) + "…" } ?? "—"))
                            .font(.system(size: 19, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                            .textSelection(.enabled)
                        if let u = currentUsage {
                            noteChip(u)
                        } else {
                            Text(L("登录后会自动记录邮箱", "Email is recorded after you sign in"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 12)
                    if let u = currentUsage {
                        miniGauge(L("5 小时", "5-hour"), u.fiveHour, u.fiveHourEstimated)
                        miniGauge(L("每周", "Weekly"), u.weekly, u.weeklyEstimated)
                    }
                }
                .padding(Space.xl)
                if let u = currentUsage {
                    VStack(alignment: .leading, spacing: Space.s) {
                        resetLine(L("5 小时", "5-hour"), u.fiveHourReset,
                                  u.fiveHour == nil ? L("暂无数据", "no data") : L("现在可用", "available now"))
                        resetLine(L("每周", "Weekly"), u.weeklyReset, L("重置时间未知", "reset unknown"))
                    }
                    .padding(.horizontal, Space.xl).padding(.bottom, Space.l)
                }
                Divider()
                HStack(spacing: Space.xxl) {
                    let n = m.status?.accounts.first { $0.current }?.sessions ?? 0
                    footStat("bubble.left.and.bubble.right", "\(n)", L("侧边栏对话", "in sidebar"))
                    footStat("tray.full", "\(m.status?.vaultSessions ?? 0)", L("已备份", "backed up"))
                    footStat("internaldrive", ByteCountFormatter.string(fromByteCount: Int64(m.status?.vaultBytes ?? 0), countStyle: .file),
                             L("占用", "on disk"))
                    Spacer()
                    Button { m.confirmRestore = true } label: {
                        Label(L("恢复所有对话", "Restore all chats"), systemImage: "arrow.down.circle").padding(.horizontal, 4)
                    }
                    .buttonStyle(.primaryLarge)
                    .disabled(m.busy || m.status == nil)
                }
                .padding(.horizontal, Space.xl).padding(.vertical, Space.l)
                .background(Color.primary.opacity(0.025))
            }
        }
    }

    func footStat(_ icon: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).font(.caption).foregroundStyle(brand)
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Every account on one card: full email, note, both limits, and Switch.
    var accountsList: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text(L("所有账号", "All accounts")).font(TypeScale.section)
                Spacer()
                Button(L("额度详情 →", "Usage details →")) { m.page = .usage }.buttonStyle(.borderless)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    let list = m.usage?.accounts ?? []
                    if list.isEmpty {
                        Text(L("还没有额度记录。在 Claude 里打开一次 Code 标签页后点刷新。", "No usage yet. Open the Code tab in Claude once."))
                            .font(.callout).foregroundStyle(.secondary).padding(Space.l)
                    } else {
                        HStack(spacing: Space.m) {
                            Text(L("账号", "Account")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 42)
                            Text(L("5 小时", "5-hour")).frame(width: 104, alignment: .leading)
                            Text(L("每周", "Weekly")).frame(width: 104, alignment: .leading)
                            Color.clear.frame(width: 72, height: 1)
                        }
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.l).padding(.top, Space.m).padding(.bottom, 6)
                        Divider()
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider().padding(.leading, 58) }
                        accountRow(a)
                    }
                }
            }
        }
    }

    func accountRow(_ a: Usage.Account) -> some View {
        HStack(spacing: Space.m) {
            Avatar(name: a.avatarText, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s) {
                    Text(a.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                    if a.current { Tag(text: L("当前", "Current")) }
                }
                HStack(spacing: Space.xs) {
                    if let n = a.note {
                        Text(n).font(.caption.weight(.medium)).foregroundStyle(brand)
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(a.email == nil ? a.subtitle
                         : (a.weeklyReset.map { L("每周 \($0.when) 重置", "weekly resets \($0.when)") } ?? L("每周重置时间未知", "weekly reset unknown")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            compactBar(a.fiveHour, a.fiveHourEstimated)
            compactBar(a.weekly, a.weeklyEstimated)
            Group {
                if a.current {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(brand)
                } else {
                    Button(L("切换", "Switch")) { m.switchTo(a) }.buttonStyle(.secondary)
                }
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .background(a.current ? brand.opacity(0.05) : .clear)
    }

    var activityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text(L("活动记录", "Activity")).font(TypeScale.section)
                    Spacer()
                    Button(L("清空", "Clear")) { m.log = "" }.buttonStyle(.borderless).font(.caption)
                }
                Text(m.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func miniGauge(_ label: String, _ v: Int?, _ est: Bool) -> some View {
        VStack(spacing: Space.xs) {
            Ring(value: v, estimated: est, size: 54, line: 5)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    func resetLine(_ label: String, _ r: Usage.Reset?, _ idle: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(brand)
            Text(label).font(.caption.weight(.semibold)).frame(width: isZH ? 40 : 50, alignment: .leading)
            Text(r.map { "\($0.when) · \($0.week) · \($0.inText)" + ($0.exact ? "" : L("（估计）", " (est.)")) } ?? idle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    func compactBar(_ v: Int?, _ est: Bool) -> some View {
        HStack(spacing: Space.s) {
            Bar(value: v, estimated: est, width: 58)
            Text(v.map { "\($0)%" } ?? "—").font(.caption.monospacedDigit())
                .foregroundStyle(est || v == nil ? .secondary : .primary).frame(width: 36, alignment: .leading)
        }
        .frame(width: 104, alignment: .leading)
    }

    // MARK: usage

    var usagePage: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            PageHeader(title: L("额度", "Usage"),
                       subtitle: L("每个账号的 5 小时额度和每周额度，以及下一次重置时间", "5-hour and weekly limits for every account, and when each resets")) {
                refreshControl
            }
            if let u = m.usage, !u.accounts.isEmpty {
                if let ex = u.exact, ex.enabled { exactBanner(ex, u) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Space.l, alignment: .top)],
                          alignment: .leading, spacing: Space.l) {
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

    func exactBanner(_ ex: Usage.Exact, _ u: Usage) -> some View {
        let desktop = u.accounts.first { $0.current }?.email
        let mismatch = ex.email != nil && desktop != nil && ex.email != desktop
        return HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: mismatch ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(mismatch ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(ex.ok == true ? L("精确模式：\(ex.email ?? "") 的额度来自 Anthropic 官方", "Exact mode: \(ex.email ?? "")'s usage comes from Anthropic")
                                   : exactStatusText(ex))
                    .font(.callout.weight(.medium))
                if mismatch {
                    Text(L("命令行登录的是 \(ex.email ?? "")，桌面版当前是 \(desktop ?? "")，所以桌面版这个号仍是本地数据。",
                           "The CLI is signed in to \(ex.email ?? ""), the desktop app to \(desktop ?? "") — the desktop account still uses local data."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill((mismatch ? Color.orange : Color.green).opacity(0.08)))
    }

    func usageCard(_ a: Usage.Account) -> some View {
        Card(padding: Radius.inset) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .top, spacing: Space.m) {
                    Avatar(name: a.avatarText, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.title).font(TypeScale.cardTitle).lineLimit(1).truncationMode(.tail)
                            .textSelection(.enabled).help(a.title)
                        HStack(spacing: Space.s) {
                            if a.current { Tag(text: L("当前登录", "Signed in")) }
                            noteChip(a)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding([.horizontal, .top], Space.s).padding(.bottom, Space.xs)
                limitBlock(L("5 小时额度", "5-hour limit"), a.fiveHour, a.fiveHourEstimated, a.fiveHourReset,
                           resetWord: L("下次恢复", "Resets"),
                           idle: a.fiveHour == nil ? L("暂无数据", "no data")
                               : L("现在可用 · 开始使用后 5 小时内恢复", "Available · resets 5 h after you start"))
                limitBlock(L("每周额度", "Weekly limit"), a.weekly, a.weeklyEstimated, a.weeklyReset,
                           resetWord: L("下次重置", "Resets"),
                           idle: a.weekly == nil ? L("暂无数据", "no data")
                               : L("重置时间未知 · 碰到一次每周限额后就能算准", "Reset time unknown until the weekly limit is hit once"))
                HStack {
                    Text(a.updatedAt > 0 ? L("Claude 记录于 ", "Recorded ") + shortTime(a.updatedAt) : L("暂无用量记录", "No usage yet"))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if !a.current {
                        Button { m.switchTo(a) } label: {
                            Label(L("切换到这个号", "Switch to this"), systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.secondary)
                    }
                }
                .frame(minHeight: 28)
                .padding(.horizontal, Space.s).padding(.bottom, Space.xs)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .stroke(a.current ? brand.opacity(0.45) : .clear, lineWidth: 1.5))
    }

    func limitBlock(_ title: String, _ v: Int?, _ est: Bool, _ r: Usage.Reset?, resetWord: String, idle: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(v.map { "\($0)%" } ?? "—")
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(v == nil ? .secondary : (est ? .secondary : usageColor(v)))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(usageColor(v).opacity(est ? 0.45 : 0.9))
                        .frame(width: v == nil ? 0 : max(6, g.size.width * min(max(Double(v ?? 0) / 100, 0), 1)))
                }
            }
            .frame(height: 6)
            if let r = r {
                HStack(spacing: Space.s) {
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
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    // MARK: chats

    var chatsPage: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            PageHeader(title: L("对话", "Chats"),
                       subtitle: L("备份、恢复和整理 Claude Code 的对话列表", "Back up, restore and tidy your Claude Code chat list"))
            Card(padding: 0) {
                VStack(spacing: 0) {
                    actionRow("arrow.down.circle", L("恢复到当前账号", "Restore to this account"),
                              L("把所有账号的对话加进当前账号的侧边栏。", "Add chats from every account to this account's sidebar."),
                              L("恢复", "Restore"), prominent: true, enabled: m.status != nil) { m.confirmRestore = true }
                    Divider().padding(.leading, 58)
                    actionRow("externaldrive.badge.checkmark", L("立即备份", "Back up now"),
                              L("后台每分钟会自动备份，这里可以手动再来一次。", "Runs every minute in the background; run it now by hand."),
                              L("备份", "Back up"), enabled: true) { Task { await m.run(["backup"]) } }
                    Divider().padding(.leading, 58)
                    actionRow("sparkles", L("清理旧对话", "Clean up old chats"),
                              m.rules.enabled ? L("按下面的保留规则，从所有账号里移除旧对话。", "Remove old chats from every account using the rule below.")
                                              : L("先打开下面的保留规则。", "Turn on the keep rule below first."),
                              L("清理…", "Clean up…"), enabled: m.rules.enabled) { Task { await m.preparePrune() } }
                    Divider().padding(.leading, 58)
                    actionRow("arrow.uturn.backward", L("撤销上次操作", "Undo last action"),
                              L("撤销上一次「恢复」或「清理」。", "Undo the last restore or cleanup."),
                              L("撤销", "Undo"), enabled: m.status?.canUndo ?? false) { m.confirmUndo = true }
                }
            }
            .disabled(m.busy)

            Text(L("保留规则", "Keep rule")).font(TypeScale.section).padding(.bottom, -Space.m)   // title sits with its card
            Card {
                let r = m.rules
                VStack(alignment: .leading, spacing: Space.m) {
                    switchRow(L("只保留最近的对话", "Keep only recent chats"),
                              L("恢复时只带这些对话过去，「清理旧对话」也按这个规则。", "Restore brings only these, and Clean up uses the same rule."),
                              Binding(get: { r.enabled }, set: { v in var n = r; n.enabled = v; m.saveRules(n) }))
                    if r.enabled {
                        Divider()
                        HStack(spacing: Space.xxl) {
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
        HStack(spacing: Space.m) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(brand)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(brand.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) { Text(button).frame(minWidth: 52) }
                .buttonStyle(FilledButton(primary: prominent)).disabled(!enabled)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
    }

    func switchRow(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
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
        HStack(spacing: Space.m) {
            if let t = m.refreshedAt, !m.refreshing {
                Text(L("已刷新 ", "Refreshed ") + t.formatted(date: .omitted, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await m.manualRefresh() } } label: {
                HStack(spacing: Space.xs) {
                    if m.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    Text(L("刷新", "Refresh"))
                }
            }
            .buttonStyle(.secondary)
            .disabled(m.refreshing)
        }
    }

    var remindersCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.m) {
                switchRow(L("换号提醒", "Account switch reminder"),
                          L("一换号就弹系统通知：现在是哪个邮箱、对话要不要恢复、这个号的额度用了多少。",
                            "A system notification as soon as you switch: which email you're on, whether chats need restoring, and how much of its limits is used."),
                          Binding(get: { m.notifySwitch }, set: { m.saveSetting("notify_switch", $0) }))
                Divider()
                switchRow(L("额度提醒", "Usage reminder"),
                          L("当前账号的 5 小时或每周额度用到 \(m.quotaAlertAt)% 时提醒一次，并告诉你什么时候恢复。",
                            "Tells you once when the signed-in account reaches \(m.quotaAlertAt)% of its 5-hour or weekly limit, and when it resets."),
                          Binding(get: { m.notifyQuota }, set: { m.saveSetting("notify_quota", $0) }))
                if m.notifyQuota {
                    Stepper(value: Binding(get: { m.quotaAlertAt }, set: { m.saveSetting("quota_alert_at", $0) }), in: 50...99, step: 5) {
                        Text(L("提醒阈值：\(m.quotaAlertAt)%", "Remind at \(m.quotaAlertAt)%")).font(.callout)
                    }
                }
                Divider()
                HStack {
                    Text(L("提醒由后台任务发出，换号助手不用开着。第一次会请求通知权限。",
                           "The background job sends them — this app doesn't need to be open. macOS may ask to allow notifications once."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("发一条试试", "Send a test")) { Task { await m.testReminder() } }.buttonStyle(.secondary)
                }
            }
        }
    }

    var exactModeCard: some View {
        let ex = m.usage?.exact
        let on = ex?.enabled ?? false
        return Card {
            VStack(alignment: .leading, spacing: Space.m) {
                switchRow(L("精确模式（读取官方额度）", "Exact mode (official usage)"),
                          L("开启后，在你用过 Claude 之后（最多 10 分钟一次、每天最多 60 次），用 Claude Code 自己保存的登录凭证向 Anthropic 查询一次当前账号的额度（与 /usage 命令同一个接口），百分比和重置时间都是官方数字。凭证只用于这次查询，不保存、不刷新、不发往别处。开启时会锁定当前网络，断网不查询，出口 IP 或网络一变就自动关闭。第一次开启时 macOS 会询问是否允许读取钥匙串。",
                            "After you've used Claude (at most every 10 min, 60 a day), uses the sign-in Claude Code already stores to ask Anthropic for the signed-in account's usage (same endpoint as /usage) — official numbers. The credential is used for that request only. Locks to your current network: nothing is sent offline, and it turns itself off if the egress IP or network changes. The first time, macOS asks to allow Keychain access."),
                          Binding(get: { on }, set: { v in Task { await m.setExactMode(v) } }))
                if !on, let off = ex?.autoOffAt, ex?.error != nil {
                    Divider()
                    HStack(alignment: .top, spacing: Space.s) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        Text(L("已在 \(shortTime(off)) 自动关闭：", "Turned off at \(shortTime(off)): ") + exactStatusText(ex)
                             + L(" 确认网络稳定后可以重新打开。", " Turn it back on once your network is stable."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if on {
                    Divider()
                    HStack(spacing: Space.s) {
                        Circle().fill((ex?.ok ?? false) ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(exactStatusText(ex)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Space.s) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        Text(L("网络已锁定：", "Network locked: ") + (ex?.lockedIp ?? "—")
                             + L(" · 今天查询 \(ex?.count ?? 0) 次（上限 60）", " · \(ex?.count ?? 0) reads today (max 60)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("只在你用过 Claude 之后才查询，最多 10 分钟一次；断网不查询；出口 IP、网关、代理或 VPN 一变就自动关闭。",
                           "Reads only after you've used Claude, at most every 10 min; never offline; turns itself off if the egress IP, gateway, proxy or VPN changes."))
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Text(L("只覆盖命令行版 Claude Code 登录的那个号；想让它和桌面版一致，在终端里运行 claude 并用 /login 登录同一个号。",
                           "Covers only the account the Claude Code CLI is signed in to; to match the desktop app, run claude in Terminal and /login with the same account."))
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func exactStatusText(_ ex: Usage.Exact?) -> String {
        guard let ex = ex else { return "" }
        if ex.ok == true {
            return L("已连接：", "Connected: ") + (ex.email ?? "?")
                + (ex.lastOk.map { L(" · 上次更新 ", " · updated ") + shortTime($0) } ?? "")
        }
        switch ex.error ?? "" {
        case "no_credentials": return L("没找到 Claude Code 的登录：在终端运行 claude 登录一次即可。", "No Claude Code sign-in found: run claude in Terminal and sign in once.")
        case "token_expired": return L("登录凭证已过期：打开一次 Claude Code 它会自动续期，之后这里会恢复。", "Sign-in expired: open Claude Code once and it renews itself.")
        case "http_401", "http_403": return L("官方拒绝了这次查询（登录已失效），在 Claude Code 里重新登录即可。", "Anthropic refused the request (sign-in no longer valid) — sign in again in Claude Code.")
        case "http_429": return L("查询太频繁，已自动暂停 30 分钟。", "Too many requests — paused for 30 minutes.")
        case "network": return ex.detail == "repeated" ? L("连续几次网络失败。", "Several network failures in a row.")
                                                       : L("网络连接失败，稍后会自动重试。", "Network error — will retry.")
        case "offline": return L("现在没联网，暂不查询（不会发送任何请求）。", "Offline — not reading (nothing is sent).")
        case "daily_cap": return L("今天已查询 60 次，明天再继续。", "60 reads today — continuing tomorrow.")
        case "env_changed":
            let what = (ex.detail ?? "").split(separator: ",").map { $0 == "ip" ? L("出口 IP", "egress IP") : L("本机网络（网关/代理/VPN）", "local network (gateway/proxy/VPN)") }
            return L("网络环境变了（", "Network changed (") + what.joined(separator: L("、", ", ")) + L("），为避免风控已停止查询。", ") — stopped to stay safe.")
        case "": return L("等待第一次读取…", "Waiting for the first read…")
        default: return L("读取失败：", "Read failed: ") + (ex.error ?? "")
        }
    }

    // MARK: guide

    var guidePage: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            PageHeader(title: L("使用指南", "Guide"), subtitle: L("三分钟看懂怎么用", "Everything in three minutes"))
            guideCard("1", L("平时：什么都不用做", "Day to day: nothing to do"), [
                L("后台每分钟自动备份一次对话列表和额度记录，只在有变化时才写入。", "A background job backs up chat lists and usage every minute, writing only when something changed."),
                L("「额度」页每 30 秒自动刷新；想马上看最新的，点右上角「刷新」。", "The Usage page refreshes every 30 s; press Refresh for the latest."),
            ])
            guideCard("2", L("换号：三步", "Switching accounts: three steps"), [
                L("在「额度」或「概览」里，对要换的号点「切换」，邮箱会自动复制。", "In Usage or Overview, click Switch on the account you want — its email is copied for you."),
                L("在 Claude 左下角点头像 → 退出登录，再用这个邮箱登录，打开一次 Code 标签页。", "In Claude: avatar (bottom left) → Log out, sign in with that email, open the Code tab once."),
                L("一分钟内会弹出系统通知告诉你换到了哪个号、额度用了多少，然后倒数 10 秒把之前的对话恢复到这个号；想停下就点「取消」。如果有对话正在回复，会等它结束再恢复。",
                  "Within a minute a notification tells you which account you're on and how much of it is used, then your chats are restored after a 10-second countdown — Cancel stops it. A chat that's still answering is never cut off."),
                L("额度用到 90% 时也会提醒一次（可以在「设置 → 提醒」里调整或关闭）。", "You're also told once when a limit reaches 90% (change or turn off in Settings → Reminders)."),
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
            HStack(alignment: .top, spacing: Space.m) {
                Text(n).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(brand))
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(title).font(TypeScale.section)
                    ForEach(items, id: \.self) { t in
                        HStack(alignment: .top, spacing: Space.s) {
                            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4).padding(.top, Space.s)
                            Text(t).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: settings

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            PageHeader(title: L("设置", "Settings"), subtitle: L("后台任务、备份位置和关于", "Background job, vault and about"))
            Card {
                let s = m.status
                VStack(alignment: .leading, spacing: Space.m) {
                switchRow(L("换号后自动恢复对话", "Restore chats automatically after a switch"),
                          L("检测到换号后倒数 10 秒自动恢复（Claude 会重启），期间可以取消。关掉后改为弹窗询问。",
                            "After a switch, restores on its own after a 10-second countdown (Claude restarts); you can cancel. Off: ask first."),
                          Binding(get: { m.autoRestore }, set: { m.saveAutoRestore($0) }))
                Divider()
                switchRow(L("后台任务（自动备份 + 换号检测）", "Background job (backup + switch detection)"),
                          L("每分钟备份一次对话列表和额度记录，并检测换号。关掉后不会自动恢复，也不会有提醒。",
                            "Backs up chat lists and usage every minute and watches for switches. Off: no automatic restore and no reminders."),
                          Binding(get: { s?.autoBackup ?? false }, set: { on in
                              Task { await m.run([on ? "install-agent" : "uninstall-agent"]) }
                          }))
                }
            }
            Text(L("提醒", "Reminders")).font(TypeScale.section).padding(.bottom, -Space.m)
            remindersCard
            exactModeCard
            Card {
                HStack(spacing: Space.m) {
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
                        .buttonStyle(.secondary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(spacing: Space.m) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Claude 换号助手", "Session Keeper for Claude")).font(TypeScale.section)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // CSV_SNAPSHOT_SCALE=2 renders at Retina resolution (README screenshots)
            let scale = CGFloat(Double(env["CSV_SNAPSHOT_SCALE"] ?? "1") ?? 1)
            if let w = NSApp.windows.first, let v = w.contentView?.superview ?? w.contentView,
               let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale),
                                          pixelsHigh: Int(v.bounds.height * scale), bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = v.bounds.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
                NSRect(origin: .zero, size: v.bounds.size).fill()
                NSGraphicsContext.restoreGraphicsState()
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
