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

    /// Agent row title: status message, else tab name (named and ≠ program),
    /// else a telling title, else program name, else tab name, else address.
    ///
    /// Claude Code (7501 app `claude-code`): its `msg` is a passing detail (a progress
    /// note, "1 shell still running", a turn's summary), its session's title (made up by
    /// it or `/rename`) is the terminal's title. So while it needs you (blocked, error)
    /// its message (the question, the error) if any; otherwise a telling title first,
    /// then the message, then the same fallbacks.
    public static func title(_ t: TerminalInfo, tab: Tab?) -> String {
        let msg = cleanTitle(t.message)
        if t.app == claudeCode {
            if t.status == .blocked, !msg.isEmpty { return msg }
            if isTelling(t.title, program: t.program) { return cleanTitle(t.title) }
        }
        if !msg.isEmpty { return msg }
        if let tab, !tab.name.isEmpty, tab.name.lowercased() != t.program.name.lowercased() { return tab.name }
        if isTelling(t.title, program: t.program) { return cleanTitle(t.title) }
        if !t.program.name.isEmpty { return t.program.name }
        if let tab { return tab.displayName }
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
    /// status change. Empty groups are left out.
    public var inbox: [InboxGroup] {
        var byStatus: [AgentStatus: [InboxItem]] = [:]
        for space in spaces {
            for row in sidebarRows(for: space) where row.kind == .agent {
                guard let status = row.urgency ?? row.terminal?.status else { continue }
                byStatus[status, default: []].append(InboxItem(row: row, space: space))
            }
        }
        return [AgentStatus.blocked, .done, .working, .idle].compactMap { status in
            guard let items = byStatus[status], !items.isEmpty else { return nil }
            return InboxGroup(status: status, items: items.sorted { a, b in
                let ta = a.row.terminal, tb = b.row.terminal
                if ta?.pinned != tb?.pinned { return ta?.pinned == true }
                let da = ta?.statusChangedAt ?? .distantPast, db = tb?.statusChangedAt ?? .distantPast
                if da != db { return da > db }
                return a.row.paneID < b.row.paneID
            })
        }
    }
}
