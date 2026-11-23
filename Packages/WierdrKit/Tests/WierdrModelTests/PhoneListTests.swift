import Foundation
import Testing
@testable import WierdrModel

/// The iPhone's list: Telegram's order (pins on top, newest pin first, then the
/// latest status change), every space on "All", a space's terminals after its agents.
@MainActor @Suite struct PhoneListTests {
    let now = Date(timeIntervalSince1970: 1_763_130_000)

    func agent(_ a: String, _ s: AgentStatus, ago: TimeInterval, parent: String? = nil,
               pinned: Bool = false, pinnedAgo: TimeInterval? = nil) -> TerminalInfo {
        TerminalInfo(address: a, createdAt: now.addingTimeInterval(-1000), status: s, state: "x",
                     statusChangedAt: now.addingTimeInterval(-ago), parent: parent, pinned: pinned,
                     pinnedAt: pinnedAgo.map { now.addingTimeInterval(-$0) })
    }

    func pane(_ id: String, _ a: String) -> PaneNode { PaneNode(id: id, kind: .terminal(a)) }

    func tab(_ space: String, _ id: String, _ panes: [PaneNode]) -> Tab {
        Tab(id: id, spaceID: space, name: "", index: 0, root: PaneNode(id: id, kind: .row(panes)))
    }

    func workspace() -> Workspace {
        let ws = Workspace()
        let terms: [TerminalInfo] = [
            agent("a1", .blocked, ago: 500),
            agent("a2", .idle, ago: 10),
            // a3 is older itself, but its sub-agent changed 5 s ago.
            agent("a3", .working, ago: 900), agent("k1", .working, ago: 5, parent: "a3"),
            agent("b1", .done, ago: 50),
            // Pins: b2 newest (1 min ago), a4 an hour ago, b3 and a5 the desktop's (no time).
            agent("b2", .idle, ago: 9999, pinned: true, pinnedAgo: 60),
            agent("a4", .working, ago: 1, pinned: true, pinnedAgo: 3600),
            agent("b3", .idle, ago: 1, pinned: true),
            agent("a5", .done, ago: 2, pinned: true),
            TerminalInfo(address: "s1"), TerminalInfo(address: "s2"),
        ]
        ws.terminals = Dictionary(uniqueKeysWithValues: terms.map { ($0.address, $0) })
        ws.spaces = [
            Space(id: "spA", machine: nil, name: "", displayName: "A", folder: "", tabs: [
                tab("spA", "tA1", [pane("pa1", "a1"), pane("ps1", "s1")]),
                tab("spA", "tA2", [pane("pa2", "a2"), pane("pa3", "a3")]),
                tab("spA", "tA3", [pane("pa4", "a4"), pane("pa5", "a5"), PaneNode(id: "pm", kind: .mod("markdown"))]),
            ]),
            Space(id: "spB", machine: "lf", name: "", displayName: "B", folder: "", tabs: [
                tab("spB", "tB1", [pane("ps2", "s2")]),
                tab("spB", "tB2", [pane("pb1", "b1"), pane("pb2", "b2"), pane("pb3", "b3")]),
            ]),
        ]
        return ws
    }

    @Test func allIsEveryAgentPinnedFirstThenNewest() {
        let page = workspace().phoneList(space: nil)
        #expect(page.agents.map(\.row.paneID) == ["pb2", "pa4", "pa5", "pb3", "pa3", "pa2", "pb1", "pa1"])
        #expect(page.others.isEmpty)
        #expect(page.agents.first?.space.id == "spB" && page.agents.last?.space.id == "spA")
        // Sub-agents ride along with their agent, not rows of their own.
        #expect(page.agents.first { $0.row.paneID == "pa3" }?.row.subtree.map(\.terminal.address) == ["k1"])
    }

    /// The agents panel: by status (an agent's own or its sub-agents'), pinned first in each,
    /// then the newest; the inbox's groups in one list.
    @Test func agentsByStatusIsTheInboxsOrder() {
        let ws = workspace()
        #expect(ws.agentsByStatus.map(\.row.paneID) == ["pa1", "pa5", "pb1", "pa4", "pa3", "pb3", "pb2", "pa2"])
        #expect(ws.inbox.flatMap(\.items).map(\.row.paneID) == ws.agentsByStatus.map(\.row.paneID))
        // A sub-agent's status lifts its agent: a2 waits for you through its own.
        ws.terminals["k2"] = agent("k2", .blocked, ago: 1, parent: "a2")
        #expect(ws.agentsByStatus.map(\.row.paneID).prefix(2) == ["pa2", "pa1"])
    }

    @Test func aSpaceIsItsAgentsThenItsOtherPanes() {
        let ws = workspace()
        let a = ws.phoneList(space: "spA")
        #expect(a.agents.map(\.row.paneID) == ["pa4", "pa5", "pa3", "pa2", "pa1"])
        // Its sidebar order: tA3's mod (its tab has agents, newest first), then tA1's terminal.
        #expect(a.others.map(\.row.paneID) == ["pm", "ps1"])
        #expect(a.others.map(\.row.kind) == [.mod, .terminal])
        let b = ws.phoneList(space: "spB")
        #expect(b.agents.map(\.row.paneID) == ["pb2", "pb3", "pb1"])
        #expect(b.others.map(\.row.paneID) == ["ps2"])
        #expect(ws.phoneList(space: "nope").isEmpty)
    }

    @Test func aNewPinGoesOnTopAndUnpinnedGoesBackToItsPlace() {
        let ws = workspace()
        ws.terminals["a1"]?.pinned = true
        ws.terminals["a1"]?.pinnedAt = now
        #expect(ws.phoneList(space: nil).agents.map(\.row.paneID).prefix(5) == ["pa1", "pb2", "pa4", "pa5", "pb3"])
        ws.terminals["b2"]?.pinned = false
        ws.terminals["b2"]?.pinnedAt = nil
        #expect(ws.phoneList(space: nil).agents.map(\.row.paneID) == ["pa1", "pa4", "pa5", "pb3", "pa3", "pa2", "pb1", "pb2"])
    }

    @Test func theDemoPinsAndMarksLocally() {
        let ws = Workspace.preview()
        ws.setPinned("t7a", true)
        #expect(ws.terminal("t7a")?.pinned == true && ws.terminal("t7a")?.pinnedAt != nil)
        #expect(ws.phoneList(space: nil).agents.first?.row.terminal?.address == "t7a")
        ws.setPinned("t7a", false)
        #expect(ws.terminal("t7a")?.pinned == false && ws.terminal("t7a")?.pinnedAt == nil)
        ws.markRead("t7a")
        #expect(ws.terminal("t7a")?.status == .idle)
        ws.markUnread("t7a")
        #expect(ws.terminal("t7a")?.status == .done)
        ws.markUnread("t5w")  // working: no change
        #expect(ws.terminal("t5w")?.status == .working)
    }

    @Test func pinTimes() {
        #expect(TerminalDeriver.pinTime("1763130000") == Date(timeIntervalSince1970: 1_763_130_000))
        #expect(TerminalDeriver.pinTime("1") == nil)
        #expect(TerminalDeriver.pinTime("yes") == nil)
        #expect(TerminalDeriver.pinTime("") == nil && TerminalDeriver.pinTime(nil) == nil)
    }
}
