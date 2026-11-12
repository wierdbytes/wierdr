import Foundation

/// The order of rows under a space card (the user's `wierd-agents` sidebar,
/// docs/research/ui-spec.md §4.11):
/// - tabs that contain agents first, sorted by their first agent; then tabs
///   without agents, in tab order (empty tabs skipped);
/// - inside a tab: agents by pinned → urgency (its own status or its most
///   urgent sub-agent's) → most recent status change → address; then the
///   tab's non-agent panes in pane order.
/// - an agent's sub-agents and terminals (`hc run`) ride along with its row
///   (`subtree`); kept ones (with a pane of their own) are not rows of their tab.
enum SidebarOrder {
    static func rows(for space: Space, terminals: [String: TerminalInfo]) -> [SidebarRow] {
        rows(for: space, index: SubAgentIndex(spaces: [space], terminals: terminals))
    }

    static func rows(for space: Space, index: SubAgentIndex) -> [SidebarRow] {
        let terminals = index.terminals
        struct Group { var tab: Tab; var agents: [SidebarRow]; var others: [SidebarRow] }
        var groups: [Group] = []
        for tab in space.tabs {
            var agents: [SidebarRow] = []
            var others: [SidebarRow] = []
            for pane in tab.panes {
                if let address = pane.terminal {
                    if index.isNested(address) { continue }
                    let info = terminals[address]
                    if let info, info.isAgent {
                        let subtree = index.subtree(of: address)
                        let urgency = AgentStatus.rollup([info.status] + subtree.map(\.terminal.kidStatus))
                        agents.append(SidebarRow(kind: .agent, paneID: pane.id, tabID: tab.id, terminal: info,
                                                 subtree: subtree, urgency: urgency))
                    } else {
                        others.append(SidebarRow(kind: .terminal, paneID: pane.id, tabID: tab.id, terminal: info))
                    }
                } else {
                    others.append(SidebarRow(kind: .mod, paneID: pane.id, tabID: tab.id, terminal: nil, mod: pane.mod))
                }
            }
            agents.sort(by: before)
            // A tab's rows are joined by a bracket when it shows two or more.
            let split = agents.count + others.count > 1
            for i in agents.indices { agents[i].tabIsSplit = split }
            for i in others.indices { others[i].tabIsSplit = split }
            if !agents.isEmpty || !others.isEmpty { groups.append(Group(tab: tab, agents: agents, others: others)) }
        }
        let withAgents = groups.filter { !$0.agents.isEmpty }
            .sorted { before($0.agents[0], $1.agents[0]) }
        let without = groups.filter { $0.agents.isEmpty }
        return (withAgents + without).flatMap { $0.agents + $0.others }
    }

    /// Agent order: pinned first, then more urgent (with its sub-agents), then
    /// newer status change, then address desc.
    static func before(_ a: SidebarRow, _ b: SidebarRow) -> Bool {
        before(a.terminal, b.terminal, urgency: (a.urgency, b.urgency))
    }

    static func before(_ a: TerminalInfo?, _ b: TerminalInfo?, urgency: (AgentStatus?, AgentStatus?)? = nil) -> Bool {
        guard let a, let b else { return a != nil }
        if a.pinned != b.pinned { return a.pinned }
        let ua = urgency.map { $0.0 } ?? a.status, ub = urgency.map { $0.1 } ?? b.status
        let ra = ua?.rawValue ?? 0, rb = ub?.rawValue ?? 0
        if ra != rb { return ra > rb }
        let ta = a.statusChangedAt ?? .distantPast, tb = b.statusChangedAt ?? .distantPast
        if ta != tb { return ta > tb }
        return a.address > b.address
    }
}
