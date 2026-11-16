import SwiftUI
import WierdrModel

/// A space card's header (§4.3): avatar, name, git tail, the agents' summary while the
/// card is folded, show/hide chevron. 44 pt, on the card's top.
///
/// A tap: on the iPad it selects the space (its tab shows in the panel); in the iPhone
/// layout, where nothing is selected, it folds or unfolds the card, as the chevron does.
/// Held, its menu (`SpaceMenu`), and moved on, the card is dragged (`SpaceDrag`; the
/// list's own interactions, `SpaceListInteractions`, which find the header by its
/// marker, so the menu is theirs too).
struct SpaceHeader: View {
    var space: Space
    var hasRows: Bool
    var closed: Bool
    var bodyShown: Bool

    static let height: CGFloat = 44

    @Environment(WorkspaceController.self) private var controller
    @Environment(SpaceDrag.self) private var drag: SpaceDrag?
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var chevronHover = false

    var body: some View {
        let isActive = !controller.singlePane && controller.activeSpace?.id == space.id
        HStack(spacing: 10) {
            SpaceAvatar(space: space, size: 22)
            Text(space.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            gitTail
                .frame(maxWidth: .infinity, alignment: .trailing)
            if closed {
                StatusBadges(counts: counts)
            }
            chevron
        }
        .padding(.leading, PhoneRowMetrics.inset - 2)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        .background(headerFill(isActive: isActive))
        .overlay(alignment: .bottom) {
            if bodyShown { Hairline() }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if controller.singlePane {
                toggle()
            } else {
                controller.select(space: space)
                controller.showPanel()
            }
        }
        .contextMenu { SpaceMenu(space: space) }
        // Its menu's New Tab lists the agents installed there.
        .onAppear { controller.workspace.refreshLaunchers(machine: space.machine) }
        .background {
            // Not in the lifted card's picture (`ImageRenderer` draws a UIKit view as a placeholder).
            if let drag { SpaceMarker(space: space.id, role: .header, markers: drag.markers) }
        }
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
            .font(.system(size: 13))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if hasRows {
            Button(action: toggle) {
                Icon(closed ? "chevron-right" : "chevron-down", size: 14, color: chevronHover ? theme.foreground : theme.dim)
                    .frame(width: 32, height: 32)
                    .background(chevronHover ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { chevronHover = $0 }
            .hoverEffect(.highlight)
            .accessibilityLabel(closed ? "Show tabs" : "Hide tabs")
        } else {
            Color.clear.frame(width: 32, height: 20)
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if closed { controller.closedSpaces.remove(space.id) } else { controller.closedSpaces.insert(space.id) }
        }
    }
}

/// The space menu (§7): Rename, New tab, Close.
struct SpaceMenu: View {
    var space: Space
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        Button { controller.beginRename(space: space.id) } label: { Label("Rename…", image: "ui.square-pen") }
        Menu {
            LaunchMenuItems(machine: space.machine) { controller.newTab(launch: $0, in: space) }
        } label: { Label("New Tab", image: "ui.plus") }
        Divider()
        Button(role: .destructive) { controller.closeSpace(space.id) } label: { Label("Close Space", image: "ui.x") }
    }
}

/// A folded card's (or machine's) agents by status, as the header's counts: a round
/// badge filled with its status's color and their number, for needs you, done and
/// working (idle has none), most urgent first.
struct StatusBadges: View {
    var counts: [AgentStatus: Int]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach([AgentStatus.blocked, .done, .working], id: \.self) { status in
                if let n = counts[status], n > 0 {
                    Text("\(n)")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(theme.color(for: status), in: Capsule())
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.summary(counts))
    }
}
