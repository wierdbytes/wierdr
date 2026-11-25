import Foundation
import Testing
@testable import WierdrModel

/// The demo's workspace changes here (no herdr-core behind it): its agents at work
/// (`changeLocally`, the app's `DemoAgents`) and what's on screen seen at once.
@MainActor @Suite struct DemoTests {
    @Test func theDemoChangesItsTerminalsHere() {
        let ws = Workspace.preview()
        ws.changeLocally("t5w") { $0.status = .done; $0.turn += 1 }
        #expect(ws.terminal("t5w")?.status == .done)
        #expect(ws.terminal("t5w")?.turn == 4)
        // The sidebar's tree follows (its index is rebuilt).
        #expect(ws.subtree(of: "t5w").map(\.terminal.address).contains("t60"))
    }

    @Test func aLiveWorkspaceIsNotChangedHere() {
        let ws = Workspace()
        ws.terminals = ["t1": TerminalInfo(address: "t1", status: .idle)]
        ws.changeLocally("t1") { $0.status = .done }
        #expect(ws.terminal("t1")?.status == .idle)
    }

    @Test func whatTheDemoShowsIsSeenAtOnce() {
        let ws = Workspace.preview()
        #expect(ws.terminal("t7a")?.status == .done)
        ws.markSeen(["t7a", "t5w"])
        #expect(ws.terminal("t7a")?.status == .idle)
        // Only done turns idle: working, needing you stay.
        #expect(ws.terminal("t5w")?.status == .working)
        ws.markSeen(["t60"])
        #expect(ws.terminal("t60")?.status == .blocked)
    }

    /// As the engine's: a turn on screen is seen once, so Mark Unread on the agent in front
    /// sticks (its status changed, the screen is reported again); its next turn is seen.
    @Test func markedUnreadOnScreenStaysUnread() {
        let ws = Workspace.preview()
        ws.markSeen(["t7a"])
        #expect(ws.terminal("t7a")?.status == .idle)
        ws.markUnread("t7a")
        ws.markSeen(["t7a"])
        #expect(ws.terminal("t7a")?.status == .done)
        ws.changeLocally("t7a") { $0.status = .done; $0.turn += 1 }
        ws.markSeen(["t7a"])
        #expect(ws.terminal("t7a")?.status == .idle)
        // Off screen and back: seen again.
        ws.markUnread("t7a")
        ws.markSeen([])
        ws.markSeen(["t7a"])
        #expect(ws.terminal("t7a")?.status == .idle)
    }
}
