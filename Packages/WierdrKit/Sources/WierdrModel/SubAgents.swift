import Foundation

/// Who started whom (`parent`), as the sidebar reads it (the user's
/// `wierd-agents`: kit.js `tree`, spaces.js `countBySpace`, agents.js `homeOf`).
/// Built from one snapshot of spaces and terminals.
///
/// - An agent with a pane (a row of the list) shows its live children under
///   it, depth first, each followed by its own: sub-agents (they report a
///   status) and plain terminals. Kept ones (someone gave them a pane) still
///   show there, not as rows of their own tab.
/// - The counts count the rows (`countedAgents`): each agent, and a sub-agent
///   in the space of the topmost agent it shows under, with its status as it
///   reads there (`kidStatus`: never done).
struct SubAgentIndex {
    struct Place: Hashable, Sendable {
        var space: String
        var tab: String
        var pane: String
    }

    let terminals: [String: TerminalInfo]
    /// Live terminals by the address that started them, oldest first.
    let children: [String: [TerminalInfo]]
    /// Each terminal shown in a pane: where.
    let placed: [String: Place]
    /// Each space's agents by status (`counts()`), space ids → counts.
    private(set) var countsBySpace: [String: [AgentStatus: Int]] = [:]

    init(spaces: [Space], terminals: [String: TerminalInfo]) {
        self.terminals = terminals
        var placed: [String: Place] = [:]
        for space in spaces {
            for tab in space.tabs {
                for pane in tab.panes {
                    if let a = pane.terminal, placed[a] == nil { placed[a] = Place(space: space.id, tab: tab.id, pane: pane.id) }
                }
            }
        }
        self.placed = placed
        var children: [String: [TerminalInfo]] = [:]
        for t in terminals.values where t.isLive {
            if let p = t.parent, p != t.address { children[p, default: []].append(t) }
        }
        for k in children.keys {
            children[k]!.sort { a, b in
                let ta = a.createdAt ?? .distantPast, tb = b.createdAt ?? .distantPast
                if ta != tb { return ta < tb }
                if a.address.count != b.address.count { return a.address.count < b.address.count }
                return a.address < b.address
            }
        }
        self.children = children
        countsBySpace = Self.counts(spaces: spaces, index: self)
    }

    /// An agent of the list: an agent shown in a pane (`SidebarOrder` gives it a
    /// row; an ended one too, its live children still show under it).
    func isListed(_ address: String) -> Bool {
        guard placed[address] != nil, let t = terminals[address] else { return false }
        return t.isAgent
    }

    /// The live terminals `address` started, and theirs, depth first, each with
    /// the tree lines in front of it.
    func subtree(of address: String) -> [SubAgent] {
        var out: [SubAgent] = []
        var seen: Set<String> = [address]
        func walk(_ addr: String, _ lead: [SubAgent.Line]) {
            let kids = (children[addr] ?? []).filter { seen.insert($0.address).inserted }
            for (i, k) in kids.enumerated() {
                let last = i == kids.count - 1
                out.append(SubAgent(terminal: k, lines: lead + [last ? .elbow : .tee], paneID: placed[k.address]?.pane))
                walk(k.address, lead + [last ? .blank : .pipe])
            }
        }
        walk(address, [])
        return out
    }

    /// The topmost agent of the list `address` shows under, going up through
    /// live terminals (nil: it shows under none).
    func root(of address: String) -> String? {
        var up = terminals[address]?.parent
        var top: String?
        var seen: Set<String> = [address]
        while let u = up, seen.insert(u).inserted {
            if isListed(u) { top = u }
            guard let p = terminals[u], p.isLive else { break }
            up = p.parent
        }
        return top
    }

    /// Whether `address` shows under an agent of the list rather than as a row of its own.
    func isNested(_ address: String) -> Bool {
        guard let t = terminals[address], t.isLive else { return false }
        return root(of: address) != nil
    }

    /// Each space's agents by status, as its rows count them (`countedAgents`): an
    /// agent with a pane where its pane is, a sub-agent (kept or not) where the
    /// agent it shows under is, as it reads there (never done); each once.
    /// Space ids → counts.
    private static func counts(spaces: [Space], index: SubAgentIndex) -> [String: [AgentStatus: Int]] {
        var out: [String: [AgentStatus: Int]] = [:]
        var seen: Set<String> = []
        for space in spaces {
            for a in SidebarOrder.rows(for: space, index: index).countedAgents
            where seen.insert(a.terminal.address).inserted {
                out[space.id, default: [:]][a.status, default: 0] += 1
            }
        }
        return out
    }

    /// Where a child of an agent goes when kept: next to its nearest ancestor
    /// with a pane (through live terminals). Nil when there is none.
    func home(of address: String) -> (address: String, place: Place)? {
        var up = terminals[address]?.parent
        var seen: Set<String> = [address]
        while let u = up, seen.insert(u).inserted {
            guard let p = terminals[u], p.isLive else { return nil }
            if let place = placed[u] { return (u, place) }
            up = p.parent
        }
        return nil
    }
}
