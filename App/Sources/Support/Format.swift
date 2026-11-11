import Foundation
import WierdrModel

/// Text rules of the sidebar and the panel (ui-spec §10.4, §4.9, §8).
enum Format {
    /// `59.4k`, `105k`, `1.2M`; `nil` when 0/absent.
    static func context(_ n: Int?) -> String? {
        guard let n, n > 0 else { return nil }
        if n < 1000 { return String(n) }
        if n < 100_000 {
            let v = (Double(n) / 1000 * 10).rounded() / 10
            if v >= 100 { return "100k" }
            return v == v.rounded() ? "\(Int(v))k" : String(format: "%.1fk", v)
        }
        if n < 1_000_000 {
            let k = Int((Double(n) / 1000).rounded())
            return k >= 1000 ? "1M" : "\(k)k"
        }
        let v = (Double(n) / 1_000_000 * 10).rounded() / 10
        return v == v.rounded() ? "\(Int(v))M" : String(format: "%.1fM", v)
    }

    /// `56s`, `28m`, `3h`, `2d`.
    static func age(since date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    /// `$HOME` → `~` (connected computer's home, else a `/Users/x`/`/home/x` prefix).
    static func tilde(_ path: String?, home: String?) -> String {
        guard var path, !path.isEmpty else { return "" }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if let home, !home.isEmpty, path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        for root in ["/Users/", "/home/"] where path.hasPrefix(root) {
            let rest = path.dropFirst(root.count)
            if let slash = rest.firstIndex(of: "/") { return "~" + rest[slash...] }
            return "~"
        }
        if path == "/root" { return "~" }
        return path
    }

    /// Strip leading non-letter/digit characters (spinner glyphs, bullets) and trim.
    static func cleanTitle(_ s: String?) -> String {
        guard let s else { return "" }
        let trimmed = s.drop { !($0.isLetter || $0.isNumber) }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A terminal title worth showing: not the program name/key, not a path, no `@`.
    static func isTelling(_ title: String, program: Program) -> Bool {
        let t = cleanTitle(title)
        if t.isEmpty { return false }
        let lower = t.lowercased()
        if lower == program.name.lowercased() || lower == program.key.lowercased() { return false }
        if t.hasPrefix("~") || t.hasPrefix("/") || t.contains("@") { return false }
        return true
    }

    /// Agent row title (§10.4): status message, else tab name (named and ≠ program),
    /// else a telling title, else program name, else tab name, else address.
    static func agentTitle(_ t: TerminalInfo, tab: Tab?) -> String {
        let msg = cleanTitle(t.message)
        if !msg.isEmpty { return msg }
        if let tab, !tab.name.isEmpty, tab.name.lowercased() != t.program.name.lowercased() { return tab.name }
        if isTelling(t.title, program: t.program) { return cleanTitle(t.title) }
        if !t.program.name.isEmpty { return t.program.name }
        if let tab { return tab.displayName }
        return t.address
    }

    /// Plain terminal row name (§4.9): the foreground process's own name.
    static func processName(_ t: TerminalInfo) -> String {
        if let p = t.processName, !p.isEmpty { return p.hasPrefix("-") ? String(p.dropFirst()) : p }
        if let n = t.name, !n.isEmpty { return n }
        return t.program.name
    }

    /// Plain terminal row folder: for a shell the path in its `user@host:PATH` title, else cwd.
    static func folder(_ t: TerminalInfo, home: String?) -> String {
        if t.program.isShell, let colon = t.title.firstIndex(of: ":"), t.title[..<colon].contains("@") {
            let path = t.title[t.title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return tilde(path, home: home) }
        }
        return tilde(t.cwd, home: home)
    }

    /// Pane header name (§8): agent or shell → program name; else the title; else program name.
    static func paneName(_ t: TerminalInfo?) -> String {
        guard let t else { return "shell" }
        if t.isAgent || t.program.isShell { return t.program.name }
        let title = cleanTitle(t.title)
        if !title.isEmpty { return title }
        if !t.program.name.isEmpty { return t.program.name }
        return "shell"
    }

    /// "1 needs you · 2 done · 3 working"
    static func summary(_ counts: [AgentStatus: Int]) -> String {
        var parts: [String] = []
        if let n = counts[.blocked], n > 0 { parts.append("\(n) needs you") }
        if let n = counts[.done], n > 0 { parts.append("\(n) done") }
        if let n = counts[.working], n > 0 { parts.append("\(n) working") }
        if let n = counts[.idle], n > 0 { parts.append("\(n) idle") }
        return parts.joined(separator: " · ")
    }

    static func statusWord(_ s: AgentStatus?) -> String {
        switch s {
        case .blocked: return "needs you"
        case .done: return "done"
        case .working: return "working"
        case .idle: return "idle"
        case nil: return ""
        }
    }

    /// Git tail of a space header (§4.3): `repo · branch`, each only where unusual.
    static func gitTail(_ space: Space) -> String? {
        guard let git = space.git else { return nil }
        var parts: [String] = []
        if let repo = git.repo, !repo.isEmpty, repo != space.displayName, !git.isWorktree { parts.append(repo) }
        if let branch = git.branch, !branch.isEmpty {
            if branch != space.displayName && branch != "main" && branch != "master" { parts.append(branch) }
        } else if git.top != nil {
            parts.append("detached")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
