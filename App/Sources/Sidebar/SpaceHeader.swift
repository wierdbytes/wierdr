import SwiftUI
import WierdrModel

/// A space card's header (§4.3): avatar, name, git tail, the agents' summary while the
/// card is folded, show/hide chevron (`SpaceHeaderBar`). 44 pt, at the card's bottom (the
/// list is drawn bottom up: a header is under what it names), a hairline over it when
/// rows show.
///
/// A tap: on the iPad it selects the space (its tab shows in the panel); in the iPhone
/// layout, where nothing is selected, it folds or unfolds the card, as the chevron does.
/// Held, its menu (`SpaceHeaderMenu`), and moved on, the card is dragged (`SpaceDrag`):
/// both are the list's own long press (`SpaceListDragDrop`), which finds the header by
/// its marker.
struct SpaceHeader: View {
    var space: Space
    var hasRows: Bool
    var closed: Bool
    var bodyShown: Bool

    static let height: CGFloat = 44

    @Environment(WorkspaceController.self) private var controller
    @Environment(SpaceDrag.self) private var drag: SpaceDrag?
    @State private var hovering = false

    var body: some View {
        let isActive = !controller.singlePane && controller.activeSpace?.id == space.id
        // Held for its menu: it shrinks 15 pt narrower (Telegram's).
        let shrunk = drag?.pressing == "space:\(space.id)"
        SpaceHeaderBar(space: space, hasRows: hasRows, closed: closed, bodyShown: bodyShown,
                       isActive: isActive, hovering: hovering, toggle: toggle)
            .visualEffect { content, proxy in
                content.scaleEffect(shrunk ? max(0.7, (proxy.size.width - 15) / max(1, proxy.size.width)) : 1)
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
            // Its menu's New Tab lists the agents installed there.
            .onAppear { controller.workspace.refreshLaunchers(machine: space.machine) }
            .background {
                // Not in the lifted card's picture (`ImageRenderer` draws a UIKit view as a placeholder).
                if let drag { SpaceMarker(space: space.id, role: .header, markers: drag.markers) }
            }
            .tutorialAnchor(.spaceHeader(space.id))
            // Lifted by its menu: the menu's picture stands in for it.
            .opacity(drag?.menuLifted == "space:\(space.id)" ? 0 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Space \(space.displayName)")
            .accessibilityValue(Format.summary(controller.workspace.agentCounts(in: space.id)))
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: closed ? "Show tabs" : "Hide tabs") { toggle() }
            // The menu is UIKit's, on the list: VoiceOver gets its items here.
            .accessibilityAction(named: "Rename") { controller.beginRename(space: space.id) }
            .accessibilityAction(named: "New Terminal Tab") { controller.newTab(launch: .shell, in: space) }
            .accessibilityAction(named: "Close Space") { controller.closeSpace(space.id) }
    }

    private func toggle() {
        withAnimation(SpaceCard.fold) {
            if closed { controller.closedSpaces.remove(space.id) } else { controller.closedSpaces.insert(space.id) }
        }
    }
}

/// What a card's header draws: its line on its ground (opaque: folding, the rows slide
/// down under it into the card's bottom edge), the hairline over it while rows show. Also
/// the picture its menu lifts (`SpaceListDragDrop.headerPreview`).
struct SpaceHeaderBar: View {
    var space: Space
    var hasRows: Bool
    var closed: Bool
    var bodyShown: Bool
    var isActive: Bool
    var hovering: Bool
    var toggle: (() -> Void)? = nil

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.rowGround) private var ground
    @State private var chevronHover = false

    var body: some View {
        HStack(spacing: 10) {
            SpaceAvatar(space: space, size: 22)
            Text(space.displayName)
                .font(.ui(16, .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            gitTail
                .frame(maxWidth: .infinity, alignment: .trailing)
            if closed {
                StatusBadges(counts: controller.workspace.agentCounts(in: space.id))
            }
            chevron
        }
        .padding(.leading, PhoneRowMetrics.inset - 2)
        .padding(.trailing, 8)
        .frame(height: SpaceHeader.height)
        // Moves as one while the card folds: the summary coming or going comes in its place
        // here, not at the card's top as the card's own geometry would put it.
        .geometryGroup()
        .background {
            ZStack {
                ground ?? theme.surface
                fill
            }
        }
        .overlay(alignment: .top) {
            if bodyShown { Hairline() }
        }
    }

    private var fill: Color {
        if isActive { return theme.accent.opacity(hovering ? 0.20 : 0.15) }
        return hovering ? theme.selected : theme.hover
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
            .font(.ui(13))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if hasRows {
            Button { toggle?() } label: {
                // Open, it points up, at the rows over the header.
                Icon("chevron-right", size: 14, color: chevronHover ? theme.foreground : theme.dim)
                    .rotationEffect(.degrees(closed ? 0 : -90))
                    .frame(width: 32, height: 32)
                    .background(chevronHover ? theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { chevronHover = $0 }
            .hoverEffect(.highlight)
            .tutorialAnchor(.spaceChevron(space.id))
            .accessibilityLabel(closed ? "Show tabs" : "Hide tabs")
        } else {
            Color.clear.frame(width: 32, height: 20)
        }
    }
}

/// The space menu (§7), the list's own (`SpaceListDragDrop` shows it held on a header):
/// Rename…, New Tab › (a terminal or an agent installed on its machine), Close Space.
@MainActor
enum SpaceHeaderMenu {
    static func menu(space id: String, controller: WorkspaceController) -> PhoneMenu {
        guard let space = controller.workspace.space(id) else { return [] }
        let launchers = controller.workspace.launchers[space.machine ?? ""] ?? []
        var tabs: [PhoneMenuItem] = [PhoneMenuItem(title: "Terminal", icon: .asset("program.shell")) {
            controller.newTab(launch: .shell, in: space)
        }]
        if launchers.isEmpty {
            tabs.append(PhoneMenuItem(title: "Checking installed agents…", icon: .system("hourglass"), disabled: true))
        }
        for launcher in launchers where launcher.installed == true {
            tabs.append(PhoneMenuItem(title: launcher.program.name, icon: .asset(launcher.program.iconAsset)) {
                controller.newTab(launch: .agent(launcher, task: nil), in: space)
            })
        }
        return [
            [PhoneMenuItem(title: "Rename…", icon: .asset("ui.square-pen")) { controller.beginRename(space: id) },
             PhoneMenuItem(title: "New Tab", icon: .asset("ui.plus"), children: [tabs])],
            [PhoneMenuItem(title: "Close Space", icon: .asset("ui.x"), destructive: true) { controller.closeSpace(id) }],
        ]
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
                        .font(.ui(13, .semibold))
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
