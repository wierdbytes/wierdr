import Foundation
import HerdrCore
import Testing
@testable import WierdrModel

@Suite struct ProgramTests {
    let table = ProgramTable.builtIn

    @Test func tableLoadsFromTheBundle() {
        #expect(table.programs.count == 122)
        #expect(table.shells.contains("zsh") && table.interpreters.contains("node"))
    }

    @Test func agentsShellsToolsAndWhatInterpretersRun() {
        func key(_ app: String?, _ argv: [String]) -> String { table.resolve(app: app, argv: argv).key }
        let claude = table.resolve(app: nil, argv: ["claude"])
        #expect(claude == Program(key: "claude", name: "Claude Code", iconAsset: "program.claude", tint: false,
                                  tile: "#1c1d21", color: "#ffffff", isShell: false, isAgent: false))
        let pi = table.resolve(app: "pi", argv: ["pi", ""])
        #expect(pi.key == "pi" && pi.isAgent && pi.name == "Pi" && pi.iconAsset == "program.pi" && pi.tint)
        #expect(key("claude-code", ["/bin/zsh"]) == "claude")
        let unknownAgent = table.resolve(app: "newagent", argv: [])
        #expect(unknownAgent.key == "agent" && unknownAgent.name == "newagent" && unknownAgent.isAgent)
        #expect(key(nil, ["zsh", "-ic", "\"$@\"", "zsh", "claude"]) == "claude")
        #expect(key(nil, ["/bin/zsh", "-lic", "\"$@\"; exec \"$0\" -li", "/bin/zsh", "codex", "--no-daemon"]) == "codex")
        #expect(key(nil, LaunchArgv.agent(["codex", "--no-daemon"], task: "fix it")) == "codex")
        #expect(key(nil, ["node", "/x/node_modules/.bin/vite", "dev"]) == "vite")
        #expect(key(nil, ["npx", "vitest"]) == "vitest")
        #expect(key(nil, ["node", "server.js"]) == "node")
        #expect(key(nil, ["python3", "-m", "http.server"]) == "python")
        #expect(key(nil, ["uv", "run", "pytest"]) == "pytest")
        let lazygit = table.resolve(app: nil, argv: ["lazygit"])
        #expect(lazygit.key == "lazygit" && lazygit.name == "Git Changes" && lazygit.iconAsset == "program.lazygit")
        #expect(key(nil, ["tig"]) == "lazygit")
        #expect(key(nil, ["vi"]) == "vim")
        let zsh = table.resolve(app: nil, argv: ["-zsh"])
        #expect(zsh.key == "shell" && zsh.name == "zsh" && zsh.isShell && zsh.iconAsset == "program.shell")
        #expect(table.resolve(app: nil, argv: []).name == "Shell")
        let unknown = table.resolve(app: nil, argv: ["/usr/local/bin/mytool", "x"])
        #expect(unknown.key == "program" && unknown.name == "mytool" && unknown.tile == "#3a7d44" && unknown.color == "#ffffff")
        #expect(unknown.iconAsset == "program.program")
        #expect(table.resolve(app: nil, argv: ["caffeinate", "-dimsu"]).tile == "#2f80ed")
        #expect(table.resolve(app: nil, argv: ["R"]).iconAsset == "program.r")
        let line = "& 'codex' 'fix it'"
        #expect(key(nil, ["pwsh.exe", "-NoExit", "-Command", line]) == "codex")
    }

    @Test func startableAgentsInMenuOrder() {
        let keys = table.startable.map(\.program.key)
        #expect(Array(keys.prefix(9)) == ProgramTable.agentsFirst)
        #expect(keys.count == 17)
        #expect(Array(keys.dropFirst(9)) == Array(keys.dropFirst(9)).sorted())
        #expect(table.startable[1].run == ["codex", "--no-daemon"])
    }
}

@Suite struct TerminalFactsTests {
    @Test(arguments: [
        ("⠹ Building", "Building"),
        ("✳ Claude Code", "Claude Code"),
        ("◐ working on it", "working on it"),
        ("π ⠹ task name", "π task name"),
        ("π ⠹", "π"),
        ("✓ build", "✓ build"),
        ("plain title", "plain title"),
        ("⠹", "⠹"),
        ("", ""),
        ("abcd ⠹ x", "abcd ⠹ x"),
    ])
    func shownTitle(_ input: String, _ expected: String) {
        #expect(TerminalText.shownTitle(input) == expected)
    }

    @Test func modelShortening() {
        #expect(AgentLabels.shortModel("Claude Opus 5.5", mark: "anthropic") == "Opus 5.5")
        #expect(AgentLabels.shortModel("Anthropic: Claude Opus 4.8", mark: "openrouter") == "Claude Opus 4.8")
        #expect(AgentLabels.shortModel("anthropic/claude-fable-5", mark: "anthropic") == "fable-5")
        #expect(AgentLabels.shortModel("GPT-5.2 Codex", mark: "openai") == "5.2 Codex")
        #expect(AgentLabels.shortModel("Kimi K2", mark: "moonshot") == "K2")
        #expect(AgentLabels.shortModel("Claude", mark: "anthropic") == "Claude")
        #expect(AgentLabels.shortModel("  Gemini 3 Pro ", mark: "google") == "Gemini 3 Pro")
    }

    @Test func providerMarks() {
        #expect(AgentLabels.mark(provider: "anthropic") == "anthropic")
        #expect(AgentLabels.mark(provider: "openai-codex") == "openai")
        #expect(AgentLabels.mark(provider: "ChatGPT") == "openai")
        #expect(AgentLabels.mark(provider: "google-vertex") == "google")
        #expect(AgentLabels.mark(provider: "vertex") == "google")
        #expect(AgentLabels.mark(provider: "github-copilot") == "github-copilot")
        #expect(AgentLabels.mark(provider: "amazon-bedrock") == "aws")
        #expect(AgentLabels.mark(provider: "lmstudio") == "lm-studio")
        #expect(AgentLabels.mark(provider: "acme") == nil)
        #expect(AgentLabels.mark(provider: nil) == nil)
        #expect(AgentLabels.providers.allSatisfy { AgentLabels.shippedMarks.contains($0.mark) })
    }

    @Test func agentMetaTrustRule() throws {
        let labels = ["agent.app": "pi", "agent.pid": "55908", "agent.provider": "anthropic", "agent.model": "Claude Opus 5.5",
                      "agent.effort": "xhigh", "agent.ctx": "102488", "agent.ctx_max": "1000000",
                      "agent.cache_until": "1794352397764", "agent.cache_ttl": "300000", "agent.subagents": "2",
                      "agent.session": "01a1"]
        let meta = try #require(AgentLabels.meta(labels: labels, foregroundPID: 55908))
        #expect(meta.provider == "anthropic" && meta.providerAsset == "provider.anthropic")
        #expect(meta.model == "Opus 5.5" && meta.effort == "xhigh" && meta.ctx == 102_488 && meta.ctxMax == 1_000_000)
        #expect(meta.cacheUntil == Date(timeIntervalSince1970: 1_794_352_397.764) && meta.cacheTTL == 300)
        #expect(meta.subagents == 2 && meta.session == "01a1")
        #expect(AgentLabels.meta(labels: labels, foregroundPID: 1234) == nil)  // a dead pi's labels
        #expect(AgentLabels.meta(labels: labels, foregroundPID: nil) != nil)
        #expect(AgentLabels.meta(labels: ["agent.model": "x"], foregroundPID: nil) == nil)
    }

    @Test func statusRules() {
        func s(_ word: String?, turn: UInt64 = 3, seen: UInt64? = nil, local: Bool = true) -> AgentStatus? {
            StatusRule.status(word: word, turn: turn, seenTurn: seen, locallySeen: local)
        }
        #expect(s(nil) == nil)
        #expect(s("working") == .working)
        #expect(s("blocked") == .blocked && s("error") == .blocked)
        #expect(s("idle", seen: 2) == .done)
        #expect(s("done", seen: 3) == .idle)
        #expect(s("idle", seen: 4) == .idle)
        #expect(s("idle", local: false) == .done && s("idle", local: true) == .idle)
    }

    @Test func derivedTerminal() {
        let deriver = TerminalDeriver(prefix: "herdr")
        let pi = Fixture.terminal("lf/t5", fg: ["pi", ""], fgName: "node", cwd: "/home/x/dev",
                                  status: TerminalStatus(state: "idle", app: "pi", msg: "Session"), turn: 3,
                                  labels: ["herdr.space": "spA", "herdr.tab": "tbA", "herdr.seen": "2", "herdr.pinned": "1",
                                           "agent.app": "pi", "agent.pid": "100"],
                                  parent: "lf/t1")
        let info = deriver.info(pi, seenTurn: deriver.seenLabel(pi), locallySeen: true)
        #expect(info.machine == "lf" && info.spaceID == "lf/spA" && info.tabID == "lf/tbA")
        #expect(info.status == .done && info.state == "idle" && info.message == "Session" && info.turn == 3)
        #expect(info.program.key == "pi" && info.processName == "pi" && info.cwd == "/home/x/dev")
        #expect(info.pinned && info.meta != nil && info.parent == "lf/t1")
        let shell = Fixture.terminal("t9", fg: ["-zsh"], fgName: "zsh")
        let s = deriver.info(shell, seenTurn: nil, locallySeen: true)
        #expect(s.status == nil && s.processName == "zsh" && s.program.isShell && !s.pinned && s.spaceID == nil)
        // Another prefix ignores herdr.* labels (tests never get adopted by the desktop).
        let other = TerminalDeriver(prefix: "wierdrtest").info(pi, seenTurn: nil, locallySeen: true)
        #expect(other.spaceID == nil && !other.pinned)
    }

    @Test func folderNames() {
        #expect(SpaceNaming.folderName("/Users/mentor/me/dev/wierdr", home: "/Users/mentor") == "wierdr")
        #expect(SpaceNaming.folderName("/Users/mentor/me/dev/wierdr/", home: "/Users/mentor") == "wierdr")
        #expect(SpaceNaming.folderName("/Users/mentor", home: "/Users/mentor/") == "~")
        #expect(SpaceNaming.folderName("", home: "/Users/mentor") == "~")
        #expect(SpaceNaming.folderName("/", home: "/Users/mentor") == "/")
        #expect(SpaceNaming.folderName("/home/hcagent", home: "/Users/mentor") == "hcagent")
    }

    @Test func spaceColors() {
        let spaces = [("a", "x"), ("b", "y"), ("c", "~"), ("d", "z"), ("e", "w")]
        let colors = SpaceNaming.colors(for: spaces.map { (id: $0.0, name: $0.1) },
                                        shared: ["a": "ansi6", "b": "#123456", "gone": "ansi3"])
        #expect(colors["a"] == "#22a99a")
        #expect(colors["b"] == "#123456")
        #expect(colors["c"] == "#22a99a")  // `~`: ansi6
        #expect(colors["d"] == "#e3814f")  // least used: ansi3 (the gone space's entry doesn't count)
        #expect(colors["e"] == "#5b8def")  // then ansi4
    }

    @Test func launchArgvMatchesHerdr() {
        let argv = LaunchArgv.agent(["codex", "--no-daemon"], task: "  fix it  ")
        #expect(Array(argv.prefix(2)) == ["sh", "-c"] && argv[3] == "sh")
        #expect(Array(argv[4...]) == ["codex", "--no-daemon", "fix it"])
        #expect(argv[2] == """
            shell=${SHELL:-/bin/sh}
            case "${shell##*/}" in
              fish) exec "$shell" -lic 'command $argv[2..]; exec $argv[1] -li' "$shell" "$@" ;;
              sh|bash|zsh|dash|ksh) exec "$shell" -lic '"$@"; exec "$0" -li' "$shell" "$@" ;;
              *) exec sh -c '"$@"; exec "${SHELL:-sh}" -i' sh "$@" ;;
            esac
            """)
        #expect(LaunchArgv.agent(["pi"], task: "") == Array(LaunchArgv.agent(["pi"], task: nil)))
        #expect(LaunchArgv.installed(["claude", "pi", "codex"], output: "hi\nherdr-has:claude\nherdr-has:pi\n\nherdr-check-complete\n", code: 0) == ["claude", "pi"])
        #expect(LaunchArgv.installed(["claude"], output: "herdr-has:claude\n", code: 0) == nil)
        #expect(LaunchArgv.installed(["claude"], output: "herdr-check-complete\n", code: 1) == nil)
    }

    #if os(macOS)
    @Test func launchArgvRunsInAShell() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wierdr-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func run(_ argv: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = Array(argv.dropFirst())
            p.environment = ["HOME": home.path, "SHELL": "/bin/bash", "PATH": "/usr/bin:/bin", "TERM": "dumb"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            p.standardInput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let out = try run(LaunchArgv.agent(["/usr/bin/printf", "<%s>"], task: "a 'quoted' $(task)"))
        #expect(out.contains("<a 'quoted' $(task)>"))
        let check = try run(LaunchArgv.check(["printf", "wierdr-missing-command"]))
        #expect(LaunchArgv.installed(["printf", "wierdr-missing-command"], output: check, code: 0) == ["printf"])
    }
    #endif
}

@Suite struct SidebarTests {
    @Test func agentsFirstThenTerminals() {
        let now = Date()
        func agent(_ a: String, _ s: AgentStatus, ago: TimeInterval, pinned: Bool = false) -> TerminalInfo {
            TerminalInfo(address: a, status: s, state: "x", statusChangedAt: now.addingTimeInterval(-ago), pinned: pinned)
        }
        let terms: [String: TerminalInfo] = [
            "a1": agent("a1", .idle, ago: 1), "a2": agent("a2", .blocked, ago: 100), "a3": agent("a3", .working, ago: 5),
            "a4": agent("a4", .working, ago: 50), "a5": agent("a5", .idle, ago: 999, pinned: true),
            "s1": TerminalInfo(address: "s1"), "s2": TerminalInfo(address: "s2"),
        ]
        func pane(_ id: String, _ a: String) -> PaneNode { PaneNode(id: id, kind: .terminal(a)) }
        let tabs = [
            Tab(id: "t1", spaceID: "sp", name: "", index: 0, root: PaneNode(id: "t1", kind: .row([pane("p1", "s1")]))),
            Tab(id: "t2", spaceID: "sp", name: "", index: 1, root: PaneNode(id: "t2", kind: .row([pane("p2", "a1"), pane("p3", "s2"), pane("p4", "a3")]))),
            Tab(id: "t3", spaceID: "sp", name: "", index: 2, root: PaneNode(id: "t3", kind: .row([pane("p5", "a4"), pane("p6", "a2")]))),
            Tab(id: "t4", spaceID: "sp", name: "", index: 3, root: PaneNode(id: "t4", kind: .row([pane("p7", "a5"), PaneNode(id: "p8", kind: .mod("markdown"))]))),
        ]
        let space = Space(id: "sp", machine: nil, name: "", displayName: "x", folder: "", tabs: tabs)
        let rows = SidebarOrder.rows(for: space, terminals: terms)
        #expect(rows.map(\.paneID) == ["p7", "p8", "p6", "p5", "p4", "p2", "p3", "p1"])
        #expect(rows.map(\.kind) == [.agent, .mod, .agent, .agent, .agent, .agent, .terminal, .terminal])
        #expect(rows.first { $0.paneID == "p1" }?.tabIsSplit == false && rows.first { $0.paneID == "p2" }?.tabIsSplit == true)
    }
}
