import Foundation
import WierdrActivity
import WierdrModel

/// What the agents Live Activity shows of a workspace: the iPhone's agents list
/// (`Workspace.inbox`) in counts, and its most urgent agents (no idle ones).
public enum ActivitySummary {
    public typealias State = AgentsActivityAttributes.ContentState

    /// At most this many agent rows (the Lock Screen shows up to 4, the island 3;
    /// one spare keeps payloads well under APNs' 4 KB).
    public static let maxAgents = 5
    /// Titles longer than this are cut (the rows show one line anyway).
    public static let maxTitle = 64
    /// Space names longer than this are cut (the row shows them whole, the title gives way).
    public static let maxSpace = 14

    @MainActor
    public static func state(of ws: Workspace, now: Date = Date()) -> State {
        state(of: ws.inbox, tab: { ws.tab($0) }, now: now)
    }

    /// The same from an inbox (tests): `tab` finds a tab by id for the row titles.
    public static func state(of inbox: [InboxGroup], tab: (String) -> Tab?, now: Date) -> State {
        var s = State(at: now.timeIntervalSince1970.rounded())
        for group in inbox {
            switch group.status {
            case .blocked: s.blocked = group.items.count
            case .done: s.done = group.items.count
            case .working: s.working = group.items.count
            case .idle: s.idle = group.items.count
            }
            guard group.status != .idle else { continue }
            for item in group.items where s.agents.count < maxAgents {
                guard let t = item.row.terminal else { continue }
                s.agents.append(agent(t, status: group.status, tab: tab(item.row.tabID), space: item.space))
            }
        }
        return s
    }

    static func agent(_ t: TerminalInfo, status: AgentStatus, tab: Tab?, space: Space) -> AgentsActivityAttributes.Agent {
        var title = AgentText.title(t, tab: tab)
        if title.count > maxTitle { title = String(title.prefix(maxTitle - 1)) + "…" }
        var spaceName = space.displayName
        if spaceName.count > maxSpace { spaceName = String(spaceName.prefix(maxSpace - 1)) + "…" }
        // Its row's status is its urgency (a sub-agent's blocked); its time is its own.
        return .init(id: t.address, title: title, space: spaceName, spaceColor: space.color,
                     machine: t.machine, status: word(status),
                     since: t.statusChangedAt.map { $0.timeIntervalSince1970.rounded() },
                     model: t.meta?.model ?? t.program.name,
                     icon: t.program.iconAsset, tint: t.program.tint, color: t.program.color)
    }

    public static func word(_ s: AgentStatus) -> AgentStatusWord {
        switch s {
        case .blocked: return .blocked
        case .done: return .done
        case .working: return .working
        case .idle: return .idle
        }
    }

    /// `1 needs you · 2 done · 3 working` (idle only when nothing else).
    public static func line(_ s: State) -> String {
        var parts: [String] = []
        if s.blocked > 0 { parts.append("\(s.blocked) needs you") }
        if s.done > 0 { parts.append("\(s.done) done") }
        if s.working > 0 { parts.append("\(s.working) working") }
        if parts.isEmpty { parts.append(s.idle > 0 ? "\(s.idle) idle" : "No agents") }
        return parts.joined(separator: " · ")
    }
}
