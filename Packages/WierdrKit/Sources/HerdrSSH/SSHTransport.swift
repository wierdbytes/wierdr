import Foundation
import HerdrCore
import Network
import NIOCore
import NIOSSH
import NIOTransportServices
import Synchronization

/// herdr-core over SSH: a TCP connection (Network.framework via
/// NIOTransportServices), an SSH session (SwiftNIO SSH) and one exec channel
/// running `hc connect`. The channel's stdout is `inbound`, `write` feeds its
/// stdin.
///
///     let transport = try await SSHTransport.connect(
///         SSHConfig(host: "mac.local", username: "me", auth: .key(identity)),
///         hostKeyValidator: TOFUHostKeyValidator(store: knownHosts) { key, prompt in await askUser(key, prompt) })
///
/// `inbound` finishes normally when `hc connect` exits with status 0 or after
/// `close()`; it finishes with an `SSHError` otherwise (`remoteExited` with the
/// stderr tail, `disconnected`, ...).
public final class SSHTransport: CoreTransport {
    public let inbound: AsyncThrowingStream<Data, Error>
    /// The server's host key, as accepted during the handshake.
    public let hostKey: HostKeyInfo

    private let parent: Channel
    private let child: Channel
    private let state: SessionState

    private init(parent: Channel, child: Channel, state: SessionState, inbound: AsyncThrowingStream<Data, Error>, hostKey: HostKeyInfo) {
        self.parent = parent
        self.child = child
        self.state = state
        self.inbound = inbound
        self.hostKey = hostKey
    }

    deinit {
        parent.close(promise: nil)
    }

    /// Connects, authenticates, validates the host key and starts the remote
    /// command. Throws `SSHError`.
    public static func connect(
        _ config: SSHConfig,
        hostKeyValidator: any HostKeyValidator,
        group: NIOTSEventLoopGroup = .singleton
    ) async throws -> SSHTransport {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let state = SessionState(continuation: continuation)
        let loop = group.next()
        let authPromise = loop.makePromise(of: Void.self)
        let timeout = TimeAmount.nanoseconds(Int64(max(config.connectTimeout, 0.1) * 1_000_000_000))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        if config.keepaliveIdle > 0 {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = config.keepaliveIdle
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 4
        }

        let host = config.host
        let port = config.port
        let username = config.username
        let auth = config.auth
        let bootstrap = NIOTSConnectionBootstrap(group: loop)
            .connectTimeout(timeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .tcpOptions(tcp)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let setup = SetupHandler(authPromise: authPromise, state: state, timeout: timeout)
                    let hostKeys = HostKeyDelegate(host: host, port: port, validator: hostKeyValidator, state: state, setup: setup)
                    let ssh = NIOSSHHandler(
                        role: .client(
                            SSHClientConfiguration(
                                userAuthDelegate: AuthDelegate(username: username, auth: auth),
                                serverAuthDelegate: hostKeys)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers(ssh, setup)
                }
            }

        let parent: Channel
        do {
            parent = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            loop.execute { authPromise.fail(error) }
            throw state.recordedError ?? Self.connectError(error)
        }

        do {
            try await authPromise.futureResult.get()

            let execPromise = loop.makePromise(of: Void.self)
            let childPromise = loop.makePromise(of: Channel.self)
            let command = config.remoteCommand
            loop.execute {
                do {
                    let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(childPromise, channelType: .session) { child, _ in
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(
                                ExecHandler(command: command, execPromise: execPromise, state: state))
                        }
                    }
                } catch {
                    childPromise.fail(error)
                }
            }
            childPromise.futureResult.whenFailure { execPromise.fail($0) }
            let child = try await childPromise.futureResult.get()
            try await execPromise.futureResult.get()
            try await loop.submit {
                try parent.pipeline.syncOperations.handler(type: SetupHandler.self).finish()
            }.get()
            guard let hostKey = state.hostKey else { throw SSHError.disconnected("no host key seen") }
            return SSHTransport(parent: parent, child: child, state: state, inbound: stream, hostKey: hostKey)
        } catch {
            let mapped = state.recordedError ?? Self.sessionError(error, state: state)
            parent.close(promise: nil)
            state.finish(with: mapped)
            throw mapped
        }
    }

    public func write(_ data: Data) async throws {
        if state.isClosedLocally { throw SSHError.closed }
        if data.isEmpty { return }
        let buffer = child.allocator.buffer(bytes: data)
        do {
            try await child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
        } catch {
            if state.isClosedLocally { throw SSHError.closed }
            throw state.recordedError ?? SSHError.disconnected("write failed: \(error)")
        }
    }

    public func close() async {
        state.markClosedLocally()
        try? await parent.close().get()
        state.finish(with: nil)
    }

    // MARK: Error mapping

    static func connectError(_ error: Error) -> SSHError {
        if let e = error as? SSHError { return e }
        if let e = error as? ChannelError, case .connectTimeout = e { return .timedOut }
        return .connectFailed(Self.describe(error))
    }

    static func sessionError(_ error: Error, state: SessionState) -> SSHError {
        if let e = error as? SSHError { return e }
        return .disconnected(Self.describe(error))
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? NWError {
            switch e {
            case .posix(let code): return String(cString: strerror(code.rawValue))
            case .dns(let code): return "DNS lookup failed (\(code))"
            default: return e.debugDescription
            }
        }
        if let e = error as? ChannelError {
            switch e {
            case .eof, .alreadyClosed, .ioOnClosedChannel, .outputClosed, .inputClosed:
                return "the connection closed"
            default: return String(describing: e)
            }
        }
        if let e = error as? NIOSSHError { return "SSH protocol error: \(e)" }
        return String(describing: error)
    }
}

// MARK: - Shared state

/// What both channels' handlers and the transport see. Lock-protected.
final class SessionState: Sendable {
    private struct Inner {
        var stderrTail = Data()
        var exitStatus: Int?
        var exitSignal: String?
        var error: SSHError?
        var hostKey: HostKeyInfo?
        var closedLocally = false
        var finished = false
    }

    static let stderrLimit = 8 * 1024

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let inner = Mutex(Inner())

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ data: Data) {
        continuation.yield(data)
    }

    func appendStderr(_ data: Data) {
        inner.withLock { s in
            s.stderrTail.append(data)
            if s.stderrTail.count > Self.stderrLimit {
                s.stderrTail = Data(s.stderrTail.suffix(Self.stderrLimit))
            }
        }
    }

    var stderr: String {
        inner.withLock { String(decoding: $0.stderrTail, as: UTF8.self) }
    }

    /// The first error that explains a failure (auth, host key, timeout, ...).
    var recordedError: SSHError? { inner.withLock { $0.error } }

    func record(_ error: SSHError) {
        inner.withLock { s in
            if s.error == nil { s.error = error }
        }
    }

    var hostKey: HostKeyInfo? { inner.withLock { $0.hostKey } }

    func setHostKey(_ key: HostKeyInfo) {
        inner.withLock { $0.hostKey = key }
    }

    func setExit(status: Int) {
        inner.withLock { $0.exitStatus = status }
    }

    func setExit(signal: String) {
        inner.withLock { $0.exitSignal = signal }
    }

    var isClosedLocally: Bool { inner.withLock { $0.closedLocally } }

    func markClosedLocally() {
        inner.withLock { $0.closedLocally = true }
    }

    /// Finishes `inbound` once: with `error` if given, else with whatever the
    /// channel's end says (exit status, signal, recorded error).
    func finish(with error: SSHError?) {
        let outcome: (Bool, SSHError?) = inner.withLock { s in
            guard !s.finished else { return (false, nil) }
            s.finished = true
            if s.closedLocally { return (true, nil) }
            if let error { return (true, error) }
            let stderr = String(decoding: s.stderrTail, as: UTF8.self)
            if let signal = s.exitSignal { return (true, .remoteSignaled(signal: signal, stderr: stderr)) }
            if let status = s.exitStatus { return (true, status == 0 ? nil : .remoteExited(status: status, stderr: stderr)) }
            if let e = s.error { return (true, e) }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, .disconnected(tail.isEmpty ? "the server closed the session" : "the server closed the session: \(tail)"))
        }
        guard outcome.0 else { return }
        if let e = outcome.1 {
            continuation.finish(throwing: e)
        } else {
            continuation.finish()
        }
    }
}

// MARK: - Parent channel: handshake bookkeeping

/// Sits after `NIOSSHHandler`: completes `authPromise` on user-auth success,
/// records errors, and runs the handshake timer (paused while the host-key
/// validator runs).
final class SetupHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    private let authPromise: EventLoopPromise<Void>
    private let state: SessionState
    private let timeout: TimeAmount
    private var context: ChannelHandlerContext?
    private var timer: Scheduled<Void>?
    private var paused = false
    private var done = false
    private var everActive = false

    init(authPromise: EventLoopPromise<Void>, state: SessionState, timeout: TimeAmount) {
        self.authPromise = authPromise
        self.state = state
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive {
            everActive = true
            arm()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timer?.cancel()
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        everActive = true
        arm()
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        timer?.cancel()
        timer = nil
        done = true
        authPromise.fail(state.recordedError ?? SSHError.disconnected("the server closed the connection"))
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            authPromise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Before channelActive, it is the TCP connect that failed.
        let mapped =
            context.channel.isActive || everActive
            ? (error as? SSHError) ?? .disconnected(SSHTransport.describe(error))
            : SSHTransport.connectError(error)
        state.record(mapped)
        authPromise.fail(mapped)
        context.close(promise: nil)
    }

    /// Setup complete: no more timeout.
    func finish() {
        done = true
        timer?.cancel()
        timer = nil
    }

    func pause() {
        paused = true
        timer?.cancel()
        timer = nil
    }

    func resume() {
        paused = false
        arm()
    }

    private func arm() {
        guard !done, !paused, timer == nil, let context else { return }
        timer = context.eventLoop.assumeIsolated().scheduleTask(in: timeout) { [weak self] in
            guard let self, let context = self.context else { return }
            self.timer = nil
            self.state.record(.timedOut)
            self.authPromise.fail(SSHError.timedOut)
            context.close(promise: nil)
        }
    }
}

// MARK: - Delegates

final class AuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let auth: SSHConfig.Auth
    private var attempted = false

    init(username: String, auth: SSHConfig.Auth) {
        self.username = username
        self.auth = auth
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        var names: [String] = []
        if availableMethods.contains(.publicKey) { names.append("publickey") }
        if availableMethods.contains(.password) { names.append("password") }
        if availableMethods.contains(.hostBased) { names.append("hostbased") }
        let failure = SSHError.authenticationFailed(methodsOffered: names)

        // One offer: the configured method. If the server asks again, it said no.
        guard !attempted else {
            nextChallengePromise.fail(failure)
            return
        }
        attempted = true
        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch auth {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(failure)
                return
            }
            offer = .password(.init(password: password))
        case .ed25519(let key):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(failure)
                return
            }
            offer = .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
        case .ecdsaP256(let key):
            guard availableMethods.contains(.publicKey) else {
                nextChallengePromise.fail(failure)
                return
            }
            offer = .privateKey(.init(privateKey: NIOSSHPrivateKey(p256Key: key)))
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
    }
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let validator: any HostKeyValidator
    private let state: SessionState
    private weak var setup: SetupHandler?

    init(host: String, port: Int, validator: any HostKeyValidator, state: SessionState, setup: SetupHandler) {
        self.host = host
        self.port = port
        self.validator = validator
        self.state = state
        self.setup = setup
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let info = HostKeyInfo(host: host, port: port, key: hostKey)
        state.setHostKey(info)
        setup?.pause()
        let loop = validationCompletePromise.futureResult.eventLoop
        let setup = NIOLoopBound(self.setup, eventLoop: loop)
        let validator = self.validator
        let state = self.state
        Task {
            let decision = await validator.validate(info)
            loop.execute {
                setup.value?.resume()
                switch decision {
                case .accept:
                    validationCompletePromise.succeed(())
                case .reject:
                    let error = SSHError.hostKeyRejected(fingerprint: info.fingerprint)
                    state.record(error)
                    validationCompletePromise.fail(error)
                }
            }
        }
    }
}

// MARK: - Session channel

/// The exec channel: sends the exec request, feeds stdout to `inbound`,
/// keeps a stderr tail, notes the exit status, and ends everything when the
/// channel closes.
final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let execPromise: EventLoopPromise<Void>
    private let state: SessionState
    private var execSent = false
    private var execPending = true

    init(command: String, execPromise: EventLoopPromise<Void>, state: SessionState) {
        self.command = command
        self.execPromise = execPromise
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Remote EOF on stdout is not the end: exit-status and close follow.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
        if context.channel.isActive { sendExec(context: context) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failExec(SSHError.execRejected(stderr: state.stderr))
    }

    func channelActive(context: ChannelHandlerContext) {
        sendExec(context: context)
        context.fireChannelActive()
    }

    private func sendExec(context: ChannelHandlerContext) {
        guard !execSent else { return }
        execSent = true
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request).assumeIsolated().whenFailure { [weak self] error in
            self?.failExec(SSHError.execRejected(stderr: "exec request failed: \(error)"))
            context.close(promise: nil)
        }
    }

    private func failExec(_ error: SSHError) {
        guard execPending else { return }
        execPending = false
        execPromise.fail(state.recordedError ?? error)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if execPending {
                execPending = false
                execPromise.succeed(())
            }
        case is ChannelFailureEvent:
            if execPending {
                let error = SSHError.execRejected(stderr: state.stderr)
                state.record(error)
                failExec(error)
                context.close(promise: nil)
            }
        case let exit as SSHChannelRequestEvent.ExitStatus:
            state.setExit(status: exit.exitStatus)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            state.setExit(signal: signal.signalName)
        case ChannelEvent.inputClosed:
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        switch message.type {
        case .channel:
            state.yield(Data(buffer.readableBytesView))
        case .stdErr:
            state.appendStderr(Data(buffer.readableBytesView))
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.record((error as? SSHError) ?? .disconnected(SSHTransport.describe(error)))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if execPending {
            let stderr = state.stderr
            failExec(stderr.isEmpty ? SSHError.execRejected(stderr: "the session closed before the command started") : .execRejected(stderr: stderr))
        }
        state.finish(with: nil)
        // One exec per connection: when it ends, so does the connection.
        context.channel.parent?.close(promise: nil)
        context.fireChannelInactive()
    }
}
