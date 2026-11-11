import SwiftUI
import WierdrModel

// SwiftUI previews of the main pieces, on `Workspace.preview()`.

@MainActor
private func demoController() -> WorkspaceController {
    let ws = Workspace.preview()
    let screen = ScreenState()
    if let pane = ws.spaces.first?.tabs.first?.panes.first { screen.focus(pane: pane.id, in: ws) }
    return WorkspaceController(workspace: ws, screen: screen, isDemo: true)
}

private struct PreviewHost<Content: View>: View {
    var scheme: ColorScheme = .dark
    @ViewBuilder var content: (WorkspaceController) -> Content
    @State private var controller = demoController()

    var body: some View {
        content(controller)
            .environment(controller)
            .environment(\.homeFolder, controller.workspace.home)
            .resolvingTheme()
            .preferredColorScheme(scheme)
    }
}

#Preview("Workspace", traits: .landscapeLeft) {
    PreviewHost { c in WorkspaceView(controller: c, hostName: nil, onDisconnect: {}) }
}

#Preview("Workspace (light)", traits: .landscapeLeft) {
    PreviewHost(scheme: .light) { c in WorkspaceView(controller: c, hostName: nil, onDisconnect: {}) }
}

#Preview("Sidebar") {
    PreviewHost { _ in SidebarView().frame(width: 320) }
}

#Preview("Terminal panel") {
    PreviewHost { _ in TerminalPanel() }
}

#Preview("Tab bar") {
    PreviewHost { _ in TabBar().frame(width: 700) }
}

#Preview("Status marks") {
    PreviewHost { _ in
        HStack(spacing: 16) {
            ForEach([AgentStatus.working, .blocked, .done, .idle], id: \.self) { StatusMark(status: $0) }
            StatusMark(status: .blocked, style: .full)
        }
        .padding()
        .background(Theme.atomOneDark.chrome)
    }
}

#Preview("Quick switcher") {
    PreviewHost { _ in QuickSwitcher() }
}

#Preview("Connect") {
    ConnectView().environment(AppModel())
}

#Preview("Settings") {
    SettingsView(hostName: "Studio", isDemo: false, onDisconnect: {})
}
