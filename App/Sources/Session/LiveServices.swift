import SwiftUI
import UIKit
import HerdrSSH
import WierdrModel

/// Owns the live `HostSession` and provides the `AppServices` the UI uses:
/// connect/disconnect, this device's SSH key, host passwords (Keychain) and
/// the live terminal views.
@MainActor
@Observable
final class LiveConnector {
    /// The open live session (nil in demo mode or when disconnected).
    private(set) var active: HostSession?

    var services: AppServices {
        AppServices(
            connect: { [weak self] host, password in
                guard let self else { throw SessionError.failed("Gone") }
                return try await self.connect(host, password: password)
            },
            disconnect: { [weak self] _ in await self?.disconnect() },
            publicKey: { Self.publicKeyLine() },
            generateKey: {
                _ = try AppStores.keys.loadOrCreateIdentity()
                return Self.publicKeyLine() ?? ""
            },
            savePassword: { id, password in
                try? AppStores.keys.savePassword(password, host: Self.passwordKey(id), port: 0, user: "wierdr")
            },
            loadPassword: { id in
                (try? AppStores.keys.password(host: Self.passwordKey(id), port: 0, user: "wierdr")) ?? nil
            },
            deletePassword: { id in
                try? AppStores.keys.deletePassword(host: Self.passwordKey(id), port: 0, user: "wierdr")
            },
            terminalViews: TerminalViewProvider { [weak self] ctx in
                if let session = self?.active {
                    return AnyView(LiveTerminalView(context: ctx, session: session))
                }
                return AnyView(DemoTerminalView(context: ctx))
            },
            bindScreen: { [weak self] _, screen in self?.active?.bind(screen: screen) },
            installKey: { [weak self] in
                guard let session = self?.active else { throw SessionError.failed("Not connected") }
                _ = try AppStores.keys.loadOrCreateIdentity()
                guard let line = Self.publicKeyLine() else { throw SessionError.failed("No key") }
                try await session.installPublicKey(line)
            }
        )
    }

    private func connect(_ host: Host, password: String?) async throws -> Workspace {
        await disconnect()
        let auth: Endpoint.Auth = host.auth == .password ? .password(password ?? "") : .key
        let endpoint = Endpoint(address: host.address.trimmingCharacters(in: .whitespaces),
                                port: host.port, user: host.user.trimmingCharacters(in: .whitespaces), auth: auth)
        let dark = UITraitCollection.current.userInterfaceStyle != .light
        let fontSize = CGFloat(UserDefaults.standard.object(forKey: "terminalFontSize") as? Double ?? 14)
        let session = HostSession(endpoint: endpoint, dark: dark, fontSize: fontSize)
        active = session
        #if DEBUG
        DebugHooks.type = { [weak session] text, address in
            guard let t = session?.terminals.session(for: address) else { return }
            t.send(source: t.terminalView, data: ArraySlice(Array(text.utf8)))
        }
        #endif
        session.start()
        // First connection: wait until live; give up on the first error
        // (later drops reconnect by themselves). Time spent on the host-key
        // question doesn't count.
        var waited = 0.0
        while true {
            switch session.state {
            case .live:
                return session.workspace
            case .failed(let message), .reconnecting(let message):
                await disconnect()
                throw SessionError.failed(message)
            case .connecting:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
            if session.hostKeyQuestion == nil { waited += 0.1 }
            if waited > 30 {
                await disconnect()
                throw SessionError.failed("Timed out connecting to \(endpoint.address)")
            }
            if active !== session { throw CancellationError() }
        }
    }

    func disconnect() async {
        guard let session = active else { return }
        active = nil
        await session.stop()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active { active?.resume() }
    }

    private static func passwordKey(_ id: UUID) -> String { "host-\(id.uuidString)" }

    static func publicKeyLine() -> String? {
        guard let key = try? AppStores.keys.identity() else { return nil }
        return key.openSSHPublicKey(comment: "wierdr@\(UIDevice.current.name.replacingOccurrences(of: " ", with: "-"))")
    }
}

/// A live terminal in a pane card (SwiftTerm view fed by an attach stream).
struct LiveTerminalView: View {
    let context: TerminalViewContext
    let session: HostSession
    @Environment(\.colorScheme) private var colorScheme

    private var pool: TerminalSessionPool { session.terminals }

    var body: some View {
        TerminalSurface(session: pool.session(for: context.address), isFocused: context.focused) {
            context.requestFocus()
        }
        .onAppear { sync() }
        .onChange(of: colorScheme) { _, _ in sync() }
        .onChange(of: context.fontSize) { _, _ in sync() }
    }

    private func sync() {
        let dark = colorScheme == .dark
        if pool.isDark != dark { session.setAppearance(dark: dark) }
        if pool.fontSize != context.fontSize { pool.setFontSize(context.fontSize) }
    }
}
