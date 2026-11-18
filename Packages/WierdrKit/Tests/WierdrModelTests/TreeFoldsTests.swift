import Foundation
import Testing
@testable import WierdrModel

/// An agent's tree folding: its sub-agents by the bot chip, each agent's terminals by its
/// own `>_` chip, the lines drawn afresh for what shows.
@Suite struct TreeFoldsTests {
    /// a (agent row) started s (sub-agent) and v (a plain terminal), and reports a shell; s
    /// started g (its own sub-agent) and w (a terminal), w started n (a terminal in it).
    @MainActor static func workspace() -> Workspace {
        let now = Date()
        func t(_ address: String, _ age: TimeInterval, agent: Bool, parent: String? = nil,
               records: [TaskRecord] = []) -> TerminalInfo {
            TerminalInfo(address: address, createdAt: now.addingTimeInterval(-age),
                         status: agent ? .working : nil, state: agent ? "working" : nil,
                         app: agent ? "claude-code" : nil, parent: parent, records: records)
        }
        let shell = TaskRecord(id: "bcq5ektlx", app: "claude-code", state: "working", title: "watch")
        let terms = [
            t("a", 0, agent: true, records: [shell]),
            t("s", 50, agent: true, parent: "a"),
            t("g", 40, agent: true, parent: "s"),
            t("w", 30, agent: false, parent: "s"),
            t("n", 20, agent: false, parent: "w"),
            t("v", 10, agent: false, parent: "a"),
        ]
        let ws = Workspace()
        ws.spaces = [Space(id: "sp", machine: nil, name: "", displayName: "x", folder: "",
                           tabs: [Tab(id: "tb", spaceID: "sp", name: "", index: 0,
                                      root: PaneNode(id: "tb", kind: .row([PaneNode(id: "pa", kind: .terminal("a"))])))])]
        ws.terminals = Dictionary(uniqueKeysWithValues: terms.map { ($0.address, $0) })
        return ws
    }

    @MainActor @Test func terminalsCountOnTheAgentThatStartedThem() {
        let row = Self.workspace().sidebarRows(for: Self.workspace().spaces[0])[0]
        #expect(row.tree.map(\.id) == ["kid:s", "kid:g", "kid:w", "kid:n", "kid:v", "record:a#bcq5ektlx"])
        #expect(TreeFolds.chipOwners(row.tree) == [nil, nil, "s", "s", "a", "a"])
        // The row's >_: v and its shell; s's: w and the terminal w started.
        #expect(row.kidCounts.terminals == 1 && row.kidCounts.shells == 1 && row.kidCounts.agents == 2)
        #expect(TreeFolds.terminals(of: "s", in: row.tree) == TerminalTally(terminals: 2))
        #expect(TreeFolds.terminals(of: "g", in: row.tree).total == 0)
    }

    @MainActor @Test func foldsAndLines() {
        let ws = Self.workspace()
        let tree = ws.sidebarRows(for: ws.spaces[0])[0].tree
        // Terminals folded (as they start), sub-agents open.
        let start = TreeFolds.shown(tree, agentsOpen: true, terminalsOpen: { _ in false })
        #expect(start.map(\.id) == ["kid:s", "kid:g"])
        #expect(start.map(\.lines) == [[.elbow], [.blank, .elbow]])
        // s's terminals open: w and what it started under s, after g.
        let s = TreeFolds.shown(tree, agentsOpen: true, terminalsOpen: { $0 == "s" })
        #expect(s.map(\.id) == ["kid:s", "kid:g", "kid:w", "kid:n"])
        #expect(s.map(\.lines) == [[.elbow], [.blank, .tee], [.blank, .elbow], [.blank, .blank, .elbow]])
        // The row's terminals open, sub-agents folded: s's go with s.
        let a = TreeFolds.shown(tree, agentsOpen: false, terminalsOpen: { _ in true })
        #expect(a.map(\.id) == ["kid:v", "record:a#bcq5ektlx"])
        #expect(a.map(\.lines) == [[.tee], [.elbow]])
        // Everything open: as the tree is.
        #expect(TreeFolds.shown(tree, agentsOpen: true, terminalsOpen: { _ in true }) == tree)
        // A match shows with the rows it hangs under, whatever the folds.
        let found = TreeFolds.shown(tree, agentsOpen: false, terminalsOpen: { _ in false }, forced: ["kid:n"])
        #expect(found.map(\.id) == ["kid:s", "kid:w", "kid:n"])
        #expect(found.map(\.lines) == [[.elbow], [.blank, .elbow], [.blank, .blank, .elbow]])
    }

    @MainActor @Test func ownersAreTheTerminalsWithTerminals() {
        let ws = Self.workspace()
        #expect(TreeFolds.owners(in: ws.terminals) == ["a", "s", "w"])
        ws.terminals["v"]?.isLive = false
        ws.terminals["a"]?.records = []
        #expect(TreeFolds.owners(in: ws.terminals) == ["s", "w"])
    }
}
