import Foundation
import Synchronization
import Testing

@testable import HerdrSSH

@Suite("Known hosts")
struct KnownHostsTests {
    func key(_ host: String = "mac.local", port: Int = 22) -> HostKeyInfo {
        HostKeyInfo(host: host, port: port, openSSHPublicKey: SSHPrivateKey.generateEd25519().openSSHPublicKey())!
    }

    @Test func trustOnFirstUse() throws {
        let store = KnownHostsStore.inMemory()
        let k = key()
        #expect(store.status(of: k) == .unknown)
        try store.trust(k)
        #expect(store.status(of: k) == .trusted)
        // Host names compare case-insensitively; ports are separate entries.
        var upper = k
        upper.host = "MAC.local"
        #expect(store.status(of: upper) == .trusted)
        var otherPort = k
        otherPort.port = 2222
        #expect(store.status(of: otherPort) == .unknown)

        let changed = key()
        guard case .changed(let old) = store.status(of: changed) else {
            Issue.record("expected .changed")
            return
        }
        #expect(old.fingerprint == k.fingerprint)

        try store.trust(changed)
        #expect(store.status(of: changed) == .trusted)
        #expect(store.status(of: k) != .trusted)
        #expect(store.all.count == 1)

        try store.remove(host: "mac.local")
        #expect(store.status(of: changed) == .unknown)
        #expect(store.all.isEmpty)
    }

    @Test func persistsToJSONFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = key("a.local")
        let b = key("b.local", port: 2222)
        do {
            let store = KnownHostsStore(directory: dir.appendingPathComponent("sub"))
            try store.trust(a)
            try store.trust(b)
        }
        let reopened = KnownHostsStore(directory: dir.appendingPathComponent("sub"))
        #expect(reopened.status(of: a) == .trusted)
        #expect(reopened.status(of: b) == .trusted)
        #expect(reopened.all.map(\.host) == ["a.local", "b.local"])
        #expect(reopened.knownHost(host: "b.local", port: 2222)?.fingerprint == b.fingerprint)
        try reopened.remove(host: "a.local")
        #expect(KnownHostsStore(directory: dir.appendingPathComponent("sub")).all.map(\.host) == ["b.local"])
    }

    @Test func tofuValidatorAsksOnlyWhenNeeded() async throws {
        let store = KnownHostsStore.inMemory()
        let prompts = Mutex<[TOFUHostKeyValidator.Prompt]>([])
        let answer = Mutex(true)
        let validator = TOFUHostKeyValidator(store: store) { _, prompt in
            prompts.withLock { $0.append(prompt) }
            return answer.withLock { $0 }
        }
        let k = key()
        #expect(await validator.validate(k) == .accept)
        #expect(store.status(of: k) == .trusted)
        #expect(await validator.validate(k) == .accept)
        #expect(prompts.withLock { $0 } == [.unknown])

        // A changed key, refused: rejected and not stored.
        answer.withLock { $0 = false }
        let other = key()
        #expect(await validator.validate(other) == .reject)
        #expect(store.status(of: k) == .trusted)
        let last = prompts.withLock { $0.last }
        guard case .changed(let old) = last else {
            Issue.record("expected a .changed prompt, got \(String(describing: last))")
            return
        }
        #expect(old.fingerprint == k.fingerprint)

        // Unknown host, refused.
        #expect(await validator.validate(key("new.local")) == .reject)
        #expect(store.all.count == 1)
    }
}

@Suite("Remote command")
struct RemoteCommandTests {
    @Test func authDescriptionHidesSecrets() {
        let config = SSHConfig(host: "h", username: "u", auth: .password("hunter2"))
        #expect(!String(describing: config).contains("hunter2"))
        #expect(!String(reflecting: config).contains("hunter2"))
    }

    @Test func noNestedSingleQuotesOrBackslashes() {
        for cmd in [SSHConfig.defaultRemoteCommand, SSHConfig.remoteCommand(session: "s1")] {
            #expect(cmd.hasPrefix("/bin/sh -c '"))
            #expect(cmd.hasSuffix("'"))
            let inner = cmd.dropFirst("/bin/sh -c '".count).dropLast()
            #expect(!inner.contains("'"))
            #expect(!inner.contains("\\"))
        }
        #expect(SSHConfig.remoteCommand(session: "s1").contains("HC_SESSION=s1 exec"))
        // Unsafe session names are ignored.
        #expect(SSHConfig.remoteCommand(session: "x; rm -rf ~") == SSHConfig.defaultRemoteCommand)
        #expect(SSHConfig.remoteCommand(session: "x'y") == SSHConfig.defaultRemoteCommand)
    }

    /// Documented in docs/ssh.md; verified with the system ssh against scripts/test-sshd.sh.
    @Test func exactDefaultCommand() {
        #expect(SSHConfig.defaultRemoteCommand == #"/bin/sh -c 'for p in "$(command -v herdr-core)" "$HOME/.local/bin/herdr-core" "/opt/homebrew/bin/herdr-core" "/usr/local/bin/herdr-core" "$HOME/.cargo/bin/herdr-core" "$HOME/.local/share/mise/shims/herdr-core" "$HOME/.nix-profile/bin/herdr-core" "/run/current-system/sw/bin/herdr-core" "$(command -v hc)" "$HOME/.local/bin/hc"; do [ -n "$p" ] && [ -x "$p" ] && exec "$p" connect; done; echo "herdr-core is not installed here (looked on PATH and in ~/.local/bin, Homebrew, ~/.cargo/bin, mise, nix)" >&2; exit 127'"#)
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash", "/bin/sh"])
    func reportsMissingHerdrCore(shell: String) throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // How sshd runs it: `<login shell> -c <command>`.
        let (status, out, err) = try run(
            shell, ["-c", SSHConfig.defaultRemoteCommand],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        #expect(status == 127)
        #expect(out.isEmpty)
        #expect(err.contains(SSHConfig.notInstalledMarker))
        #expect(SSHError.remoteExited(status: Int(status), stderr: err).isHerdrCoreMissing)
    }

    @Test func findsHerdrCoreInLocalBin() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("herdr-core")
        try "#!/bin/sh\necho \"fake $1 session=$HC_SESSION\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let (status, out, _) = try run("/bin/zsh", ["-c", SSHConfig.defaultRemoteCommand], environment: env)
        #expect(status == 0)
        #expect(out == "fake connect session=\n")
        let (_, out2, _) = try run("/bin/bash", ["-c", SSHConfig.remoteCommand(session: "s1")], environment: env)
        #expect(out2 == "fake connect session=s1\n")
    }
}
