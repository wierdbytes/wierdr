import SwiftUI
import WierdrModel

/// The work column: tab bar, the active tab's panes on `canvas`, the status bar.
struct TerminalPanel: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Group {
                if let tab = controller.activeTab {
                    PaneTreeView(tab: tab)
                } else {
                    EmptyPanel()
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.canvas)
            .overlay(alignment: .bottomTrailing) { ToastStack().padding(16) }
            StatusBar()
        }
        .background(theme.chrome.ignoresSafeArea())
        .overlay(alignment: .top) { ConnectionBanner() }
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

/// The status bar (§9): agent counts; tap → next agent with that status.
struct StatusBar: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let counts = controller.workspace.statusCounts
        HStack(spacing: 14) {
            ForEach([AgentStatus.blocked, .done, .working, .idle], id: \.self) { status in
                let n = counts[status] ?? 0
                if n > 0 || status == .working || status == .idle {
                    StatusCount(status: status, count: n)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(theme.chrome)
        .overlay(alignment: .top) { Hairline() }
    }
}

private struct StatusCount: View {
    var status: AgentStatus
    var count: Int
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { controller.focusNext(status: status) } label: {
            HStack(spacing: 6) {
                StatusMark(status: status, tint: status == .working && count == 0 ? theme.dim : nil)
                Text("\(count)")
                    .font(.ui(11.5))
                    .foregroundStyle(count == 0 ? theme.dim : (status == .blocked ? theme.blocked : (hovering ? theme.foreground : theme.muted)))
            }
            .padding(.horizontal, 4)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .onHover { hovering = $0 }
        .hoverEffect(.highlight)
        .padding(.horizontal, -4)
        .accessibilityLabel("\(count) \(Format.statusWord(status))")
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
private struct ConnectionBanner: View {
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
                        .padding(.top, 48)
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
        .padding(.top, 48)
    }
}
