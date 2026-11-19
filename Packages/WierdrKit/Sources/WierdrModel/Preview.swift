import Foundation

/// A populated `Workspace` without a connection, for SwiftUI previews,
/// screenshots and the app's demo mode. Mirrors the user's real desktop, its titles in
/// English as the interface is (the tour is taken on it).
extension Workspace {
    public static func preview() -> Workspace {
        let ws = Workspace()
        ws.isLocal = true
        ws.phase = .live
        ws.home = "/Users/mentor"
        ws.machines = [Machine(name: nil, state: .ready, isConnected: true),
                       Machine(name: "lf", state: .ready, isConnected: true)]
        let now = Date()
        let pi = Program(key: "pi", name: "Pi", iconAsset: "program.pi", isAgent: true)
        let claude = Program(key: "claude", name: "Claude Code", iconAsset: "program.claude", tint: false, isAgent: true)
        let codex = Program(key: "codex", name: "Codex", iconAsset: "program.codex", tint: false, isAgent: true)
        let lazygit = Program(key: "lazygit", name: "lazygit", iconAsset: "program.lazygit", tile: "#3f8f4f")
        let zsh = Program(key: "shell", name: "zsh", iconAsset: "program.shell", tile: "#16241a", color: "#4ec95f", isShell: true)

        func meta(_ model: String, _ effort: String, _ ctx: Int, _ max: Int = 1_000_000, cacheLeft: TimeInterval = 120, subagents: Int = 0) -> AgentMeta {
            AgentMeta(provider: "anthropic", providerAsset: "provider.anthropic", model: model, effort: effort,
                      ctx: ctx, ctxMax: max, cacheUntil: now.addingTimeInterval(cacheLeft), cacheTTL: 300,
                      session: UUID().uuidString, subagents: subagents)
        }

        var terms: [TerminalInfo] = [
            TerminalInfo(address: "t5w", title: "π - wierdr", cwd: "/Users/mentor/me/dev/wierdr", processName: "pi",
                         program: pi, status: .working, state: "working", message: "Wierdr, an iPad app for herdr-core",
                         app: "pi", turn: 3, statusChangedAt: now.addingTimeInterval(-56),
                         meta: meta("Opus 5.5", "xhigh", 59_400, subagents: 1)),
            // t5w's sub-agents (hc run): a reviewer that started its own helper and a
            // test watcher, a dev server, and a scout waiting for an answer.
            TerminalInfo(address: "t5x", name: "reviewer", createdAt: now.addingTimeInterval(-600), title: "π - wierdr",
                         cwd: "/Users/mentor/me/dev/wierdr", processName: "pi", program: pi, status: .working,
                         state: "working", message: "Review the sub-agent tree", app: "pi", turn: 1,
                         statusChangedAt: now.addingTimeInterval(-42), parent: "t5w",
                         meta: AgentMeta(provider: "anthropic", providerAsset: "provider.anthropic", model: "Sonnet 5",
                                         effort: "medium", ctx: 18_200, ctxMax: 1_000_000,
                                         cacheUntil: now.addingTimeInterval(200), cacheTTL: 300)),
            TerminalInfo(address: "t5y", name: "tests", createdAt: now.addingTimeInterval(-300), title: "π - tests",
                         cwd: "/Users/mentor/me/dev/wierdr", processName: "pi", program: pi, status: .idle,
                         state: "done", message: "Run the model tests", app: "pi", turn: 1,
                         statusChangedAt: now.addingTimeInterval(-95), parent: "t5x",
                         meta: AgentMeta(provider: "openai", providerAsset: "provider.openai", model: "GPT 5.5",
                                         effort: "low", ctx: 7_400, ctxMax: 400_000)),
            TerminalInfo(address: "t5v", name: "swift test", createdAt: now.addingTimeInterval(-250), title: "zsh",
                         cwd: "/Users/mentor/me/dev/wierdr", processName: "swift", program: zsh, parent: "t5x"),
            TerminalInfo(address: "t5z", name: "vite", createdAt: now.addingTimeInterval(-500), title: "vite",
                         cwd: "/Users/mentor/me/dev/wierdr/site", processName: "node", program: Program(key: "vite", name: "Vite", iconAsset: "program.vite"),
                         parent: "t5w"),
            TerminalInfo(address: "t60", name: "scout", createdAt: now.addingTimeInterval(-200), title: "claude",
                         cwd: "/Users/mentor/me/dev/wierdr", processName: "claude", program: claude, status: .blocked,
                         state: "blocked", message: "Allow reading ~/.ssh/config?", app: "claude-code", turn: 1,
                         statusChangedAt: now.addingTimeInterval(-12), parent: "t5w"),
            TerminalInfo(address: "t6a", title: "π - herdr-app", cwd: "/Users/mentor/me/dev/herdr-app", processName: "pi",
                         program: pi, status: .idle, state: "idle", message: "Read the herdr mobile app's sources",
                         app: "pi", turn: 4, statusChangedAt: now.addingTimeInterval(-28 * 60),
                         labels: ["herdr.seen": "4"], meta: meta("Opus 5.5", "high", 49_700, cacheLeft: -10)),
            TerminalInfo(address: "t6b", title: "lazygit", cwd: "/Users/mentor/.local/share/chezmoi", processName: "lazygit",
                         program: lazygit),
            TerminalInfo(address: "t7a", title: "π - wierd-limits", cwd: "/Users/mentor/me/dev/wierd-limits", processName: "pi",
                         program: pi, status: .done, state: "idle", message: "Install the herdr mod from the repo",
                         app: "pi", turn: 2, statusChangedAt: now.addingTimeInterval(-3 * 3600),
                         meta: meta("Opus 5.5", "high", 22_800, cacheLeft: 20)),
            TerminalInfo(address: "t7b", title: "zsh", cwd: "/Users/mentor/me/dev/wierd-limits", processName: "zsh", program: zsh),
            // Claude Code with the cc@wierdr plugin: its session's title is the terminal's
            // (its `msg` a passing detail), `agent.*` as the plugin writes them (1 h cache),
            // and its background work as 7501 records: a sub-agent (its model, effort, context
            // and start from `agent.subagents_meta`) and a shell; and a teammate between turns,
            // which only `agent.subagents_meta` tells of (`StatusRecords.merge`).
            TerminalInfo(address: "t8a", title: "Dream jobs on the queue", cwd: "/Users/mentor/me/dev/memory",
                         processName: "claude", program: claude, status: .working, state: "working",
                         message: "1 shell still running", app: "claude-code", turn: 2,
                         statusChangedAt: now.addingTimeInterval(-3 * 60),
                         meta: AgentMeta(provider: "anthropic", providerAsset: "provider.anthropic", model: "Opus 5.5",
                                         effort: "high", ctx: 84_300, ctxMax: 200_000,
                                         cacheUntil: now.addingTimeInterval(52 * 60), cacheTTL: 3600,
                                         session: "5f0c2a41-7d3e-4b8a-9c61-2e8f4d1a7b30"),
                         records: [
                            TaskRecord(id: "a445e47c8be43ef46", app: "claude-code", state: "working",
                                       title: "Review the queue's retry logic",
                                       meta: AgentMeta(provider: "anthropic", providerAsset: "provider.anthropic",
                                                       model: "Haiku 5.5", effort: "medium", ctx: 31_200,
                                                       ctxMax: 1_000_000),
                                       startedAt: now.addingTimeInterval(-74)),
                            TaskRecord(id: "asleeper-0d1e2f3a4b5c6d7e", app: "claude-code", state: "idle",
                                       title: "Wait for the nightly build", kind: .agent,
                                       meta: AgentMeta(provider: "anthropic", providerAsset: "provider.anthropic",
                                                       model: "Sonnet 5.5", effort: "medium", ctx: 12_400,
                                                       ctxMax: 1_000_000),
                                       startedAt: now.addingTimeInterval(-20 * 60),
                                       statusSince: now.addingTimeInterval(-6 * 60), name: "sleeper"),
                            TaskRecord(id: "bcq5ektlx", app: "claude-code", state: "working",
                                       title: "Run the queue tests in watch mode"),
                         ]),
            // Codex with the codex@wierdr plugin: its window title is its thread's name and
            // its project's (Codex's own `tui.terminal_title`), its `agent.*` as the plugin
            // writes them, read as the engine reads them; it said idle after a turn
            // herdr-core counted (its launch, say) but nobody saw: idle all the same.
            TerminalInfo(address: "t9a", title: "Fix the login redirect | wierdr", cwd: "/Users/mentor/me/dev/wierdr",
                         processName: "codex", program: codex,
                         status: StatusRule.status(word: "idle", turn: 2, seenTurn: 1, locallySeen: false, app: "codex"),
                         state: "idle", app: "codex", turn: 2, statusChangedAt: now.addingTimeInterval(-9 * 60),
                         labels: ["herdr.seen": "1"],
                         meta: AgentLabels.meta(labels: [
                            "agent.app": "codex", "agent.pid": "48211", "agent.provider": "openai",
                            "agent.model": "GPT-6.1 Sol", "agent.model_id": "gpt-6.1-sol", "agent.effort": "high",
                            "agent.ctx": "61240", "agent.ctx_max": "258400",
                            "agent.session": "019a8f3e-5c2b-7d41-9e0a-3b6c1f2d4e58", "agent.subagents": "2",
                         ], foregroundPID: 48211)),
            TerminalInfo(address: "lf/t1", machine: "lf", title: "zsh", cwd: "/home/hcagent", processName: "zsh", program: zsh),
        ]
        terms = terms.map { t in
            var t = t
            t.pinned = false
            return t
        }
        ws.terminals = Dictionary(uniqueKeysWithValues: terms.map { ($0.address, $0) })

        func tab(_ space: String, _ id: String, _ index: Int, _ root: PaneNode, name: String = "") -> Tab {
            var t = Tab(id: id, spaceID: space, name: name, index: index, root: root)
            t.status = AgentStatus.rollup(t.panes.map { ws.terminals[$0.terminal ?? ""]?.status })
            return t
        }
        func pane(_ id: String, _ address: String) -> PaneNode { PaneNode(id: id, kind: .terminal(address)) }
        func space(_ id: String, _ name: String, _ folder: String, _ color: String, _ tabs: [Tab], machine: String? = nil, git: GitInfo? = nil) -> Space {
            Space(id: id, machine: machine, name: "", displayName: name, folder: folder, tabs: tabs,
                  status: AgentStatus.rollup(tabs.map(\.status)), git: git, color: color)
        }

        ws.spaces = [
            space("sp1", "wierdr", "/Users/mentor/me/dev/wierdr", "#22a99a",
                  [tab("sp1", "tb1", 0, PaneNode(id: "tb1", kind: .row([pane("p1", "t5w")]))),
                   tab("sp1", "tb7", 1, PaneNode(id: "tb7", kind: .row([pane("p8", "t9a")])))]),
            space("sp2", "herdr-app", "/Users/mentor/me/dev/herdr-app", "#e3814f",
                  [tab("sp2", "tb2", 0, PaneNode(id: "tb2", kind: .row([
                        PaneNode(id: "p2", kind: .terminal("t6a"), weight: 0.6),
                        PaneNode(id: "p3", kind: .terminal("t6b"), weight: 0.4)])))],
                  git: GitInfo(repo: "herdr-app", branch: "main", ahead: 1)),
            space("sp3", "wierd-limits", "/Users/mentor/me/dev/wierd-limits", "#5b8def",
                  [tab("sp3", "tb3", 0, PaneNode(id: "tb3", kind: .row([pane("p4", "t7a")]))),
                   tab("sp3", "tb4", 1, PaneNode(id: "tb4", kind: .row([pane("p5", "t7b")])), name: "shell")]),
            space("sp4", "memory", "/Users/mentor/me/dev/memory", "#8b7cf6",
                  [tab("sp4", "tb5", 0, PaneNode(id: "tb5", kind: .row([pane("p6", "t8a")])))],
                  git: GitInfo(repo: "wierd-mem", branch: "dream", behind: 2)),
            space("lf/sp5", "~", "", "#3fae6a",
                  [tab("lf/sp5", "lf/tb6", 0, PaneNode(id: "lf/tb6", kind: .row([pane("lf/p7", "lf/t1")])))], machine: "lf"),
        ]
        ws.launchers[""] = [
            AgentLauncher(program: claude, run: ["claude"], installed: true),
            AgentLauncher(program: Program(key: "codex", name: "Codex", iconAsset: "program.codex", tint: false, isAgent: true),
                          run: ["codex", "--no-daemon"], installed: true),
            AgentLauncher(program: pi, run: ["pi"], installed: true),
            AgentLauncher(program: Program(key: "opencode", name: "OpenCode", iconAsset: "program.opencode", isAgent: true),
                          run: ["opencode"], installed: false),
        ]
        func window(_ id: String, _ label: String, _ length: TimeInterval, used: Double, left: TimeInterval) -> LimitWindow {
            LimitWindow(id: id, label: label, length: length, used: used, resetsAt: now.addingTimeInterval(left), at: now)
        }
        ws.limits = [
            LimitAccount(id: "claude.849d2d8c", provider: "claude", account: "849d2d8c", status: "ok", binding: "5h", at: now,
                         host: "mentoair", windows: [window("5h", "5 hours", 18_000, used: 37, left: 16 * 60),
                                                     window("7d", "7 days", 604_800, used: 58, left: 40 * 3600),
                                                     window("7d_fable", "Fable", 604_800, used: 44, left: 5 * 86_400),
                                                     window("7d_oi", "7 days + extra", 604_800, used: 58, left: 40 * 3600)]),
            LimitAccount(id: "codex.d4800446", provider: "codex", account: "d4800446", label: "dev@example.com", plan: "plus",
                         at: now.addingTimeInterval(-3600),
                         windows: [window("5h", "5 hours", 18_000, used: 9, left: 3 * 3600 + 2 * 60),
                                   window("7d", "7 days", 604_800, used: 21, left: 4 * 86_400)]),
        ]
        return ws
    }
}
