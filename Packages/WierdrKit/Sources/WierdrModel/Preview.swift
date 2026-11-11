import Foundation

/// A populated `Workspace` without a connection, for SwiftUI previews,
/// screenshots and the app's demo mode. Mirrors the user's real desktop.
extension Workspace {
    public static func preview() -> Workspace {
        let ws = Workspace()
        ws.phase = .live
        ws.home = "/Users/mentor"
        ws.machines = [Machine(name: nil, state: .ready, isConnected: true),
                       Machine(name: "lf", state: .ready, isConnected: true)]
        let now = Date()
        let pi = Program(key: "pi", name: "Pi", iconAsset: "program.pi", isAgent: true)
        let claude = Program(key: "claude", name: "Claude Code", iconAsset: "program.claude", tint: false, isAgent: true)
        let lazygit = Program(key: "lazygit", name: "lazygit", iconAsset: "program.lazygit", tile: "#3f8f4f")
        let zsh = Program(key: "shell", name: "zsh", iconAsset: "program.shell", tile: "#16241a", color: "#4ec95f", isShell: true)

        func meta(_ model: String, _ effort: String, _ ctx: Int, _ max: Int = 1_000_000, cacheLeft: TimeInterval = 120, subagents: Int = 0) -> AgentMeta {
            AgentMeta(provider: "anthropic", providerAsset: "provider.anthropic", model: model, effort: effort,
                      ctx: ctx, ctxMax: max, cacheUntil: now.addingTimeInterval(cacheLeft), cacheTTL: 300,
                      session: UUID().uuidString, subagents: subagents)
        }

        var terms: [TerminalInfo] = [
            TerminalInfo(address: "t5w", title: "π - wierdr", cwd: "/Users/mentor/me/dev/wierdr", processName: "pi",
                         program: pi, status: .working, state: "working", message: "Wierdr iPad-приложение для herdr-core",
                         app: "pi", turn: 3, statusChangedAt: now.addingTimeInterval(-56),
                         meta: meta("Opus 5.5", "xhigh", 59_400, subagents: 2)),
            TerminalInfo(address: "t6a", title: "π - herdr-app", cwd: "/Users/mentor/me/dev/herdr-app", processName: "pi",
                         program: pi, status: .idle, state: "idle", message: "Исходники мобильного приложения herdr",
                         app: "pi", turn: 4, statusChangedAt: now.addingTimeInterval(-28 * 60),
                         labels: ["herdr.seen": "4"], meta: meta("Opus 5.5", "high", 49_700, cacheLeft: -10)),
            TerminalInfo(address: "t6b", title: "lazygit", cwd: "/Users/mentor/.local/share/chezmoi", processName: "lazygit",
                         program: lazygit),
            TerminalInfo(address: "t7a", title: "π - wierd-limits", cwd: "/Users/mentor/me/dev/wierd-limits", processName: "pi",
                         program: pi, status: .done, state: "idle", message: "Установка мода herdr из репозитория",
                         app: "pi", turn: 2, statusChangedAt: now.addingTimeInterval(-3 * 3600),
                         meta: meta("Opus 5.5", "high", 22_800, cacheLeft: 20)),
            TerminalInfo(address: "t7b", title: "zsh", cwd: "/Users/mentor/me/dev/wierd-limits", processName: "zsh", program: zsh),
            TerminalInfo(address: "t8a", title: "claude", cwd: "/Users/mentor/me/dev/memory", processName: "claude",
                         program: claude, status: .blocked, state: "blocked", message: "Allow edits to src/dream.ts?",
                         app: "claude", turn: 1, statusChangedAt: now.addingTimeInterval(-7 * 3600)),
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
                  [tab("sp1", "tb1", 0, PaneNode(id: "tb1", kind: .row([pane("p1", "t5w")])))]),
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
                                                     window("7d_oi", "7 days + extra", 604_800, used: 58, left: 40 * 3600)]),
            LimitAccount(id: "codex.d4800446", provider: "codex", account: "d4800446", label: "dev@example.com", plan: "plus",
                         at: now.addingTimeInterval(-3600),
                         windows: [window("5h", "5 hours", 18_000, used: 9, left: 3 * 3600 + 2 * 60),
                                   window("7d", "7 days", 604_800, used: 21, left: 4 * 86_400)]),
        ]
        return ws
    }
}
