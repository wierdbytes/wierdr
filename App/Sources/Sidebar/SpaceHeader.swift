import SwiftUI
import WierdrModel

/// A space card's header (§4.3): avatar, name, git tail, status summary when
/// the body is hidden, show/hide chevron. 34 pt.
struct SpaceHeader: View {
    var space: Space
    var rows: [SidebarRow]
    var closed: Bool
    var bodyShown: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact
    @State private var hovering = false
    @State private var chevronHover = false

    var body: some View {
        let isActive = controller.activeSpace?.id == space.id
        HStack(spacing: 9) {
            SpaceAvatar(space: space, size: compact ? 20 : 18)
            Text(space.displayName)
                .font(.ui(compact ? 14.5 : 13, .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: compact ? 230 : 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            gitTail
                .frame(maxWidth: .infinity, alignment: .trailing)
            if closed {
                StatusSummary(counts: counts)
            }
            chevron
        }
        .padding(.leading, 13)
        .padding(.trailing, 11)
        .frame(height: compact ? 42 : 34)
        .background {
            let r: CGFloat = 9
            UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: bodyShown ? 0 : r,
                                   bottomTrailingRadius: bodyShown ? 0 : r, topTrailingRadius: r)
                .fill(headerFill(isActive: isActive))
                .padding(.horizontal, 1).padding(.top, 1).padding(.bottom, bodyShown ? 0 : 1)
        }
        .overlay(alignment: .bottom) {
            if bodyShown { Hairline().padding(.horizontal, 1) }
        }
        .padding(.bottom, bodyShown ? 0 : 6)
        .contentShape(.contextMenuPreview, UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: bodyShown ? 0 : 10, bottomTrailingRadius: bodyShown ? 0 : 10, topTrailingRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            controller.select(space: space)
            controller.showPanel()
        }
        .contextMenu { SpaceMenu(space: space) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Space \(space.displayName)")
        .accessibilityValue(Format.summary(counts))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: closed ? "Show tabs" : "Hide tabs") { toggle() }
    }

    private func headerFill(isActive: Bool) -> Color {
        if isActive { return theme.accent.opacity(hovering ? 0.20 : 0.15) }
        return hovering ? theme.selected : theme.hover
    }

    /// Its agents by status, and the sub-agents under them (never done; §4.6).
    private var counts: [AgentStatus: Int] {
        controller.workspace.agentCounts(in: space.id)
    }

    @ViewBuilder
    private var gitTail: some View {
        let git = space.git
        let tail = Format.gitTail(space)
        if tail != nil || (git?.ahead ?? 0) > 0 || (git?.behind ?? 0) > 0 {
            HStack(spacing: 5) {
                if let tail {
                    Text(tail).lineLimit(1).truncationMode(.tail).foregroundStyle(theme.dim)
                }
                if let n = git?.ahead, n > 0 { Text("↑\(n)").foregroundStyle(theme.ansi(2)) }
                if let n = git?.behind, n > 0 { Text("↓\(n)").foregroundStyle(theme.ansi(1)) }
            }
            .font(.ui(compact ? 12.5 : 11.5))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if !rows.isEmpty {
            Button(action: toggle) {
                Icon(closed ? "chevron-right" : "chevron-down", size: compact ? 14 : 12, color: chevronHover ? theme.foreground : theme.dim)
                    .frame(width: compact ? 32 : 20, height: compact ? 32 : 20)
                    .background(chevronHover ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { chevronHover = $0 }
            .hoverEffect(.highlight)
            .padding(.trailing, -4)
            .accessibilityLabel(closed ? "Show tabs" : "Hide tabs")
        } else {
            Color.clear.frame(width: compact ? 32 : 20, height: 20).padding(.trailing, -4)
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if closed { controller.closedSpaces.remove(space.id) } else { controller.closedSpaces.insert(space.id) }
        }
    }
}

/// The space menu (§7): Rename, New tab, Close.
struct SpaceMenu: View {
    var space: Space
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        Button { controller.beginRename(space: space.id) } label: { Label("Rename…", image: "ui.square-pen") }
        if compact {
            // iPhone: no tab bar with its + menu, so agents start from here too.
            Menu {
                LaunchMenuItems(machine: space.machine) { controller.newTab(launch: $0, in: space) }
            } label: { Label("New Tab", image: "ui.plus") }
        } else {
            Button { controller.newTab(in: space) } label: { Label("New Tab", image: "ui.plus") }
        }
        Divider()
        Button(role: .destructive) { controller.closeSpace(space.id) } label: { Label("Close Space", image: "ui.x") }
    }
}
