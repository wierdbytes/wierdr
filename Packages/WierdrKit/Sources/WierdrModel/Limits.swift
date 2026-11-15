import Foundation
import HerdrCore

// Subscription limits (Claude, Codex) as @wierdbytes/pi-herdr publishes them:
// every provider response pi gets is folded into herdr-core's `limits`
// document on the machine pi runs on (schema 1, see that package's README).
// Wierdr reads it from every connected machine, merges the accounts, and the
// sidebar shows them the way the desktop's `limits` mod does.

/// One usage window of an account: "5 hours", "7 days", a model's weekly limit.
public struct LimitWindow: Identifiable, Hashable, Sendable {
    /// Stable within the account: `5h`, `7d`, `7d_oi`, `7d_opus`, `bengalfox.5h`.
    public var id: String
    public var label: String
    /// The window's length (seconds), when known.
    public var length: TimeInterval?
    /// Share used, in percent; can pass 100.
    public var used: Double
    public var resetsAt: Date?
    /// `ok`, `warning`, `exhausted`, when the provider said.
    public var status: String?
    /// When this window was last read.
    public var at: Date

    public init(id: String, label: String, length: TimeInterval? = nil, used: Double, resetsAt: Date? = nil,
                status: String? = nil, at: Date) {
        self.id = id; self.label = label; self.length = length; self.used = used
        self.resetsAt = resetsAt; self.status = status; self.at = at
    }
}

/// A subscription account and its windows.
public struct LimitAccount: Identifiable, Hashable, Sendable {
    /// `<provider>.<account>`, e.g. `claude.849d2d8c`.
    public var id: String
    /// `claude`, `codex`, …
    public var provider: String
    /// A short hash of the provider's account id (`main` without one).
    public var account: String
    /// The account's e-mail, when pi knows it.
    public var label: String?
    /// The plan as the provider names it (`plus`, `max`).
    public var plan: String?
    public var status: String?
    /// The window limiting the account right now.
    public var binding: String?
    /// Last reading of any window.
    public var at: Date
    /// The machine whose pi read it last.
    public var host: String?
    /// Shortest window first.
    public var windows: [LimitWindow]

    public init(id: String, provider: String, account: String, label: String? = nil, plan: String? = nil,
                status: String? = nil, binding: String? = nil, at: Date, host: String? = nil, windows: [LimitWindow]) {
        self.id = id; self.provider = provider; self.account = account; self.label = label; self.plan = plan
        self.status = status; self.binding = binding; self.at = at; self.host = host; self.windows = windows
    }
}

/// Reading, merging and judging limits. Pure functions.
public enum Limits {
    /// The herdr-core document pi-herdr writes.
    public static let documentName = "limits"
    static let schema: Int64 = 1
    /// Two readings of one window can disagree on the reset by a little (Codex derives it).
    static let sameWindow: TimeInterval = 120

    /// Providers in the order the sidebar lists them; others follow by name.
    public static let providerOrder = ["claude", "codex"]

    // MARK: Reading

    /// The accounts of one `limits` document; empty for anything that isn't schema 1.
    public static func parse(_ doc: JSONValue) -> [LimitAccount] {
        guard doc["schema"]?.int64 == schema, let accounts = doc["accounts"]?.object else { return [] }
        var out: [LimitAccount] = []
        for (key, raw) in accounts {
            guard let provider = raw["provider"]?.string, let account = raw["account"]?.string else { continue }
            var windows: [LimitWindow] = []
            for (wid, w) in raw["windows"]?.object ?? JSONObject() {
                guard let used = w["used"]?.double else { continue }
                windows.append(LimitWindow(
                    id: w["id"]?.string ?? wid,
                    label: w["label"]?.string ?? wid,
                    length: w["window_s"]?.double,
                    used: used,
                    resetsAt: w["resets_at"]?.double.map { Date(timeIntervalSince1970: $0) },
                    status: w["status"]?.string,
                    at: Date(timeIntervalSince1970: w["at"]?.double ?? 0)))
            }
            out.append(LimitAccount(
                id: key, provider: provider, account: account,
                label: raw["label"]?.string, plan: raw["plan"]?.string, status: raw["status"]?.string,
                binding: raw["binding"]?.string, at: Date(timeIntervalSince1970: raw["at"]?.double ?? 0),
                host: raw["host"]?.string, windows: sortWindows(windows)))
        }
        return out
    }

    static func sortWindows(_ windows: [LimitWindow]) -> [LimitWindow] {
        windows.sorted { a, b in
            let la = a.length ?? .infinity, lb = b.length ?? .infinity
            return la != lb ? la < lb : a.id < b.id
        }
    }

    // MARK: Merging

    /// Folds window `b` into `a`, as pi-herdr does: within one window (same
    /// reset, give or take two minutes) the used share only grows; a later
    /// window replaces it, an earlier one is dropped; a window without a reset
    /// (not started) replaces one only after its reset passed.
    public static func fold(_ a: LimitWindow?, _ b: LimitWindow) -> LimitWindow {
        guard let a else { return b }
        if let ra = a.resetsAt, let rb = b.resetsAt {
            if rb > ra.addingTimeInterval(sameWindow) { return b }
            if rb < ra.addingTimeInterval(-sameWindow) { return a }
            var out = b.at >= a.at ? b : a
            out.used = max(a.used, b.used)
            out.resetsAt = max(ra, rb)
            out.at = max(a.at, b.at)
            return out
        }
        if let ra = a.resetsAt, b.resetsAt == nil, b.at < ra { return a }
        if a.resetsAt == nil, let rb = b.resetsAt, a.at < rb { return b }
        return b.at >= a.at ? b : a
    }

    /// The same account read on several machines (pi runs on each): one
    /// account per id, its windows folded, its other facts from the newest reading.
    /// Sorted by provider (`providerOrder`), then the most recently used account first.
    public static func merge(_ lists: [[LimitAccount]]) -> [LimitAccount] {
        var byID: [String: LimitAccount] = [:]
        for account in lists.joined() {
            guard var cur = byID[account.id] else { byID[account.id] = account; continue }
            var windows = Dictionary(cur.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for w in account.windows { windows[w.id] = fold(windows[w.id], w) }
            if account.at > cur.at {
                let kept = cur
                cur = account
                cur.label = account.label ?? kept.label
                cur.plan = account.plan ?? kept.plan
            } else {
                cur.label = cur.label ?? account.label
                cur.plan = cur.plan ?? account.plan
            }
            cur.windows = sortWindows(Array(windows.values))
            byID[account.id] = cur
        }
        return byID.values.sorted { a, b in
            let pa = providerOrder.firstIndex(of: a.provider) ?? providerOrder.count
            let pb = providerOrder.firstIndex(of: b.provider) ?? providerOrder.count
            if pa != pb { return pa < pb }
            if a.provider != b.provider { return a.provider < b.provider }
            if a.at != b.at { return a.at > b.at }
            return a.id < b.id
        }
    }

    // MARK: Showing

    /// Windows the sidebar lists. Claude's `7d_oi` (the weekly window with extra
    /// usage folded in) repeats `7d`, as in the desktop's mod.
    public static func shown(_ account: LimitAccount) -> [LimitWindow] {
        account.windows.filter { $0.id != "7d_oi" }
    }

    /// The provider's display name.
    public static func providerName(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// Plan names as the providers call them now (the desktop mod's table):
    /// Claude Max 5x is "Max", 20x "Ultra"; ChatGPT prolite / pro / promax are Pro 100 / 200 / 500.
    public static func planName(_ provider: String, _ raw: String?) -> String? {
        var p = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["claude ", "claude_", "chatgpt ", "chatgpt_"] where p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        p = p.replacingOccurrences(of: "_", with: " ")
        guard !p.isEmpty else { return nil }
        let table: [(String, String)]
        switch provider {
        case "claude":
            table = [("20x|ultra", "Ultra"), ("^max", "Max"), ("^pro", "Pro"), ("^team", "Team"),
                     ("^enterprise", "Enterprise"), ("^free", "Free")]
        case "codex":
            table = [("^prolite$", "Pro 100"), ("^promax$", "Pro 500"), ("^pro$", "Pro 200"), ("^(team|business)$", "Business"),
                     ("^enterprise$", "Enterprise"), ("^edu$", "Edu"), ("^go$", "Go"), ("^plus$", "Plus"), ("^free$", "Free")]
        default:
            table = []
        }
        if let hit = table.first(where: { p.range(of: $0.0, options: .regularExpression) != nil }) { return hit.1 }
        return p.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Several accounts of one provider: each shows its name.
    public static func accountName(_ account: LimitAccount) -> String {
        if let label = account.label, let at = label.firstIndex(of: "@") { return String(label[..<at]) }
        return account.label ?? account.account
    }

    // MARK: Time and pace

    /// The share of the window already gone, 0…1 (nil without a reset or length).
    public static func elapsed(_ w: LimitWindow, now: Date) -> Double? {
        guard let reset = w.resetsAt, let length = w.length, length > 0 else { return nil }
        return min(1, max(0, 1 - reset.timeIntervalSince(now) / length))
    }

    /// The reading belongs to a window that has already reset.
    public static func isReset(_ w: LimitWindow, now: Date) -> Bool {
        if let reset = w.resetsAt { return reset <= now }
        if let length = w.length { return now.timeIntervalSince(w.at) > length }
        return false
    }

    public struct Pace: Equatable, Sendable {
        /// Share of the window gone.
        public var elapsed: Double
        /// used / elapsed: 1 hits 100% exactly at the reset.
        public var ratio: Double
        /// Early in a window (under 10% of its time and 10% used) the ratio is noise.
        public var trusted: Bool
        /// 0 on pace, 1 ahead (›), 2 far ahead (››, from 1.5×).
        public var speed: Int
    }

    public static func pace(_ w: LimitWindow, now: Date) -> Pace? {
        guard let e = elapsed(w, now: now), e > 0, !isReset(w, now: now) else { return nil }
        let r = w.used / (e * 100)
        let trusted = e >= 0.1 || w.used >= 10
        return Pace(elapsed: e, ratio: r, trusted: trusted, speed: !trusted ? 0 : r >= 1.5 ? 2 : r > 1 ? 1 : 0)
    }

    /// How a window looks: `reset` (dim), `ok` (green), `ahead` (yellow), `danger` (red: 90% used or 1.5× pace).
    public enum Tone: Sendable { case reset, ok, ahead, danger }

    public static func tone(_ w: LimitWindow, now: Date) -> (tone: Tone, speed: Int) {
        if isReset(w, now: now) { return (.reset, 0) }
        let speed = pace(w, now: now)?.speed ?? 0
        if w.used >= 90 || speed == 2 { return (.danger, speed) }
        return (speed == 1 ? .ahead : .ok, speed)
    }

    /// The window a collapsed account shows: the pinned one, else the worst projection.
    public static func headline(_ account: LimitAccount, pinned: String?, now: Date) -> LimitWindow? {
        let ws = shown(account)
        if let pinned, let w = ws.first(where: { $0.id == pinned }) { return w }
        func score(_ w: LimitWindow) -> Double {
            if isReset(w, now: now) { return -1 }
            if let p = pace(w, now: now), p.trusted { return w.used / p.elapsed }
            return w.used
        }
        return ws.reduce(nil) { best, w in best.map { score(w) > score($0) ? w : $0 } ?? w }
    }

    // MARK: Text

    /// `37%`, `<1%`.
    public static func percent(_ used: Double) -> String {
        used > 0 && used < 1 ? "<1%" : "\(Int(used.rounded()))%"
    }

    /// `16m`, `2h 05m`, `1d 16h`.
    public static func span(_ seconds: TimeInterval) -> String {
        let m = max(0, Int((seconds / 60).rounded()))
        if m < 60 { return "\(m)m" }
        let h = m / 60
        return h < 24 ? "\(h)h \(String(format: "%02d", m % 60))m" : "\(h / 24)d \(h % 24)h"
    }

    /// `›`, `››` or nothing.
    public static func chevrons(_ speed: Int) -> String { speed == 2 ? "››" : speed == 1 ? "›" : "" }

    /// A window's mark inside its ring: a plain window's number (`5h` → 5, `7d` → 7);
    /// a named one's initial, from its label ("Opus" → O, "Fable" → F, Codex's
    /// "GPT-5.3-Codex-Spark 5h" → G), else from the name in its id when the label
    /// is only the id (`7d_fable` → F).
    public static func symbol(_ w: LimitWindow) -> String {
        let digits = w.id.prefix(while: \.isNumber)
        let rest = w.id.dropFirst(digits.count)
        let unit = !digits.isEmpty && rest.first.map { "mhd".contains($0) } == true
        if unit, rest.count == 1 { return String(digits) }
        if let c = w.label.first, c.isLetter { return c.uppercased() }
        let name = unit ? rest.dropFirst() : Substring(w.id)
        if let c = name.first(where: \.isLetter) { return c.uppercased() }
        return String(w.id.prefix(1)).uppercased()
    }
}
