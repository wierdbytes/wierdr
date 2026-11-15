import SwiftUI
import WierdrModel

/// The work column: tab bar, the active tab's panes on `canvas`, and under
/// all of them the message field (`ComposerBar`) for the focused pane, named
/// in its placeholder (hidden while that terminal has the keyboard itself).
/// Over the panes, the key panel and the ways it and the keyboards come
/// (`KeyPanelLayer`), for the focused pane: drawn once over the whole window
/// (`KeyLayerHost`, so over a sub-agent's window too), placed over the panes,
/// whose frame this column reports (`controller.keyArea`).
struct TerminalPanel: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    /// The panes' and the field's height: how tall the field may grow.
    @State private var room: CGFloat = 0

    var body: some View {
        let address = controller.focusedPane?.terminal
        VStack(spacing: 0) {
            TabBar()
            VStack(spacing: 0) {
                Group {
                    if let tab = controller.activeTab {
                        PaneTreeView(tab: tab)
                    } else {
                        EmptyPanel()
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.keyArea = $0 }
                .overlay(alignment: .bottomTrailing) { ToastStack().padding(16).padding(.trailing, controller.keys.trailingInset) }
                if let address, services.terminalSession(address)?.hasKeyboardFocus != true {
                    ComposerBar(address: address, placeholder: "Message to \(Format.paneName(controller.workspace.terminal(address)))",
                                placement: .panel, room: room)
                        .id(address)
                }
            }
            .background(theme.canvas.ignoresSafeArea(edges: .bottom))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
        }
        .background(theme.chrome.ignoresSafeArea())
        .overlay(alignment: .top) { ConnectionBanner() }
        // Another pane: its keyboard goes (the draft stays with its terminal).
        .onChange(of: address) { controller.closeCompose() }
        .onDisappear { controller.composing = nil }
    }
}

/// No spaces at all: a hint and the New space button.
private struct EmptyPanel: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image("BrandMark").resizable().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                .opacity(0.8)
            Text("No spaces yet").font(.ui(15, .semibold)).foregroundStyle(theme.foreground)
            Button("New Space") { controller.newSpace() }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom-trailing transient messages (3 s).
struct ToastStack: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(controller.toasts) { toast in
                HStack(spacing: 10) {
                    Text(toast.message)
                        .font(.ui(12.8))
                        .foregroundStyle(theme.foreground)
                        .multilineTextAlignment(.leading)
                    Button { controller.dismiss(toast) } label: { Icon("x", size: 12, color: theme.dim) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 380, alignment: .leading)
                .background(theme.popover, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 12, y: 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

/// "Reconnecting…" / failure banner from `Workspace.phase`.
struct ConnectionBanner: View {
    /// Distance from `edge` (past the bar it hangs from).
    var inset: CGFloat = 48
    /// The edge it hangs from: the top (under a bar), the bottom (over the iPhone list's header).
    var edge: VerticalEdge = .top
    @Environment(WorkspaceController.self) private var controller
    @Environment(LiveConnector.self) private var connector: LiveConnector?
    @Environment(\.theme) private var theme

    var body: some View {
        switch controller.workspace.phase {
        case .live:
            EmptyView()
        case .connecting:
            banner("Connecting…", color: theme.muted, spinner: true)
        case .reconnecting(let why):
            banner("Reconnecting… \(why)", color: theme.working, spinner: true)
        case .failed(let why):
            HStack(spacing: 6) {
                banner(why, color: theme.blocked, spinner: false)
                if let session = connector?.active, session.workspace === controller.workspace {
                    Button("Retry") { session.retry() }
                        .font(.ui(12, .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(theme.popover, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
                        .padding(edge == .top ? .top : .bottom, inset)
                }
            }
        }
    }

    private func banner(_ text: String, color: Color, spinner: Bool) -> some View {
        HStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text).font(.ui(12)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(theme.popover, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 1))
        .padding(edge == .top ? .top : .bottom, inset)
    }
}

/// The iPad's key panel, once, over everything: the panes, the sidebar
/// overlay's edge, a sub-agent's window (`SubAgentPeek`). Placed over the
/// panel's panes (`controller.keyArea`); for the focused pane's terminal, or
/// the sub-agent looked at while its window is up.
struct KeyLayerHost: View {
    @Environment(WorkspaceController.self) private var controller
    /// This layer's own origin in the window (the panes' frame is global).
    @State private var origin: CGPoint = .zero

    var body: some View {
        @Bindable var controller = controller
        let area = controller.keyArea
        ZStack(alignment: .topLeading) {
            if area.width > 0, area.height > 0 {
                // Not hit-testable: touches go through to the panes (or the window) under it,
                // but for the panel.
                Color.clear
                    .frame(width: area.width, height: area.height)
                    .keyPanel(address: controller.peek ?? controller.focusedPane?.terminal,
                              covered: controller.sidebarOverlay, state: $controller.keys)
                    .padding(.leading, area.minX - origin.x)
                    .padding(.top, area.minY - origin.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        .ignoresSafeArea(.keyboard)
    }
}
