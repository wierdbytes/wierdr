import Foundation
import Testing
@testable import WierdrModel

/// The harness integrations' probe and installs (`Integrations`): what the app concludes,
/// and the scripts run against fake harnesses. `WIERDR_INTEGRATIONS_LIVE=1` also installs
/// the real ones into throwaway config folders (CLAUDE_CONFIG_DIR, CODEX_HOME,
/// PI_CODING_AGENT_DIR), with the harnesses this Mac has and the network.
@Suite struct IntegrationsTests {
    @Test func parsesTheProbe() {
        let s = Integrations.Status.parse("""
        Last login: whatever the rc files print
        pi.path=/Users/me/.bun/bin/pi
        pi.version=1.5.2
        pi.state=missing
        pi.old=pi-herdr
        claude.path=/opt/homebrew/bin/claude
        claude.version=2.1.319
        claude.state=disabled
        codex.path=/opt/homebrew/bin/codex
        codex.version=0.170.0
        codex.state=installed
        codex.python=1
        nothing.path=/x
        done=1
        """)
        #expect(s.complete)
        #expect(s.found.map(\.harness) == [.pi, .claude, .codex])
        #expect(s[.pi] == Integrations.Found(harness: .pi, path: "/Users/me/.bun/bin/pi", version: "1.5.2",
                                              state: .missing, old: ["pi-herdr"]))
        #expect(s[.claude]?.state == .disabled)
        #expect(s[.codex]?.python == true && s[.codex]?.trusted == false)
        #expect(s.offers)
        #expect(!Integrations.Status.parse("pi.path=/x\n").complete)
        #expect(Integrations.Status.parse("claude.version=2\ndone=1").found.isEmpty)
    }

    @Test func verdicts() {
        func found(_ h: Integrations.Harness, _ v: String?, _ state: Integrations.State, python: Bool = true) -> Integrations.Found {
            Integrations.Found(harness: h, path: "/bin/\(h.command)", version: v, state: state, python: python)
        }
        #expect(found(.pi, "1.5.2", .missing).verdict == .offer(.install))
        #expect(found(.pi, "1.5.0", .installed).verdict == .installed)
        #expect(found(.pi, "1.4.9", .missing).verdict == .tooOld(needs: "1.5.0"))
        #expect(found(.pi, nil, .missing).verdict == .tooOld(needs: "1.5.0"))
        #expect(found(.claude, "2.1.319", .disabled).verdict == .offer(.enable))
        #expect(found(.claude, "2.1.303", .installed).verdict == .tooOld(needs: "2.1.304"))
        #expect(found(.codex, "0.170.0", .disabled).verdict == .offer(.install))
        #expect(found(.codex, "0.170.0", .missing, python: false).verdict == .needsPython)
        #expect(!Integrations.Status(found: [found(.pi, "1.5.2", .installed), found(.claude, "2.0.0", .missing)],
                                     complete: true).offers)
    }

    #if os(macOS)
    /// Fake `pi`, `claude`, `codex` that log their arguments and answer as `state` says.
    private func fakes(pi: String, claude: String, codexInstalled: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wierdr-harness-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        let fm = FileManager.default
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
        let codex = dir.appendingPathComponent("codex-home")
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)
        if codexInstalled {
            try fm.createDirectory(at: codex.appendingPathComponent("plugins/cache/wierdr/codex/0.1.1"), withIntermediateDirectories: true)
            try """
            [marketplaces.wierdr]
            source = "https://github.com/wierdbytes/wierdr.git"

            [plugins."codex@wierdr"]
            enabled = true

            [hooks.state."codex@wierdr:hooks/hooks.json:session_start:0:0"]
            trusted_hash = "sha256:x"
            """.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        }
        let log = dir.appendingPathComponent("calls").path
        let scripts = [
            "pi": """
            #!/bin/sh
            echo "pi $*" >> '\(log)'
            case "$1" in
              --version) echo 1.5.2 ;;
              list) printf 'User packages:\\n%b' '\(pi)' ;;
            esac
            exit 0
            """,
            "claude": """
            #!/bin/sh
            echo "claude $*" >> '\(log)'
            case "$1 $2" in
              "--version ") echo "2.1.319 (Claude Code)" ;;
              "plugin list") printf '%s' '\(claude)' ;;
              "plugin marketplace") [ "$3" = list ] && echo "  ❯ anthropic-plugin-directory" ;;
            esac
            exit 0
            """,
            "codex": """
            #!/bin/sh
            echo "codex $*" >> '\(log)'
            [ "$1" = --version ] && echo "codex-cli 0.170.0"
            [ "$1 $2 $3" = "plugin marketplace list" ] && printf 'MARKETPLACE  ROOT\\nwierdr  /x\\n'
            exit 0
            """,
        ]
        for (name, text) in scripts {
            let url = bin.appendingPathComponent(name)
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    /// Runs `script` with only the fakes (no login shell: SHELL isn't one it knows).
    private func run(_ script: String, in dir: URL) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                         "HOME": dir.appendingPathComponent("home").path, "SHELL": "/usr/bin/true",
                         "CODEX_HOME": dir.appendingPathComponent("codex-home").path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func calls(_ dir: URL) -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    @Test func probeReadsEachHarness() throws {
        let dir = try fakes(pi: "  npm:@wierdbytes/pi-wierdr\\n  npm:@wierdbytes/pi-agents\\n",
                            claude: #"[{"id": "cc@wierdr", "version": "0.1.2", "enabled": false}]"#, codexInstalled: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (code, out) = try run(Integrations.loginPath + "\n" + Integrations.probeBody, in: dir)
        #expect(code == 0)
        let s = Integrations.Status.parse(out)
        #expect(s.complete)
        #expect(s[.pi]?.path == dir.appendingPathComponent("bin/pi").path)
        #expect(s[.pi]?.version == "1.5.2" && s[.pi]?.state == .installed && s[.pi]?.old == ["pi-agents"])
        #expect(s[.claude]?.version == "2.1.319" && s[.claude]?.state == .disabled)
        #expect(s[.codex]?.version == "0.170.0" && s[.codex]?.state == .installed && s[.codex]?.trusted == true)
    }

    @Test func probeSeesWhatsMissing() throws {
        let dir = try fakes(pi: "  npm:@wierdbytes/pi-web\\n", claude: #"[{"id": "other@x", "enabled": true}]"#,
                            codexInstalled: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Integrations.Status.parse(try run(Integrations.loginPath + "\n" + Integrations.probeBody, in: dir).1)
        #expect(s[.pi]?.state == .missing && s[.pi]?.old == [])
        #expect(s[.claude]?.state == .missing)
        #expect(s[.codex]?.state == .missing && s[.codex]?.trusted == false)
    }

    @Test func installsRunTheHarnessesCommands() throws {
        let dir = try fakes(pi: "  npm:@wierdbytes/pi-herdr\\n", claude: "[]", codexInstalled: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ found: Integrations.Found) throws -> [String] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("calls"))
            #expect(try self.run(Integrations.script(for: found), in: dir).0 == 0)
            return calls(dir)
        }
        let bin = dir.appendingPathComponent("bin").path
        #expect(try run(.init(harness: .pi, path: bin + "/pi", state: .missing)) == [
            "pi install npm:@wierdbytes/pi-wierdr", "pi list", "pi remove npm:@wierdbytes/pi-herdr", "pi list",
        ])
        #expect(try run(.init(harness: .claude, path: bin + "/claude", state: .missing)) == [
            "claude plugin marketplace list", "claude plugin marketplace add wierdbytes/wierdr",
            "claude plugin install cc@wierdr",
        ])
        #expect(try run(.init(harness: .claude, path: bin + "/claude", state: .disabled)) == [
            "claude plugin enable cc@wierdr",
        ])
        // A marketplace named wierdr is there already: used as it is.
        #expect(try run(.init(harness: .codex, path: bin + "/codex", state: .missing)) == [
            "codex plugin marketplace list", "codex plugin add codex@wierdr",
        ])
    }

    /// The real harnesses, into throwaway config folders: install, then the probe sees them in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WIERDR_INTEGRATIONS_LIVE"] == "1"))
    func liveInstallsIntoThrowawayConfigs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wierdr-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = ProcessInfo.processInfo.environment
        for (key, name) in [("CLAUDE_CONFIG_DIR", "claude"), ("CODEX_HOME", "codex"), ("PI_CODING_AGENT_DIR", "pi")] {
            let d = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            env[key] = d.path
        }
        func sh(_ script: String) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let probe = Integrations.loginPath + "\n" + Integrations.probeBody
        let before = Integrations.Status.parse(try sh(probe).1)
        #expect(before.complete)
        for found in before.found where found.state == .missing {
            #expect(try sh(Integrations.script(for: found)).0 == 0, "\(found.harness)")
        }
        let after = Integrations.Status.parse(try sh(probe).1)
        for found in after.found { #expect(found.state == .installed, "\(found.harness)") }
    }
    #endif
}
