import Foundation
import HerdrCore
import Testing
@testable import WierdrModel

/// Codex (the OpenAI Codex CLI) as Wierdr shows it: its 7501 status (app `codex`, never a
/// `msg`), its window title (`tui.terminal_title`), the `agent.*` labels its plugin
/// (codex@wierdr) writes.
@Suite struct CodexTests {
    /// The plugin's labels (Codex 0.170.0).
    static let labels: [String: String] = [
        "agent.app": "codex", "agent.pid": "48211", "agent.provider": "openai",
        "agent.model": "GPT-6.1 Sol", "agent.model_id": "gpt-6.1-sol", "agent.effort": "high",
        "agent.ctx": "16356", "agent.ctx_max": "258400",
        "agent.session": "019a8f3e-5c2b-7d41-9e0a-3b6c1f2d4e58", "agent.subagents": "2",
    ]

    static let codex = Program(key: "codex", name: "Codex", iconAsset: "program.codex", tint: false, isAgent: true)

    // MARK: Status

    /// herdr-core's turn grows for Codex without a finished turn (its launch, `/new`, every
    /// approval): its `idle` is idle, only its `done` is done, while unseen.
    @Test func statusRule() {
        func codex(_ word: String, turn: UInt64, seen: UInt64?, locallySeen: Bool = false) -> AgentStatus? {
            StatusRule.status(word: word, turn: turn, seenTurn: seen, locallySeen: locallySeen, app: "codex")
        }
        // Freshly started: working → idle counted a turn; no seen label, or seen 0.
        #expect(codex("idle", turn: 1, seen: nil) == .idle)
        #expect(codex("idle", turn: 1, seen: 0) == .idle)
        #expect(codex("idle", turn: 7, seen: 2) == .idle)
        // A finished turn: done until seen.
        #expect(codex("done", turn: 2, seen: 1) == .done)
        #expect(codex("done", turn: 2, seen: 2) == .idle)
        #expect(codex("done", turn: 2, seen: 3) == .idle)
        #expect(codex("done", turn: 2, seen: nil, locallySeen: false) == .done)
        #expect(codex("done", turn: 2, seen: nil, locallySeen: true) == .idle)
        // Busy as everyone.
        #expect(codex("working", turn: 1, seen: 0) == .working)
        #expect(codex("blocked", turn: 3, seen: 0) == .blocked)
        #expect(codex("error", turn: 3, seen: 3) == .blocked)
        // pi, Claude Code, no app: unchanged, idle with an unseen turn is done.
        for app in ["pi", "claude-code", nil] as [String?] {
            #expect(StatusRule.status(word: "idle", turn: 1, seenTurn: 0, locallySeen: true, app: app) == .done)
            #expect(StatusRule.status(word: "idle", turn: 1, seenTurn: 1, locallySeen: false, app: app) == .idle)
            #expect(StatusRule.status(word: "idle", turn: 1, seenTurn: nil, locallySeen: false, app: app) == .done)
            #expect(StatusRule.status(word: "done", turn: 4, seenTurn: 3, locallySeen: true, app: app) == .done)
        }
        #expect(StatusRule.status(word: "idle", turn: 1, seenTurn: 0, locallySeen: true) == .done)
    }

    /// Through the deriver, so every place reading `TerminalInfo.status` (rows, the ring,
    /// the cards' badges, Go to, the banner, the back button's count, the Live Activity's
    /// pusher) gets the same.
    @Test func statusThroughTheDeriver() {
        let deriver = TerminalDeriver(prefix: "herdr")
        func info(_ word: String, app: String, turn: UInt64, seen: String?) -> TerminalInfo {
            var labels = Self.labels
            labels["agent.app"] = app
            if let seen { labels["herdr.seen"] = seen }
            let t = Fixture.terminal("t9", fg: ["codex", "--no-daemon"], fgName: "codex", cwd: "/Users/mentor/me/dev/wierdr",
                                     status: TerminalStatus(state: word, app: app), turn: turn, labels: labels, pid: 48211)
            return deriver.info(t, seenTurn: seen.flatMap { UInt64($0) }, locallySeen: false)
        }
        #expect(info("idle", app: "codex", turn: 1, seen: "0").status == .idle)
        #expect(info("idle", app: "codex", turn: 1, seen: nil).status == .idle)
        #expect(info("done", app: "codex", turn: 2, seen: "1").status == .done)
        #expect(info("done", app: "codex", turn: 2, seen: "2").status == .idle)
        #expect(info("idle", app: "pi", turn: 1, seen: "0").status == .done)
        let fresh = info("idle", app: "codex", turn: 1, seen: "0")
        #expect(fresh.program.key == "codex" && fresh.app == "codex" && fresh.state == "idle")
        // "Mark Unread" can't make an idle Codex done, so it isn't offered; its done can be.
        #expect(!fresh.canMarkUnread)
        #expect(info("done", app: "codex", turn: 2, seen: "2").canMarkUnread)
        #expect(info("idle", app: "pi", turn: 1, seen: "1").canMarkUnread)
        #expect(!info("done", app: "codex", turn: 2, seen: "1").canMarkUnread)  // done already
    }

    // MARK: Title

    @Test func titleCleaning() {
        let cwd = "/private/tmp/wierdrtest-codex"
        func clean(_ title: String, cwd: String? = cwd) -> String {
            AgentText.codexTitle(TerminalText.shownTitle(title), cwd: cwd)
        }
        // Live titles of Codex 0.170.0.
        #expect(clean("⠙ wierdrtest-codex") == "")
        #expect(clean("wierdrtest-codex") == "")
        #expect(clean("⠋ Spawn exactly one sub-agent with your spawn_a... | wierdrtest-codex")
                == "Spawn exactly one sub-agent with your spawn_a...")
        #expect(clean("Reply with exactly ok | wierdrtest-codex") == "Reply with exactly ok")
        // Waiting for you: the blinking prefix goes either way.
        #expect(clean("[ ! ] Action Required | Create approval marker | wierdrtest-codex") == "Create approval marker")
        #expect(clean("[ . ] Action Required | Create approval marker | wierdrtest-codex") == "Create approval marker")
        #expect(clean("[ ! ] Action Required | wierdrtest-codex") == "")
        #expect(clean("[ ! ] Action Required") == "")
        #expect(clean("● [ ! ] Action Required | Create approval marker | wierdrtest-codex") == "Create approval marker")
        // The project is the git root's (or the project's) folder: any folder the cwd is in.
        #expect(clean("Fix the login redirect | wierdr", cwd: "/Users/mentor/me/dev/wierdr/App/Sources") == "Fix the login redirect")
        #expect(clean("Fix the login redirect | wierdr", cwd: "/Users/mentor/me/dev/wierdr") == "Fix the login redirect")
        // Not the project's name: kept (a user's own items, another folder, no cwd).
        #expect(clean("Fix the login redirect | main", cwd: "/Users/mentor/me/dev/wierdr") == "Fix the login redirect | main")
        #expect(clean("Fix the login redirect | wierdr", cwd: "/Users/mentor/me/dev/other") == "Fix the login redirect | wierdr")
        #expect(clean("Fix the login redirect | wierdr", cwd: nil) == "Fix the login redirect | wierdr")
        #expect(clean("Fix the login redirect | main | wierdr", cwd: "/Users/mentor/me/dev/wierdr") == "Fix the login redirect | main")
        // A custom title without " | ": as it is.
        #expect(clean("Reply with exactly ok") == "Reply with exactly ok")
        #expect(clean("⠸ Working") == "Working")
        // Codex cuts the project's name at 24 characters: "..." after 21.
        let long = "/Users/mentor/me/dev/a-very-long-project-folder-name"
        #expect(clean("Tidy up | a-very-long-project-f...", cwd: long) == "Tidy up")
        #expect(clean("Tidy up | a-very-long-project-folder-name", cwd: long) == "Tidy up | a-very-long-project-folder-name")
        #expect(AgentText.isCodexProject("dev", cwd: "/Users/mentor/me/dev/wierdr"))
        #expect(!AgentText.isCodexProject("", cwd: "/"))
    }

    @Test func titleRule() {
        let pi = Program(key: "pi", name: "Pi", iconAsset: "program.pi", isAgent: true)
        let claude = Program(key: "claude", name: "Claude Code", iconAsset: "program.claude", tint: false, isAgent: true)
        func t(_ title: String, app: String = "codex", program: Program = Self.codex, status: AgentStatus = .idle,
               msg: String? = nil, cwd: String = "/Users/mentor/me/dev/wierdr") -> TerminalInfo {
            TerminalInfo(address: "t9", title: TerminalText.shownTitle(title), cwd: cwd, program: program, status: status,
                         state: status == .blocked ? "blocked" : "idle", message: msg, app: app)
        }
        let named = Tab(id: "tb", spaceID: "sp", name: "login", index: 0, root: PaneNode(id: "tb", kind: .row([])))
        let unnamed = Tab(id: "tb", spaceID: "sp", name: "", index: 0, root: PaneNode(id: "tb", kind: .row([])))
        // The thread's name.
        #expect(AgentText.title(t("Fix the login redirect | wierdr"), tab: nil) == "Fix the login redirect")
        #expect(AgentText.title(t("⠙ Fix the login redirect | wierdr", status: .working), tab: unnamed) == "Fix the login redirect")
        #expect(AgentText.title(t("[ ! ] Action Required | Create approval marker | wierdr", status: .blocked), tab: nil)
                == "Create approval marker")
        // Only the project: the tab's name if it has one, else "Codex".
        #expect(AgentText.title(t("⠙ wierdr", status: .working), tab: nil) == "Codex")
        #expect(AgentText.title(t("wierdr"), tab: unnamed) == "Codex")
        #expect(AgentText.title(t("wierdr"), tab: named) == "login")
        #expect(AgentText.title(t("[ . ] Action Required | wierdr", status: .blocked), tab: nil) == "Codex")
        #expect(AgentText.title(t(""), tab: nil) == "Codex")
        // A named tab first, as for every app without a message.
        #expect(AgentText.title(t("Fix the login redirect | wierdr"), tab: named) == "login")
        // Sub-agent rows (a Codex started under another agent with `hc run`): the same.
        var kid = t("Reply with exactly ok | wierdr")
        kid.name = "helper"
        #expect(AgentText.kidTitle(kid) == "Reply with exactly ok")
        kid.title = "wierdr"
        #expect(AgentText.kidTitle(kid) == "helper")
        #expect(AgentText.kidTitle(kid, plain: true) == "helper")
        // pi and Claude Code are cut nowhere.
        #expect(AgentText.title(t("π - wierdr", app: "pi", program: pi, msg: "Session"), tab: nil) == "Session")
        #expect(AgentText.title(t("Ok reply test | wierdr", app: "pi", program: pi), tab: nil) == "Ok reply test | wierdr")
        #expect(AgentText.title(t("Ok reply test | wierdr", app: "claude-code", program: claude), tab: nil) == "Ok reply test | wierdr")
        #expect(AgentText.title(t("wierdr", app: "claude-code", program: claude), tab: nil) == "wierdr")
        var piKid = t("Ok | wierdr", app: "pi", program: pi)
        piKid.name = "helper"
        #expect(AgentText.kidTitle(piKid) == "Ok | wierdr")
    }

    // MARK: Labels

    @Test func labelsThroughAgentMeta() throws {
        let meta = try #require(AgentLabels.meta(labels: Self.labels, foregroundPID: 48211))
        #expect(meta.provider == "openai" && meta.providerAsset == "provider.openai")
        #expect(meta.model == "6.1 Sol" && meta.effort == "high")
        #expect(meta.ctx == 16_356 && meta.ctxMax == 258_400)
        #expect(meta.cacheUntil == nil && meta.cacheTTL == nil)
        #expect(meta.session == "019a8f3e-5c2b-7d41-9e0a-3b6c1f2d4e58" && meta.subagents == 2)
        #expect(AgentLabels.shortModel("GPT-6 Luna", mark: "openai") == "6 Luna")
        #expect(AgentLabels.shortModel("GPT-6.1 Sol", mark: nil) == "GPT-6.1 Sol")
        for effort in ["none", "minimal", "low", "medium", "xhigh", "max", "ultra"] {
            var l = Self.labels
            l["agent.effort"] = effort
            #expect(AgentLabels.meta(labels: l, foregroundPID: 48211)?.effort == effort)
        }
        // The pid is the TUI's, the terminal's foreground: Codex gone, the labels are stale.
        #expect(AgentLabels.meta(labels: Self.labels, foregroundPID: 70001) == nil)
        let deriver = TerminalDeriver(prefix: "herdr")
        let t = Fixture.terminal("t9", fg: ["codex", "--no-daemon"], fgName: "codex",
                                 status: TerminalStatus(state: "working", app: "codex"), labels: Self.labels, pid: 48211)
        let info = deriver.info(t, seenTurn: nil, locallySeen: true)
        #expect(info.program.key == "codex" && info.meta?.model == "6.1 Sol" && info.inProcessAgents == 2)
        #expect(info.records.isEmpty)
    }

    // MARK: Demo

    @MainActor @Test func previewHasACodex() throws {
        let ws = Workspace.preview()
        let t = try #require(ws.terminal("t9a"))
        #expect(t.app == "codex" && t.program.key == "codex")
        #expect(t.meta?.model == "6.1 Sol" && t.meta?.effort == "high" && t.meta?.providerAsset == "provider.openai")
        #expect(t.meta?.subagents == 2 && t.meta?.ctxMax == 258_400)
        // Idle with an unseen turn: idle.
        #expect(t.state == "idle" && t.turn > Int(t.labels["herdr.seen"] ?? "0")! && t.status == .idle)
        #expect(AgentText.title(t, tab: nil) == "Fix the login redirect")
        #expect(!t.canMarkUnread)
        let row = try #require(ws.sidebarRows(for: ws.spaces[0]).first { $0.terminal?.address == "t9a" })
        #expect(row.kidCounts.inProcess == 2)
        ws.markUnread("t9a")
        #expect(ws.terminal("t9a")?.status == .idle)
    }
}
