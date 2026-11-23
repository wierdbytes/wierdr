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
    /// the tree lines in front of it (drawn with the records, `tree(of:)`).
    func subtree(of address: String) -> [SubAgent] {
        tree(of: address).compactMap(\.kid)
    }

    /// `subtree(of:)` with the records its terminals report (`TerminalInfo.records`):
    /// under each terminal (`address` itself too) its children, each followed by its
    /// own, then its records, by id. Records last: they come and go with each
    /// background job, and so leave the rows of the terminals they share a level with
    /// where they were.
    func tree(of address: String) -> [TreeNode] {
        var out: [TreeNode] = []
        var seen: Set<String> = [address]
        func walk(_ addr: String, _ lead: [SubAgent.Line]) {
            let kids = (children[addr] ?? []).filter { seen.insert($0.address).inserted }
            let records = terminals[addr].map { $0.isLive ? $0.records : [] } ?? []
            let program = terminals[addr]?.program.name
            let count = kids.count + records.count
            for (i, k) in kids.enumerated() {
                let last = i == count - 1
                out.append(.kid(SubAgent(terminal: k, lines: lead + [last ? .elbow : .tee], paneID: placed[k.address]?.pane)))
                walk(k.address, lead + [last ? .blank : .pipe])
            }
            for (j, r) in records.enumerated() {
                let last = kids.count + j == count - 1
                out.append(.record(RecordKid(record: r, owner: addr, lines: lead + [last ? .elbow : .tee], program: program)))
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

/// How an agent's tree folds in the list: its sub-agents all at once (the bot chip on the
/// agent's row; open unless folded), and each agent's terminals (plain terminals it
/// started, the background shells it reports) on their own (the `>_` chip on that agent's
/// or sub-agent's row; folded until it's tapped). A row hidden hides what hangs under it;
/// the lines of what shows are drawn afresh (`relined`).
public enum TreeFolds {
    /// For each node of `tree`, the agent whose `>_` chip it's under: a terminal's row's
    /// nearest agent above it (the row's agent, the root, is its depth-1 rows' owner); nil
    /// for a sub-agent's row.
    public static func chipOwners(_ tree: [TreeNode]) -> [String?] {
        // A plain terminal of the tree: the agent whose chip it's under (nested terminals go with it).
        var plain: [String: String] = [:]
        return tree.map { node in
            guard node.isTerminal, let owner = node.owner else { return nil }
            let agent = plain[owner] ?? owner
            if let a = node.address { plain[a] = agent }
            return agent
        }
    }

    /// What the `>_` chip of `agent` counts: the terminal rows under it (`chipOwners`).
    /// `agent` nil: the row's own agent, the tree's root.
    public static func terminals(of agent: String?, in tree: [TreeNode]) -> TerminalTally {
        guard let agent = agent ?? tree.first?.owner else { return TerminalTally() }
        var out = TerminalTally()
        for (node, owner) in zip(tree, chipOwners(tree)) where owner == agent {
            if node.kid != nil { out.terminals += 1 } else { out.shells += 1 }
        }
        return out
    }

    /// The rows of `tree` that show: sub-agents' while `agentsOpen`, an agent's terminals
    /// while `terminalsOpen(agent)`, nothing under a hidden row; `forced` (node ids: the agents panel's
    /// matches) and the rows they hang under show whatever the folds. Relined.
    public static func shown(_ tree: [TreeNode], agentsOpen: Bool, terminalsOpen: (String) -> Bool,
                             forced: Set<String> = []) -> [TreeNode] {
        let owners = chipOwners(tree)
        var keep = forced
        if !forced.isEmpty {
            let byAddress = Dictionary(tree.compactMap { n in n.address.map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
            for node in tree where forced.contains(node.id) {
                var up = node.owner
                while let u = up, let parent = byAddress[u], keep.insert(parent.id).inserted { up = parent.owner }
            }
        }
        var hidden: Set<String> = []
        var out: [TreeNode] = []
        for (node, owner) in zip(tree, owners) {
            let show: Bool
            if keep.contains(node.id) {
                show = true
            } else if let o = node.owner, hidden.contains(o) {
                show = false
            } else if node.isTerminal {
                show = owner.map(terminalsOpen) ?? true
            } else {
                show = agentsOpen
            }
            if show { out.append(node) } else if let a = node.address { hidden.insert(a) }
        }
        return relined(out)
    }

    /// The lines of a depth-first tree drawn afresh for the rows it shows: each row's own
    /// `├`, or `└` when no sibling follows it; an ancestor's `│` past it while that one has
    /// a sibling still to come. A row's depth is its lines' count (a row shown has every
    /// row above it shown).
    public static func relined(_ tree: [TreeNode]) -> [TreeNode] {
        let depths = tree.map(\.lines.count)
        var last = [Bool](repeating: true, count: tree.count)
        for i in tree.indices {
            for j in (i + 1)..<tree.count {
                if depths[j] < depths[i] { break }
                if depths[j] == depths[i] { last[i] = false; break }
            }
        }
        // Whether each open level's row is its parent's last, outermost first.
        var stack: [Bool] = []
        return tree.indices.map { i in
            let d = max(1, depths[i])
            stack = Array(stack.prefix(d - 1))
            while stack.count < d - 1 { stack.append(true) }
            let lines = stack.map { $0 ? SubAgent.Line.blank : .pipe } + [last[i] ? .elbow : .tee]
            stack.append(last[i])
            return tree[i].with(lines: lines)
        }
    }

    /// The terminals whose `>_` chip can show (they started a terminal or report a
    /// background shell): an agent outside it has nothing to unfold, so its chip folds
    /// again (`WorkspaceController.openTerminals`).
    public static func owners(in terminals: [String: TerminalInfo]) -> Set<String> {
        var out: Set<String> = []
        for t in terminals.values where t.isLive {
            if !t.isAgent, let p = t.parent { out.insert(p) }
            if t.backgroundShells > 0 { out.insert(t.address) }
        }
        return out
    }
}

extension Array where Element == TreeNode {
    /// Whether rows hang under the `index`th row here (the next one is deeper).
    public func hasKids(at index: Int) -> Bool {
        index + 1 < count && self[index + 1].lines.count > self[index].lines.count
    }
}
