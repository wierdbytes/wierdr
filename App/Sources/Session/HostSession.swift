import Foundation
import Observation
import HerdrCore
import HerdrSSH
import WierdrModel

/// One live connection to a computer running herdr-core:
/// SSH → `hc connect` → `CoreConnection` → `WorkspaceEngine` (spaces, agents)
/// and the terminal attach streams (`TerminalSessionPool`). Reconnects by
/// itself with backoff when the line drops, and checks the line when the app
/// comes back to the foreground.
@MainActor
@Observable
final class HostSession {
    enum State: Equatable {
        case connecting
        case live
        /// Lost the line; retrying (message = why).
        case reconnecting(String)
        /// Gave up (auth failure, host key rejected, hc missing…); needs the person.
        case failed(String)
    }

    /// A host key the person must accept or reject (trust on first use).
    struct HostKeyQuestion: Identifiable {
        let id = UUID()
        let key: HostKeyInfo
        /// Fingerprint trusted before, when the key changed (possible attack).
        let previousFingerprint: String?
        fileprivate let answer: (Bool) -> Void
    }

    let endpoint: Endpoint
    let workspace = Workspace()
    let terminals: TerminalSessionPool
    private(set) var state: State = .connecting
    /// Pending host-key question for the UI (alert).
    private(set) var hostKeyQuestion: HostKeyQuestion?
    /// Name of the core we talk to (from `hello`), e.g. `mentoair`.
    private(set) var coreName: String?
    /// wierdrd there, and the agent harnesses with Wierdr's integrations: checked each time a
    /// connection goes live.
    let daemon = DaemonState()
    let integrations = IntegrationsState()

    @ObservationIgnored let engine: WorkspaceEngine
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var current: CoreConnection?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var wakeUp: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var waitID = 0
    @ObservationIgnored private var liveWatch: Task<Void, Never>?
    /// Each new connection, once its workspace is live (the Live Activity registration).
    @ObservationIgnored var onLive: ((CoreConnection, String) -> Void)?

    init(endpoint: Endpoint, dark: Bool, fontSize: CGFloat) {
        self.endpoint = endpoint
        terminals = TerminalSessionPool(dark: dark, fontSize: fontSize)
        engine = WorkspaceEngine(workspace: workspace)
        engine.display = terminals.theme.display(cellPixels: nil)
        engine.onEvent = { [weak self] event in
            guard let self, let address = event.terminal else { return }
            switch event.kind {
            case .restarted: self.terminals.terminalRestarted(address)
            case .removed: self.terminals.remove(address)
            default: break
            }
        }
        #if DEBUG
        engine.log = { print("[engine] \($0)") }
        #endif
    }

    /// New terminals start in the folder of the focused pane of their tab.
    func bind(screen: ScreenState) {
        engine.focusedPaneProvider = { [weak screen] tabID in screen?.snapshot.focusByTab[tabID] }
    }

    func setAppearance(dark: Bool) {
        terminals.setAppearance(dark: dark)
        engine.display = terminals.theme.display(cellPixels: nil)
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        stopped = false
        loop = Task { [weak self] in await self?.runLoop() }
    }

    /// Disconnect for good.
    func stop() async {
        stopped = true
        hostKeyQuestion?.answer(false)
        loop?.cancel()
        loop = nil
        liveWatch?.cancel()
        daemon.disconnected()
        integrations.disconnected()
        wake()
        let c = current
        current = nil
        terminals.setConnection(nil)
        await c?.close()
    }

    /// Back in the foreground: make sure the line still works (iOS may have
    /// killed the socket while suspended), else reconnect at once.
    func resume() {
        switch state {
        case .failed: return
        case .reconnecting, .connecting: wake(); return
        case .live: break
        }
        guard let c = current else { wake(); return }
        Task { [weak self] in
            let ok = await Self.ping(c)
            guard let self, !ok, self.current === c else { return }
            await c.close()   // the loop notices and reconnects
        }
    }

    /// Retry after a failure the person fixed (e.g. added the key on the Mac).
    func retry() {
        if case .failed = state { state = .connecting }
        if loop == nil { start() } else { wake() }
    }

    /// Appends `line` to `~/.ssh/authorized_keys` on the connected computer
    /// (once; keeps the file's permissions strict).
    func installPublicKey(_ line: String) async throws {
        guard let c = current else { throw SessionError.failed("Not connected") }
        let script = """
        set -e; d="$HOME/.ssh"; f="$d/authorized_keys"
        mkdir -p "$d"; chmod 700 "$d"; touch "$f"; chmod 600 "$f"
        if grep -qxF "$WIERDR_KEY" "$f"; then exit 0; fi
        if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi
        printf '%s\n' "$WIERDR_KEY" >> "$f"
        """
        let result = try await c.exec(ExecParams(argv: ["/bin/sh", "-c", script], env: ["WIERDR_KEY": line], timeout: 20))
        if result.code != 0 {
            let err = String(decoding: result.stderr, as: UTF8.self)
            throw SessionError.failed("Could not install the key (exit \(result.code.map(String.init) ?? "?")): \(err)")
        }
    }

    func answerHostKey(_ ok: Bool) {
        hostKeyQuestion?.answer(ok)
    }

    /// Waits until the first connection is live (returns) or failed (throws).
    func waitUntilLiveOrFailed() async throws {
        while true {
            switch state {
            case .live: return
            case .failed(let message): throw SessionError.failed(message)
            default: break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Loop

    private func runLoop() async {
        var attempt = 0
        while !stopped && !Task.isCancelled {
            do {
                let core = try await connect()
                if stopped || Task.isCancelled { await core.close(); break }
                current = core
                attempt = 0
                terminals.setConnection(core)
                watchLive(core)
                try await engine.run(on: core)          // until the connection closes
                if stopped { break }
                state = .reconnecting("Connection closed")
                workspace.phase = .reconnecting("Connection closed")
            } catch {
                if stopped || Task.isCancelled {
                    if let c = current { await c.close(); current = nil }
                    break
                }
                let message = Self.describe(error)
                if Self.isFatal(error) {
                    state = .failed(message)
                    workspace.phase = .failed(message)
                    current = nil
                    terminals.setConnection(nil)
                    await waitForWake(seconds: nil)
                    attempt = 0
                    continue
                }
                state = .reconnecting(message)
                workspace.phase = .reconnecting(message)
            }
            liveWatch?.cancel()
            if let c = current { await c.close() }
            current = nil
            terminals.setConnection(nil)
            attempt += 1
            await waitForWake(seconds: min(20, 0.5 * pow(2, Double(min(attempt, 6)))))
        }
    }

    /// `state = .live` once the engine reports the workspace live.
    private func watchLive(_ core: CoreConnection) {
        liveWatch?.cancel()
        liveWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.current === core else { return }
                if self.workspace.phase == .live {
                    self.state = .live
                    self.daemon.connected(core)
                    self.integrations.connected(core)
                    self.onLive?(core, self.coreName ?? self.endpoint.address)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func waitForWake(seconds: Double?) async {
        guard !stopped else { return }
        waitID &+= 1
        let id = waitID
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeUp = c
            if let seconds {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    if self?.waitID == id { self?.wake() }
                }
            }
        }
    }

    private func wake() {
        let c = wakeUp
        wakeUp = nil
        c?.resume()
    }

    private func connect() async throws -> CoreConnection {
        let config = SSHConfig(host: endpoint.address, port: endpoint.port, username: endpoint.user,
                               auth: try endpoint.sshAuth())
        let validator = TOFUHostKeyValidator(store: AppStores.knownHosts) { [weak self] key, prompt in
            guard let self else { return false }
            return await self.ask(key: key, prompt: prompt)
        }
        let transport = try await SSHTransport.connect(config, hostKeyValidator: validator)
        let core = CoreConnection(transport: transport)
        do {
            let hello = try await core.start()
            coreName = hello.core.name
        } catch {
            await core.close()
            throw error
        }
        return core
    }

    private func ask(key: HostKeyInfo, prompt: TOFUHostKeyValidator.Prompt) async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WIERDR_TRUST_HOSTKEY"] == "1" { return true }
        #endif
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var previous: String?
            if case .changed(let old) = prompt { previous = old.fingerprint }
            var answered = false
            hostKeyQuestion = HostKeyQuestion(key: key, previousFingerprint: previous) { [weak self] ok in
                guard !answered else { return }
                answered = true
                self?.hostKeyQuestion = nil
                c.resume(returning: ok)
            }
        }
    }

    private static func ping(_ c: CoreConnection) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await c.serverStatus()) != nil }
            group.addTask { try? await Task.sleep(for: .seconds(4)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: Errors

    private static func isFatal(_ error: Error) -> Bool {
        if let e = error as? SSHError {
            switch e {
            case .authenticationFailed, .hostKeyRejected: return true
            default: return e.isHerdrCoreMissing
            }
        }
        if error is SessionError { return true }
        if let e = error as? CoreError, e.kind == "unsupported_generation" { return true }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if let e = error as? CustomStringConvertible { return e.description }
        return String(describing: error)
    }
}

// MARK: - Endpoint

/// Where and how to log in.
struct Endpoint: Hashable, Sendable {
    enum Auth: Hashable, Sendable {
        /// This device's key (Keychain, generated on first use).
        case key
        case password(String)
    }
    var address: String
    var port: Int
    var user: String
    var auth: Auth

    func sshAuth() throws -> SSHConfig.Auth {
        switch auth {
        case .key: return .key(try AppStores.keys.loadOrCreateIdentity())
        case .password(let password):
            guard !password.isEmpty else { throw SessionError.failed("No password given.") }
            return .password(password)
        }
    }
}

enum SessionError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let m): return m }
    }
}

/// App-wide stores for SSH secrets and known hosts.
enum AppStores {
    static let keys = SSHKeyStore()
    static let knownHosts: KnownHostsStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wierdr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return KnownHostsStore(directory: dir)
    }()
}
