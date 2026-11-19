import SwiftUI
import WierdrModel

/// The seams between the UI and the connection plumbing (SSH + HerdrCore +
/// the live `Workspace`). The UI only calls these closures; the lead wires
/// `AppServices.live` in `WierdrApp` once HerdrSSH/HerdrCore are ready.
///
/// Everything has a harmless default so the UI (and demo mode) runs today.
struct AppServices {
    /// Opens a session to `host` and returns its live workspace (already
    /// subscribed; `phase` reflects the connection). `password`: for `.password`
    /// hosts, as the person typed it for this connection (never kept: the session
    /// holds it in memory for its own reconnects, and drops it with itself).
    var connect: @MainActor (_ host: Host, _ password: String?) async throws -> Workspace
    /// Tears the session down.
    var disconnect: @MainActor (_ workspace: Workspace) async -> Void

    /// This iPad's SSH public key (OpenSSH one-line format), `nil` while none exists.
    var publicKey: @MainActor () -> String?
    /// Creates the key if needed and returns its public part.
    var generateKey: @MainActor () async throws -> String

    /// Deletes a host's password that builds before Build 89 kept in the Keychain
    /// (passwords aren't kept any more).
    var deletePassword: @MainActor (_ host: Host.ID) -> Void

    /// The terminal view for a pane (SwiftTerm + attach stream when live).
    var terminalViews: TerminalViewProvider

    /// Called once the live workspace's screen state exists (new terminals
    /// start in the folder of the focused pane of their tab).
    var bindScreen: @MainActor (_ workspace: Workspace, _ screen: ScreenState) -> Void = { _, _ in }

    /// Adds this device's public key to `~/.ssh/authorized_keys` on the
    /// connected computer (so the next login needs no password).
    var installKey: @MainActor () async throws -> Void = { throw AppError.notImplemented("Not connected") }

    /// The live terminal session of a terminal address, for input that does
    /// not come from its own keyboard (the iPhone's key panel: keys, pasted
    /// clipboard text, image paths). `nil` when there is none (demo).
    var terminalSession: @MainActor (_ address: String) -> TerminalSession? = { _ in nil }

    /// Placeholders: connect throws "not implemented", no key, no Keychain,
    /// the drawn demo terminal.
    static let placeholder = AppServices(
        connect: { _, _ in throw AppError.notImplemented("Connecting over SSH is not implemented yet") },
        disconnect: { _ in },
        publicKey: { nil },
        generateKey: { throw AppError.notImplemented("Key generation is not implemented yet") },
        deletePassword: { _ in },
        terminalViews: .demo
    )
}

enum AppError: LocalizedError {
    case notImplemented(String)
    var errorDescription: String? {
        switch self { case .notImplemented(let s): return s }
    }
}

private struct AppServicesKey: EnvironmentKey {
    static let defaultValue = AppServices.placeholder
}

extension EnvironmentValues {
    var services: AppServices {
        get { self[AppServicesKey.self] }
        set { self[AppServicesKey.self] = newValue }
    }
}
