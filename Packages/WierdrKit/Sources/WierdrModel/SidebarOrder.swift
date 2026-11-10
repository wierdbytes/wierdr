import Foundation

/// The order of rows under a space card (the user's `wierd-agents` sidebar,
/// docs/research/ui-spec.md §4.11):
/// - tabs that contain agents first, sorted by their first agent; then tabs
///   without agents, in tab order (empty tabs skipped);
/// - inside a tab: agents by pinned → urgency → most recent status change →
///   address; then the tab's non-agent panes in pane order.
enum SidebarOrder {
    static func rows(for space: Space, terminals: [String: TerminalInfo]) -> [SidebarRow] {
        struct Group { var tab: Tab; var agents: [SidebarRow]; var others: [SidebarRow] }
        var groups: [Group] = []
        for tab in space.tabs {
            let panes = tab.panes
            let split = panes.count > 1
            var agents: [SidebarRow] = []
            var others: [SidebarRow] = []
            for pane in panes {
                if let address = pane.terminal {
                    let info = terminals[address]
                    if let info, info.isAgent {
                        agents.append(SidebarRow(kind: .agent, paneID: pane.id, tabID: tab.id, terminal: info, tabIsSplit: split))
                    } else {
                        others.append(SidebarRow(kind: .terminal, paneID: pane.id, tabID: tab.id, terminal: info, tabIsSplit: split))
                    }
                } else {
                    others.append(SidebarRow(kind: .mod, paneID: pane.id, tabID: tab.id, terminal: nil, mod: pane.mod, tabIsSplit: split))
                }
            }
            agents.sort { before($0.terminal, $1.terminal) }
            if !agents.isEmpty || !others.isEmpty { groups.append(Group(tab: tab, agents: agents, others: others)) }
        }
        let withAgents = groups.filter { !$0.agents.isEmpty }
            .sorted { before($0.agents.first?.terminal, $1.agents.first?.terminal) }
        let without = groups.filter { $0.agents.isEmpty }
        return (withAgents + without).flatMap { $0.agents + $0.others }
    }

    /// Agent order: pinned first, then more urgent, then newer status change, then address desc.
    static func before(_ a: TerminalInfo?, _ b: TerminalInfo?) -> Bool {
        guard let a, let b else { return a != nil }
        if a.pinned != b.pinned { return a.pinned }
        let ra = a.status?.rawValue ?? 0, rb = b.status?.rawValue ?? 0
        if ra != rb { return ra > rb }
        let ta = a.statusChangedAt ?? .distantPast, tb = b.statusChangedAt ?? .distantPast
        if ta != tb { return ta > tb }
        return a.address > b.address
    }
}
