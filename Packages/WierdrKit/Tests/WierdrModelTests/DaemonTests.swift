import Foundation
import Testing
@testable import WierdrModel

/// wierdrd's probe and setup (`Daemon`): what the app concludes from the probe, and the
/// scripts themselves, run here against a fake Homebrew and wierdrd.
@Suite struct DaemonTests {
    @Test func parsesTheProbe() {
        let s = Daemon.Status.parse("""
        os=Darwin
        brew=/opt/homebrew/bin/brew
        wierdrd=/opt/homebrew/bin/wierdrd
        version=0.1.0
        formula=1
        exit=
        log=2026-11-20 10:00:00 relay: refused
        junk
        """)
        #expect(s == Daemon.Status(os: "Darwin", brew: "/opt/homebrew/bin/brew", path: "/opt/homebrew/bin/wierdrd",
                                   version: "0.1.0", fromBrew: true, running: false, lastExit: nil,
                                   lastLog: "2026-11-20 10:00:00 relay: refused"))
        #expect(Daemon.Status.parse("os=Linux\nbrew=\nwierdrd=\n") == Daemon.Status(os: "Linux"))
    }

    @Test func verdicts() {
        let brew = "/opt/homebrew/bin/brew"
        let mac = Daemon.Status(os: "Darwin", brew: brew)
        #expect(mac.verdict == .offer(.install))
        #expect(Daemon.Status(os: "Darwin").verdict == .needsBrew)
        #expect(Daemon.Status(os: "Linux", brew: brew).verdict == .unsupported(os: "Linux"))
        #expect(Daemon.Status().verdict == .unsupported(os: "this system"))

        var installed = mac
        installed.path = "/opt/homebrew/bin/wierdrd"
        installed.version = Daemon.minimumVersion
        installed.fromBrew = true
        #expect(installed.verdict == .offer(.start))
        installed.running = true
        #expect(installed.verdict == .running)

        var old = installed
        old.version = "0.0.9"
        #expect(old.verdict == .offer(.update))
        old.version = nil   // too old to say
        #expect(old.verdict == .offer(.update))
        old.running = false
        #expect(old.verdict == .offer(.update))

        // A build from source: Homebrew can't start or update it.
        var source = mac
        source.path = "/Users/me/.local/bin/wierdrd"
        source.version = "0.0.1"
        #expect(source.verdict == .stoppedOutsideBrew)
        source.running = true
        #expect(source.verdict == .running)
    }

    @Test func comparesVersions() {
        #expect(Daemon.compare("0.10.0", "0.9.1") == 1)
        #expect(Daemon.compare("0.1", "0.1.0") == 0)
        #expect(Daemon.compare("0.1.0", "0.1.1") == -1)
        #expect(Daemon.compare("1.0.0-beta", "1.0.0") == 0)
    }

    #if os(macOS)
    /// A folder with a fake `brew`, `wierdrd` and `git` that log their arguments.
    private func fakes() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wierdr-daemon-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("opt/wierdrd"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls").path
        let scripts = [
            "brew": "#!/bin/sh\necho \"brew $*\" >> '\(log)'\n[ \"$1\" = --repository ] && echo '\(dir.path)/tap'\nexit 0\n",
            "wierdrd": "#!/bin/sh\n[ \"$1\" = --version ] && echo 0.2.0\n",
            "git": "#!/bin/sh\necho \"git $*\" >> '\(log)'\n",
        ]
        for (name, text) in scripts {
            let url = bin.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir
    }

    private func run(_ script: String, in dir: URL, env extra: [String: String] = [:]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PATH": dir.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                         "HOME": dir.appendingPathComponent("home").path].merging(extra) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func probeFindsHomebrewAndWierdrd() throws {
        let dir = try fakes()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (code, out) = try run(Daemon.probeScript, in: dir)
        #expect(code == 0)
        let s = Daemon.Status.parse(out)
        #expect(s.os == "Darwin")
        #expect(s.brew == dir.appendingPathComponent("bin/brew").path)
        #expect(s.path == dir.appendingPathComponent("bin/wierdrd").path)
        #expect(s.version == "0.2.0")
        #expect(s.fromBrew)
    }

    @Test func actionsRunHomebrew() throws {
        let dir = try fakes()
        defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("bin/brew").path
        let log = dir.appendingPathComponent("calls")
        func calls(of action: Daemon.Action) throws -> [String] {
            try? FileManager.default.removeItem(at: log)
            let (code, _) = try run(Daemon.script(for: action), in: dir, env: ["WIERDR_BREW": brew])
            #expect(code == 0)
            return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        #expect(try calls(of: .install) == [
            "brew tap wierdbytes/apps",
            "brew trust --help", "brew trust --tap wierdbytes/apps",
            "brew install wierdbytes/apps/wierdrd",
            "brew services restart wierdrd",
        ])
        #expect(try calls(of: .start) == ["brew services restart wierdrd"])
        #expect(try calls(of: .update) == [
            "brew tap wierdbytes/apps",
            "brew trust --help", "brew trust --tap wierdbytes/apps",
            "brew --repository wierdbytes/apps",
            "git -C \(dir.path)/tap pull --ff-only --quiet",
            "brew upgrade wierdbytes/apps/wierdrd",
            "brew services restart wierdrd",
        ])
    }

    @Test func aFailingStepStopsTheAction() throws {
        let dir = try fakes()
        defer { try? FileManager.default.removeItem(at: dir) }
        let brew = dir.appendingPathComponent("bin/brew")
        try "#!/bin/sh\n[ \"$1\" = install ] && { echo 'Error: no bottle' >&2; exit 1; }\nexit 0\n"
            .write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let (code, _) = try run(Daemon.script(for: .install), in: dir, env: ["WIERDR_BREW": brew.path])
        #expect(code == 1)
    }
    #endif
}
