import SwiftUI
import WierdrModel

/// App-level state: which session is open (none / demo / live) and the saved hosts.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable {
        case none
        case demo
        case live(Host)
    }

    private(set) var mode: Mode = .none
    /// The open session's UI state (workspace + screen + panel state).
    private(set) var session: WorkspaceController?

    /// Host being connected to (progress in the host list).
    private(set) var connecting: Host.ID?
    /// Last connection error, shown with a Retry button.
    var connectionError: String?
    private(set) var failedHost: Host?
    /// The host list opens its editor for a new host (the tour's Add My Mac).
    var addHostRequested = false
    /// A password host to connect to, waiting for its password: the host list asks for it.
    /// Passwords are never kept, so every connection to such a host asks (Connect, Retry,
    /// the return to the last host at launch); the session holds it in memory for
    /// its own reconnects.
    var passwordRequest: Host?

    let hosts = HostStore()
    @ObservationIgnored var services: AppServices

    init(services: AppServices = .placeholder) {
        self.services = services
        // Builds before 89 kept passwords in the Keychain: none stays.
        for host in hosts.hosts { services.deletePassword(host.id) }
    }

    var workspace: Workspace? { session?.workspace }
    var screen: ScreenState? { session?.screen }

    // MARK: Sessions

    func startDemo() {
        connectionError = nil
        let ws = Workspace.preview()
        let screen = ScreenState()
        // Open on the first space, its agent focused (like the desktop screenshot).
        if let first = ws.spaces.first, let pane = first.tabs.first?.panes.first {
            screen.focus(pane: pane.id, in: ws)
        }
        session = WorkspaceController(workspace: ws, screen: screen, isDemo: true)
        mode = .demo
    }

    /// Connects to `host` and opens its workspace. Errors land in `connectionError`.
    /// A password host without `password` asks for it first (`passwordRequest`).
    func connect(to host: Host, password: String? = nil) async {
        guard connecting == nil else { return }
        if host.auth == .password, (password ?? "").isEmpty {
            connectionError = nil
            passwordRequest = host
            return
        }
        connecting = host.id
        connectionError = nil
        failedHost = nil
        defer { connecting = nil }
        do {
            let ws = try await services.connect(host, host.auth == .password ? password : nil)
            let screen = ScreenState(snapshot: Self.loadScreen(for: host.id))
            screen.onChange = { snapshot in Self.saveScreen(snapshot, for: host.id) }
            services.bindScreen(ws, screen)
            session = WorkspaceController(workspace: ws, screen: screen, isDemo: false)
            mode = .live(host)
            UserDefaults.standard.set(host.id.uuidString, forKey: Self.lastHostKey)
        } catch {
            connectionError = error.localizedDescription
            failedHost = host
        }
    }

    func retry() async {
        guard let host = failedHost else { return }
        await connect(to: host)
    }

    /// The host of the last session, until the person disconnects on purpose.
    private static let lastHostKey = "lastHost"

    /// Back into the last session at launch (iOS ends apps in the background
    /// often, and the list of agents is what you open it for).
    /// Not after a deliberate Disconnect; a failure lands on the host list as usual.
    func reconnectLastHost() async {
        guard mode == .none, connecting == nil,
              let id = UserDefaults.standard.string(forKey: Self.lastHostKey).flatMap(UUID.init(uuidString:)),
              let host = hosts.hosts.first(where: { $0.id == id }) else { return }
        await connect(to: host)
    }

    /// Disconnect on purpose: no reconnect at the next launch.
    func disconnectByUser() async {
        if case .live = mode { UserDefaults.standard.removeObject(forKey: Self.lastHostKey) }
        await disconnect()
    }

    func disconnect() async {
        let live: Workspace? = { if case .live = mode { return session?.workspace } else { return nil } }()
        session = nil
        mode = .none
        if let live { await services.disconnect(live) }
    }

    /// Signed in with a password on this connection (the setup sheet offers the key).
    var signedInWithPassword: Bool {
        if case .live(let host) = mode { return host.auth == .password }
        return false
    }

    /// Installs this device's key on the connected computer and switches the host to
    /// key login: the next connection needs no password.
    func installKeyAndSwitch() async throws {
        guard case .live(var host) = mode else { return }
        try await services.installKey()
        host.auth = .key
        hosts.save(host)
        mode = .live(host)
    }

    // MARK: Hosts

    func save(_ host: Host) {
        hosts.save(host)
    }

    func delete(_ host: Host) {
        hosts.delete(host.id)
        services.deletePassword(host.id)
        UserDefaults.standard.removeObject(forKey: Self.screenKey(host.id))
        UserDefaults.standard.removeObject(forKey: SetupOffer.key(host.id))
    }

    // MARK: Per-host screen state

    private static func screenKey(_ id: Host.ID) -> String { "screen.\(id.uuidString)" }

    private static func loadScreen(for id: Host.ID) -> ScreenState.Snapshot {
        guard let data = UserDefaults.standard.data(forKey: screenKey(id)),
              let snap = try? JSONDecoder().decode(ScreenState.Snapshot.self, from: data) else { return .init() }
        return snap
    }

    private static func saveScreen(_ snapshot: ScreenState.Snapshot, for id: Host.ID) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: screenKey(id))
        }
    }
}
