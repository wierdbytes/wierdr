import SwiftUI
import WierdrModel

@main
struct WierdrApp: App {
    @State private var connector: LiveConnector
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppFont.checkRegistered()
        let connector = LiveConnector()
        _connector = State(initialValue: connector)
        _app = State(initialValue: AppModel(services: connector.services))
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG || WIERDR_LAB
            if UserDefaults.standard.bool(forKey: "terminal-lab") {
                TerminalLabView()
            } else {
                mainRoot
            }
            #else
            mainRoot
            #endif
        }
        .commands { WorkspaceCommands() }
        .onChange(of: scenePhase) { _, phase in connector.scenePhaseChanged(phase) }
    }

    private var mainRoot: some View {
        RootView()
            .environment(app)
            .environment(\.services, app.services)
            .environment(\.terminalViewProvider, app.services.terminalViews)
            .task {
                // `-demo YES` (UserDefaults `demo`) opens the demo directly (screenshots, UI tests).
                if UserDefaults.standard.bool(forKey: "demo"), app.mode == .none { app.startDemo() }
                #if DEBUG
                await DebugAutoConnect.run(app)
                #endif
                if !UserDefaults.standard.bool(forKey: "demo") { await app.reconnectLastHost() }
                #if DEBUG
                // `-open switcher|settings|space:<id>` (screenshots).
                if let open = UserDefaults.standard.string(forKey: "open"), let s = app.session {
                    try? await Task.sleep(for: .milliseconds(600))
                    if open == "switcher" { s.showSwitcher = true }
                    if open == "settings" { s.showSettings = true }
                    // iPhone: the first agent's pane (also before `banner`).
                    if open == "pane" || open == "banner",
                       let pane = s.workspace.spaces.first(where: { $0.status == .done })?.tabs.first?.panes.first {
                        s.focus(pane: pane.id)
                    }
                    if open.hasPrefix("space:"), let sp = s.workspace.space(String(open.dropFirst(6))),
                       let pane = sp.tabs.first?.panes.first { s.focus(pane: pane.id, reveal: false) }
                }
                // `-orientation landscape|portrait` (screenshots in the simulator).
                if let o = UserDefaults.standard.string(forKey: "orientation") {
                    let mask: UIInterfaceOrientationMask = o == "landscape" ? .landscapeRight : .portrait
                    let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                    scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                }
                #endif
            }
            .environment(connector)
            .hostKeyAlert(connector.active)
    }
}

/// Switches between the connect screen and an open session; applies the
/// appearance override and resolves the theme.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance: AppearanceOverride = .system

    var body: some View {
        Group {
            if let session = app.session {
                WorkspaceView(controller: session, hostName: hostName) {
                    Task { await app.disconnectByUser() }
                }
                .id(ObjectIdentifier(session))
            } else {
                ConnectView()
            }
        }
        .resolvingTheme()
        .preferredColorScheme(appearance.colorScheme)
    }

    private var hostName: String? {
        if case .live(let host) = app.mode { return host.displayName }
        return nil
    }
}
