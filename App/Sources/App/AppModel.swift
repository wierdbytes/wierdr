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

    let hosts = HostStore()
    @ObservationIgnored var services: AppServices

    init(services: AppServices = .placeholder) {
        self.services = services
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
    func connect(to host: Host, password: String? = nil) async {
        guard connecting == nil else { return }
        connecting = host.id
        connectionError = nil
        failedHost = nil
        defer { connecting = nil }
        do {
            let pw = password ?? (host.auth == .password ? services.loadPassword(host.id) : nil)
            let ws = try await services.connect(host, pw)
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

    /// iPhone: back into the last session at launch (iOS ends apps in the
    /// background often, and the list of agents is what you open it for).
    /// Not after a deliberate Disconnect; a failure lands on the host list as usual.
    func reconnectLastHost() async {
        guard Device.isPhone, mode == .none, connecting == nil,
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

    /// Installs this device's key on the connected computer and switches the
    /// host to key login (the saved password is deleted).
    func installKeyAndSwitch() async throws {
        guard case .live(var host) = mode else { return }
        try await services.installKey()
        host.auth = .key
        hosts.save(host)   // the saved password stays until key login has worked once
        mode = .live(host)
    }

    // MARK: Hosts

    func save(_ host: Host, password: String?) {
        hosts.save(host)
        if host.auth == .password, let password, !password.isEmpty {
            services.savePassword(host.id, password)
        } else if host.auth == .key {
            services.deletePassword(host.id)
        }
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
