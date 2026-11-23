import Foundation

/// Text rules for an agent's row (ui-spec §10.4), shared by the app and the
/// Live Activity's pusher.
public enum AgentText {
    /// Strip leading non-letter/digit characters (spinner glyphs, bullets) and trim.
    public static func cleanTitle(_ s: String?) -> String {
        guard let s else { return "" }
        let trimmed = s.drop { !($0.isLetter || $0.isNumber) }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A terminal title worth showing: not the program name/key, not a path, no `@`.
    public static func isTelling(_ title: String, program: Program) -> Bool {
        let t = cleanTitle(title)
        if t.isEmpty { return false }
        let lower = t.lowercased()
        if lower == program.name.lowercased() || lower == program.key.lowercased() { return false }
        if t.hasPrefix("~") || t.hasPrefix("/") || t.contains("@") { return false }
        return true
    }

    /// The 7501 app of Claude Code.
    public static let claudeCode = "claude-code"

    /// The 7501 app of Codex (the OpenAI Codex CLI).
    public static let codex = "codex"

    /// What's left of Codex's window title once its own parts are cut: its thread's name,
    /// `""` when there's none (only the project).
    ///
    /// Codex sets the title from `tui.terminal_title` (by default `activity`,
    /// `thread-name`, `project-name`): `⠙ Fix the login redirect | wierdr`, the spinner (cut
    /// already, `TerminalText.shownTitle`) only while it works, the thread's name only once
    /// it has one (the prompt cut short at 48 characters meanwhile). Waiting for you it
    /// blinks `[ ! ] Action Required | …` / `[ . ] Action Required | …` in front of the same
    /// parts. This drops that prefix and a last ` | ` part that is the project's name as
    /// Codex makes it (`terminal_title_project_name`: the folder name of the git root, or
    /// of the folder holding the project's `.codex`, else of the cwd, cut to 24 characters
    /// with "..."), i.e. the name of `cwd` or of a folder it's in. Other title items (a
    /// user's own `terminal_title`) are left as they are.
    public static func codexTitle(_ title: String, cwd: String?) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^(?:●\s*)?\[ [!.] \] Action Required(?:\s+\|\s+|\s*$)"#
        if let r = s.range(of: prefix, options: .regularExpression) { s.removeSubrange(r) }
        var parts = cleanTitle(s).components(separatedBy: " | ")
        if let last = parts.last, isCodexProject(last.trimmingCharacters(in: .whitespaces), cwd: cwd) {
            parts.removeLast()
        }
        return parts.joined(separator: " | ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `name` is Codex's `project-name` for a session in `cwd`: the name of `cwd`
    /// or of a folder it's in, cut as Codex cuts it (24 characters, else 21 and "...").
    static func isCodexProject(_ name: String, cwd: String?) -> Bool {
        guard !name.isEmpty, let cwd else { return false }
        func cut(_ s: String) -> String { s.count > 24 ? String(s.prefix(21)) + "..." : s }
        return cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains { cut(String($0)) == name }
    }

    /// Its window title when it tells something (`isTelling`), cleaned; for Codex
    /// (7501 app `codex`) what's left of it, its thread's name (`codexTitle`).
    public static func tellingTitle(_ t: TerminalInfo) -> String? {
        let title = t.app == codex ? codexTitle(t.title, cwd: t.cwd) : t.title
        return isTelling(title, program: t.program) ? cleanTitle(title) : nil
    }

    /// Agent row title: status message, else tab name (named and ≠ program),
    /// else a telling title, else program name, else tab name, else address.
    ///
    /// Claude Code (7501 app `claude-code`): its `msg` is a passing detail (a progress
    /// note, "1 shell still running", a turn's summary), its session's title (made up by
    /// it or `/rename`) is the terminal's title. So while it needs you (blocked, error)
    /// its message (the question, the error) if any; otherwise a telling title first,
    /// then the message, then the same fallbacks.
    ///
    /// Codex (7501 app `codex`) sends no message; its telling title is its thread's name,
    /// cut out of its window title (`codexTitle`): a title that's only the project's name
    /// leaves the tab's name, else the program's ("Codex").
    public static func title(_ t: TerminalInfo, tab: Tab?) -> String {
        let msg = cleanTitle(t.message)
        let telling = tellingTitle(t)
        if t.app == claudeCode {
            if t.status == .blocked, !msg.isEmpty { return msg }
            if let telling { return telling }
        }
        if !msg.isEmpty { return msg }
        if let tab, !tab.name.isEmpty, tab.name.lowercased() != t.program.name.lowercased() { return tab.name }
        if let telling { return telling }
        if !t.program.name.isEmpty { return t.program.name }
        if let tab { return tab.displayName }
        return t.address
    }

    /// A sub-agent's title under its parent (`kidLabel`): its own word (pi's session
    /// name), else a telling title (Codex's: its thread's name), else its name (`hc run
    /// --name`), its template, its program's name. `plain`: a terminal that isn't an
    /// agent (`termRow`): its name, template or program only.
    public static func kidTitle(_ t: TerminalInfo, plain: Bool = false) -> String {
        if !plain {
            let msg = cleanTitle(t.message)
            if !msg.isEmpty { return msg }
            if let telling = tellingTitle(t) { return telling }
        }
        if let n = t.name, !n.isEmpty { return n }
        if let n = t.template, !n.isEmpty { return n }
        if !t.program.name.isEmpty { return t.program.name }
        return t.address
    }
}

/// An agent in the agents list (the iPhone's inbox): its sidebar row and space.
public struct InboxItem: Identifiable, Hashable, Sendable {
    public var row: SidebarRow
    public var space: Space
    public var id: String { row.paneID }

    public init(row: SidebarRow, space: Space) { self.row = row; self.space = space }
}

/// The agents with one status, in the list's order.
public struct InboxGroup: Hashable, Sendable {
    public var status: AgentStatus
    public var items: [InboxItem]

    public init(status: AgentStatus, items: [InboxItem]) { self.status = status; self.items = items }
}

extension Workspace {
    /// Every agent with a pane (all spaces and computers), grouped by what it
    /// needs: needs you, done, working, idle (an agent goes where its most urgent
    /// sub-agent would). Inside a group: pinned first, then the most recent
    /// status change (`InboxOrder`). Empty groups are left out.
    public var inbox: [InboxGroup] {
        var byStatus: [AgentStatus: [InboxItem]] = [:]
        for space in spaces {
            for row in sidebarRows(for: space) where row.kind == .agent {
                guard let status = InboxOrder.status(row) else { continue }
                byStatus[status, default: []].append(InboxItem(row: row, space: space))
            }
        }
        return [AgentStatus.blocked, .done, .working, .idle].compactMap { status in
            guard let items = byStatus[status], !items.isEmpty else { return nil }
            return InboxGroup(status: status, items: items.sorted(by: InboxOrder.before))
        }
    }

    /// Every agent with a pane in the inbox's order, as one list (the agents panel's):
    /// needs you, done, working, idle, then those with no status yet; in each, pinned
    /// first, then the most recent status change.
    public var agentsByStatus: [InboxItem] {
        var items: [InboxItem] = []
        for space in spaces {
            for row in sidebarRows(for: space) where row.kind == .agent {
                items.append(InboxItem(row: row, space: space))
            }
        }
        return items.sorted(by: InboxOrder.before)
    }
}

/// The inbox's order: by status (an agent's own, or its most urgent sub-agent's), the
/// most urgent first and none last; then pinned first; then the latest status change.
public enum InboxOrder {
    /// What an agent's row needs: its own status or its most urgent sub-agent's.
    public static func status(_ row: SidebarRow) -> AgentStatus? {
        row.urgency ?? row.terminal?.status
    }

    public static func before(_ a: InboxItem, _ b: InboxItem) -> Bool {
        let ua = status(a.row).map { $0.rawValue + 1 } ?? 0, ub = status(b.row).map { $0.rawValue + 1 } ?? 0
        if ua != ub { return ua > ub }
        let ta = a.row.terminal, tb = b.row.terminal
        if ta?.pinned != tb?.pinned { return ta?.pinned == true }
        let da = ta?.statusChangedAt ?? .distantPast, db = tb?.statusChangedAt ?? .distantPast
        if da != db { return da > db }
        return a.row.paneID < b.row.paneID
    }
}
