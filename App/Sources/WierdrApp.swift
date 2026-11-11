import SwiftUI
import WierdrModel

@main
struct WierdrApp: App {
    /// Wire the live connection here (SSH + HerdrCore): replace `.placeholder`
    /// with `AppServices(connect: …, terminalViews: …)`.
    @State private var app = AppModel(services: .placeholder)

    init() {
        AppFont.checkRegistered()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(\.services, app.services)
                .environment(\.terminalViewProvider, app.services.terminalViews)
                .task {
                    // `-demo YES` (UserDefaults `demo`) opens the demo directly (screenshots, UI tests).
                    if UserDefaults.standard.bool(forKey: "demo"), app.mode == .none { app.startDemo() }
                    #if DEBUG
                    // `-open switcher|settings|space:<id>` (screenshots).
                    if let open = UserDefaults.standard.string(forKey: "open"), let s = app.session {
                        try? await Task.sleep(for: .milliseconds(600))
                        if open == "switcher" { s.showSwitcher = true }
                        if open == "settings" { s.showSettings = true }
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
        }
        .commands { WorkspaceCommands() }
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
                    Task { await app.disconnect() }
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
