import Foundation
import HerdrCore
import Synchronization
import Testing

@testable import HerdrSSH

/// Against a throwaway sshd on 127.0.0.1:2222 (scripts/test-sshd.sh), running
/// the real `hc connect` of this Mac. Run with:
///
///     WIERDR_SSH_LIVE=1 swift test --filter HerdrSSHTests
@Suite("Live SSH", .serialized, .enabled(if: ProcessInfo.processInfo.environment["WIERDR_SSH_LIVE"] == "1"))
struct LiveSSHTests {
    static let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIERDR_SSHD_DIR"] ?? "/tmp/wierdr-sshd")
    static let port = 2222
    static let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()

    init() throws {
        let script = repoRoot.appendingPathComponent("scripts/test-sshd.sh").path
        let (status, out, err) = try run("/bin/sh", [script, "start"])
        guard status == 0 else { throw TestError("test sshd: \(out)\(err)") }
    }

    func clientKey() throws -> SSHPrivateKey {
        try SSHPrivateKey(importing: String(contentsOf: Self.dir.appendingPathComponent("client_ed25519"), encoding: .utf8))
    }

    func config(auth: SSHConfig.Auth? = nil, command: String = SSHConfig.defaultRemoteCommand) throws -> SSHConfig {
        SSHConfig(
            host: "127.0.0.1", port: Self.port, username: Self.user, auth: try auth ?? .key(clientKey()),
            remoteCommand: command, connectTimeout: 10)
    }

    /// Accepts anything, remembering what it saw.
    final class Recorder: HostKeyValidator {
        let seen = Mutex<[HostKeyInfo]>([])
        let decision: HostKeyDecision
        init(_ decision: HostKeyDecision = .accept) { self.decision = decision }
        func validate(_ key: HostKeyInfo) async -> HostKeyDecision {
            seen.withLock { $0.append(key) }
            return decision
        }
    }

    /// Reads from `inbound` until a newline; returns the line.
    func readLine(_ transport: SSHTransport) async throws -> String {
        var buffer = Data()
        for try await chunk in transport.inbound {
            buffer.append(chunk)
            if let nl = buffer.firstIndex(of: 0x0A) {
                return String(decoding: buffer[..<nl], as: UTF8.self)
            }
        }
        throw TestError("inbound ended before a newline: \(String(decoding: buffer, as: UTF8.self))")
    }

    @Test func helloOverSSH() async throws {
        let recorder = Recorder()
        let transport = try await SSHTransport.connect(try config(), hostKeyValidator: recorder)
        let expected = try keygenFingerprint(Self.dir.appendingPathComponent("host_ed25519.pub"))
        let seen = recorder.seen.withLock { $0 }
        #expect(seen.count == 1)
        #expect(seen.first?.fingerprint == expected)
        #expect(seen.first?.keyType == "ssh-ed25519")
        #expect(seen.first?.host == "127.0.0.1")
        #expect(seen.first?.port == Self.port)
        #expect(transport.hostKey.fingerprint == expected)
        let hostPub = try String(contentsOf: Self.dir.appendingPathComponent("host_ed25519.pub"), encoding: .utf8)
        #expect(hostPub.hasPrefix(transport.hostKey.openSSHPublicKey + " "))

        try await transport.write(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hello\",\"params\":{}}\n".utf8))
        let line = try await readLine(transport)
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["id"] as? Int == 1)
        #expect(json?["result"] is [String: Any], "not a result: \(line)")
        await transport.close()
        await transport.close()  // idempotent
        await #expect(throws: SSHError.closed) { try await transport.write(Data("x".utf8)) }
    }

    @Test func tofuWithKnownHostsStore() async throws {
        let store = KnownHostsStore.inMemory()
        let asked = Mutex(0)
        let validator = TOFUHostKeyValidator(store: store) { _, _ in
            asked.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        for _ in 0..<2 {
            let t = try await SSHTransport.connect(try config(command: "echo hi"), hostKeyValidator: validator)
            #expect(try await readLine(t) == "hi")
            await t.close()
        }
        #expect(asked.withLock { $0 } == 1)
        #expect(store.all.count == 1)
    }

    @Test func wrongKeyFailsAuthentication() async throws {
        let error = await #expect(throws: SSHError.self) {
            _ = try await SSHTransport.connect(try config(auth: .ed25519(.init())), hostKeyValidator: Recorder())
        }
        guard case .authenticationFailed(let methods) = error else {
            Issue.record("expected authenticationFailed, got \(String(describing: error))")
            return
        }
        #expect(methods == ["publickey"])
    }

    @Test func passwordNotOffered() async throws {
        let error = await #expect(throws: SSHError.self) {
            _ = try await SSHTransport.connect(try config(auth: .password("nope")), hostKeyValidator: Recorder())
        }
        #expect(error == .authenticationFailed(methodsOffered: ["publickey"]))
    }

    @Test func rejectedHostKey() async throws {
        let recorder = Recorder(.reject)
        let expected = try keygenFingerprint(Self.dir.appendingPathComponent("host_ed25519.pub"))
        await #expect(throws: SSHError.hostKeyRejected(fingerprint: expected)) {
            _ = try await SSHTransport.connect(try config(), hostKeyValidator: recorder)
        }
    }

    @Test func hostKeyPromptDoesNotCountTowardsTimeout() async throws {
        var cfg = try config(command: "echo ok")
        cfg.connectTimeout = 1
        let slow = ClosureHostKeyValidator { _ in
            try? await Task.sleep(for: .milliseconds(1500))
            return .accept
        }
        let t = try await SSHTransport.connect(cfg, hostKeyValidator: slow)
        #expect(try await readLine(t) == "ok")
        await t.close()
    }

    @Test func remoteExitStatusAndStderr() async throws {
        let t = try await SSHTransport.connect(
            try config(command: "echo out; echo oops >&2; exit 3"), hostKeyValidator: Recorder())
        var got = Data()
        let error = await #expect(throws: SSHError.self) {
            for try await chunk in t.inbound { got.append(chunk) }
        }
        #expect(String(decoding: got, as: UTF8.self) == "out\n")
        #expect(error == .remoteExited(status: 3, stderr: "oops\n"))
        await #expect(throws: SSHError.self) { try await t.write(Data("x".utf8)) }
    }

    @Test func cleanExitFinishesInbound() async throws {
        let t = try await SSHTransport.connect(try config(command: "printf done"), hostKeyValidator: Recorder())
        var got = Data()
        for try await chunk in t.inbound { got.append(chunk) }
        #expect(String(decoding: got, as: UTF8.self) == "done")
    }

    @Test func missingHerdrCore() async throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let command = "env HOME=\(home.path) PATH=/usr/bin:/bin \(SSHConfig.defaultRemoteCommand)"
        let t = try await SSHTransport.connect(try config(command: command), hostKeyValidator: Recorder())
        let error = await #expect(throws: SSHError.self) {
            for try await _ in t.inbound {}
        }
        #expect(error?.isHerdrCoreMissing == true)
        #expect(error?.localizedDescription.contains("not installed") == true)
    }

    @Test func largeEcho() async throws {
        let t = try await SSHTransport.connect(try config(command: "cat"), hostKeyValidator: Recorder())
        let size = 4 << 20
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        async let received: Data = {
            var got = Data()
            for try await chunk in t.inbound {
                got.append(chunk)
                if got.count >= size { break }
            }
            return got
        }()
        var offset = 0
        while offset < size {
            let n = min(100_000, size - offset)
            try await t.write(payload[offset..<offset + n])
            offset += n
        }
        let got = try await received
        #expect(got == payload)
        await t.close()
    }

    @Test func connectionRefused() async throws {
        var cfg = try config()
        cfg.port = 2223
        let error = await #expect(throws: SSHError.self) {
            _ = try await SSHTransport.connect(cfg, hostKeyValidator: Recorder())
        }
        guard case .connectFailed = error else {
            Issue.record("expected connectFailed, got \(String(describing: error))")
            return
        }
    }

    @Test func unknownHost() async throws {
        var cfg = try config()
        cfg.host = "no-such-host.invalid"
        let error = await #expect(throws: SSHError.self) {
            _ = try await SSHTransport.connect(cfg, hostKeyValidator: Recorder())
        }
        guard case .connectFailed = error else {
            Issue.record("expected connectFailed, got \(String(describing: error))")
            return
        }
    }

    @Test func unreachableHostTimesOut() async throws {
        var cfg = try config()
        cfg.host = "10.255.255.1"  // blackhole (or no route): either way, quick
        cfg.connectTimeout = 1
        let start = ContinuousClock.now
        let error = await #expect(throws: SSHError.self) {
            _ = try await SSHTransport.connect(cfg, hostKeyValidator: Recorder())
        }
        #expect(ContinuousClock.now - start < .seconds(4))
        switch error {
        case .timedOut?, .connectFailed?: break
        default: Issue.record("expected timedOut or connectFailed, got \(String(describing: error))")
        }
    }

    @Test func silentServerTimesOut() async throws {
        // TCP accepts, SSH never says hello.
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-l", "127.0.0.1", "2224"]
        nc.standardInput = Pipe()
        nc.standardOutput = FileHandle.nullDevice
        try nc.run()
        defer { nc.terminate() }
        try await Task.sleep(for: .milliseconds(300))
        var cfg = try config()
        cfg.port = 2224
        cfg.connectTimeout = 1
        let start = ContinuousClock.now
        await #expect(throws: SSHError.timedOut) {
            _ = try await SSHTransport.connect(cfg, hostKeyValidator: Recorder())
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func worksAsCoreTransport() async throws {
        let transport: any CoreTransport = try await SSHTransport.connect(try config(command: "cat"), hostKeyValidator: Recorder())
        try await transport.write(Data("ping\n".utf8))
        var it = transport.inbound.makeAsyncIterator()
        let chunk = try await it.next()
        #expect(chunk == Data("ping\n".utf8))
        await transport.close()
        #expect(try await it.next() == nil)
    }
}
