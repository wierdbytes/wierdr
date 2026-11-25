import SwiftUI
import WierdrModel

/// The iPad's tab bar, in the app's glass (the message field's and the iPhone's top bar's,
/// `composerGlass`), on the panes' ground with no bar of its own: at its left the sidebar
/// button (a glass circle: hides the docked sidebar, docks the hidden one), the active
/// space's tabs as glass capsules (`TabPill`, laid out by `TabStripLayout`), at its right
/// + (`NewMenu`). Its sides are the pane cards' (8 pt in), so are the message field's.
struct TabBar: View {
    /// The capsules' and the circles' height.
    static let height: CGFloat = 36
    static let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            SidebarButton()
            TabStrip()
            NewMenu()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .clearsWindowControls()
        .frame(maxWidth: .infinity)
    }
}

/// The sidebar's button, left of the tabs: docked, it hides the sidebar (its overlay comes
/// with a swipe right on a terminal, `SidebarOverlay`); hidden, it docks it again (with the
/// overlay out, it puts the overlay away, as ⌘B).
private struct SidebarButton: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let hidden = controller.columnVisibility == .detailOnly
        Button { controller.toggleSidebar() } label: {
            Icon("sidebar", size: 18, color: theme.foreground)
                .frame(width: TabBar.height, height: TabBar.height)
                .contentShape(Circle())
        }
        .buttonStyle(AttachPressStyle())
        .composerGlass(Circle(), theme: theme)
        .hoverEffect(.highlight)
        .tutorialAnchor(.sidebarButton)
        .accessibilityLabel(hidden ? "Show Sidebar" : "Hide Sidebar")
    }
}

/// The active space's tabs in one row: each at its full width while they all fit, else
/// the widest cut to a common width (`TabStripLayout`); scrolled sideways only when even
/// the narrowest form doesn't fit, the active tab kept in view. Held, a tab shows its menu
/// and is dragged to another place, as the sidebar's rows and cards (`TabDrag`).
private struct TabStrip: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// The row's room (its width on screen).
    @State private var room: CGFloat = 0
    @State private var drag = TabDrag()

    var body: some View {
        let ws = controller.workspace
        let active = controller.activeTab
        let space = controller.activeSpace
        let tabs = space.map { drag.arranged($0.tabs, space: $0.id) } ?? []
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Each tab's glass its own, not in one container: a container draws its glass
                // itself, so a tab hidden for its menu or its drag (its opacity) still showed,
                // and the capsules morphed into each other as they slid apart.
                TabStripLayout(spacing: TabBar.spacing, room: room) {
                    ForEach(tabs) { tab in
                        TabPill(tab: tab, isActive: tab.id == active?.id,
                                zoomed: controller.screen.zoomedPane(of: tab) != nil, workspace: ws)
                            .id(tab.id)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: active?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: TabBar.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
        .background { TabDragHost(drag: drag, controller: controller, theme: theme) }
        .environment(drag)
        .onChange(of: space?.tabs.map(\.id)) { _, _ in drag.settle() }
    }
}

/// Lays the tabs in a row: at their full widths when they fit in `room`; else every tab
/// wider than a common cap is cut to it (its text ends in "…"), the cap as wide as lets
/// them fit, the narrower ones whole. The cap never goes under `least`: past that the
/// row is wider than its room (and scrolls).
struct TabStripLayout: Layout {
    var spacing: CGFloat
    var room: CGFloat
    /// The narrowest a cut tab gets: its icon and a few letters.
    static let least: CGFloat = 84

    static func widths(ideal: [CGFloat], room: CGFloat, spacing: CGFloat) -> [CGFloat] {
        let available = room - spacing * CGFloat(max(0, ideal.count - 1))
        guard ideal.reduce(0, +) > available, room > 0 else { return ideal }
        // Water-filling: the narrowest that fit within an equal share of what's left keep
        // their width; the share where the next one doesn't is the cap.
        var left = available
        var cap = least
        for (i, w) in ideal.sorted().enumerated() {
            let share = left / CGFloat(ideal.count - i)
            if w > share { cap = max(share, least); break }
            left -= w
        }
        return ideal.map { min($0, cap) }
    }

    private func widths(_ subviews: Subviews) -> [CGFloat] {
        Self.widths(ideal: subviews.map { ceil($0.sizeThatFits(.unspecified).width) }, room: room, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (sub, width) in zip(subviews, widths(subviews)) {
            sub.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// One tab: a glass capsule with its session's program icon and title, as its row in the
/// sidebar reads (`subject`); the active one lighter, its text bright; the tab's status (its
/// most urgent agent's) as a keyline in its color, as the iPhone's title capsule. A tap
/// selects it. Held, as the sidebar's rows: it shrinks, then its menu (`TabMenu`) over a dim,
/// the tab lifted; moved on, it's dragged to another place (`TabDrag`): meanwhile its place
/// is a dashed slot.
struct TabPill: View {
    var tab: Tab
    var isActive: Bool
    var zoomed: Bool
    var workspace: Workspace

    @Environment(WorkspaceController.self) private var controller
    @Environment(TabDrag.self) private var drag: TabDrag?
    @Environment(\.theme) private var theme

    /// The pane the tab is named after: its focused pane when that runs an agent, else its
    /// first agent's, else the focused one (a tab of terminals).
    static func subject(of tab: Tab, focused: Pane?, in ws: Workspace) -> Pane? {
        let isAgent = { (p: Pane) in ws.terminal(p.terminal)?.isAgent == true }
        if let focused, isAgent(focused) { return focused }
        return tab.panes.first(where: isAgent) ?? focused ?? tab.panes.first
    }

    /// The subject's title as the sidebar's row has it: an agent's session (`AgentText.title`),
    /// a terminal's process, a desktop panel's name.
    static func title(of tab: Tab, pane: Pane?, in ws: Workspace) -> String {
        guard let pane else { return tab.displayName }
        guard let t = ws.terminal(pane.terminal) else { return pane.mod ?? "panel" }
        return t.isAgent ? Format.agentTitle(t, tab: tab) : Format.processName(t)
    }

    /// Its agents' most urgent status, read from their terminals (as the engine's
    /// `Tab.status`, which the demo's local changes don't redo).
    static func status(of tab: Tab, in ws: Workspace) -> AgentStatus? {
        AgentStatus.rollup(tab.panes.map { ws.terminal($0.terminal)?.status })
    }

    /// Needs you, done, working: its color; idle or none: no line.
    static func keyline(_ status: AgentStatus?, theme: Theme) -> Color? {
        guard let status, status != .idle else { return nil }
        return theme.color(for: status)
    }

    var body: some View {
        let face = TabFace(tab: tab, controller: controller)
        let status = Self.status(of: tab, in: workspace)
        let shape = Capsule()
        let slot = drag?.dragged == tab.id
        let shrunk = drag?.pressing == tab.id
        TabLabel(face: face, isActive: isActive, zoomed: zoomed)
            .background(isActive ? theme.selected : .clear, in: shape)
            // The status on the glass, not through it.
            .overlay {
                shape.strokeBorder(lineWidth: 1.5)
                    .animation(.easeInOut(duration: 0.25)) { $0.foregroundStyle(Self.keyline(status, theme: theme) ?? .clear) }
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            // Not swelling under the finger: held, it shrinks for its menu instead.
            .composerGlass(shape, theme: theme, interactive: false)
            // Held: 15 pt narrower by the menu's time (Telegram's, as the sidebar's rows).
            .visualEffect { content, proxy in
                content.scaleEffect(shrunk ? max(0.7, (proxy.size.width - 15) / max(1, proxy.size.width)) : 1)
            }
            // Lifted by its menu, or dragged: its picture stands in for it.
            .opacity(slot || drag?.menuLifted == tab.id ? 0 : 1)
            .background {
                if slot {
                    shape.fill(theme.accent.opacity(0.05))
                        .overlay(shape.strokeBorder(theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .background {
                if let drag { TabMarker(id: tab.id, markers: drag.markers) }
            }
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
            .onTapGesture { controller.select(tab: tab) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tab \(face.title)\(status.map { ", " + Format.statusWord($0) } ?? "")")
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            // VoiceOver: the menu's items as the tab's actions.
            .accessibilityActions {
                ForEach(TabMenu.menu(tab: tab.id, controller: controller).joined().filter { !$0.disabled && $0.children == nil }) { item in
                    Button(item.title) { item.run() }
                }
            }
    }
}

/// What a tab is named after (`TabPill.subject`): its title and program.
struct TabFace {
    var title: String
    var program: Program?
    /// A desktop panel's pane (no terminal).
    var isPanel: Bool

    @MainActor init(tab: Tab, controller: WorkspaceController) {
        let ws = controller.workspace
        let pane = TabPill.subject(of: tab, focused: controller.screen.focusedPane(of: tab), in: ws)
        title = TabPill.title(of: tab, pane: pane, in: ws)
        program = ws.terminal(pane?.terminal)?.program
        isPanel = pane != nil && pane?.terminal == nil
    }
}

/// A tab's content, without its glass: icon, title (cut with "…" when narrower than it),
/// the zoom's mark.
struct TabLabel: View {
    var face: TabFace
    var isActive: Bool
    var zoomed: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let color = isActive ? theme.foreground : theme.muted
        HStack(spacing: 7) {
            if let program = face.program {
                ProgramIcon(program: program, size: 15, color: color)
            } else {
                Icon(face.isPanel ? "file-text" : "terminal", size: 15, color: color)
            }
            Text(face.title)
                .font(.ui(14, isActive ? .medium : .regular))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
            if zoomed {
                Icon("zoom", size: 12, color: theme.dim)
                    .accessibilityLabel("Zoomed")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: TabBar.height)
    }
}

/// A tab drawn afresh for its menu and its drag (`TabDragDrop`): the glass as its drawn
/// stand-in (opaque, over the panes' ground), or lifted: raised, with an accent edge,
/// as the sidebar's dragged card.
struct TabPicture: View {
    enum Style { case resting, lifted }
    var tab: Tab
    var style: Style

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let isActive = controller.activeTab?.id == tab.id
        let shape = Capsule()
        let keyline = TabPill.keyline(TabPill.status(of: tab, in: controller.workspace), theme: theme)
        TabLabel(face: TabFace(tab: tab, controller: controller), isActive: isActive,
                 zoomed: controller.screen.zoomedPane(of: tab) != nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isActive ? theme.selected : .clear, in: shape)
            .background {
                if style == .lifted {
                    shape.fill(theme.raised)
                } else {
                    ZStack {
                        shape.fill(theme.canvas)
                        shape.fill(theme.isDark ? theme.raised.opacity(0.85) : theme.background.opacity(0.7))
                    }
                }
            }
            .overlay {
                if let keyline {
                    shape.strokeBorder(keyline, lineWidth: 1.5)
                } else if style == .lifted {
                    shape.strokeBorder(theme.accent.opacity(0.6), lineWidth: 1)
                } else {
                    shape.strokeBorder(.white.opacity(theme.isDark ? 0.15 : 0.6), lineWidth: 0.8)
                }
            }
    }
}

/// The `+` button: the new menu (§6) as a native menu, in a glass circle as the sidebar's +.
struct NewMenu: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let machine = controller.activeSpace?.machine ?? ""
        let launchers = controller.workspace.launchers[machine] ?? []
        let installed = launchers.filter { $0.installed == true }
        let missing = launchers.filter { $0.installed == false }.prefix(2)
        Menu {
            Button { controller.newTab() } label: {
                Label { Text("Terminal") } icon: { MenuIcon.image("program.shell") }
            }
            .keyboardShortcut("t", modifiers: .command)
            Section("Start an agent") {
                if launchers.isEmpty {
                    Text("Checking installed agents…")
                }
                ForEach(installed) { launcher in
                    Button { controller.newTab(launch: .agent(launcher, task: nil)) } label: {
                        Label { Text(launcher.program.name) } icon: { MenuIcon.image(launcher.program.iconAsset) }
                    }
                }
                ForEach(Array(missing)) { launcher in
                    Button {} label: {
                        Label {
                            Text(launcher.program.name)
                            Text("Not installed")
                        } icon: { MenuIcon.image(launcher.program.iconAsset) }
                    }
                    .disabled(true)
                }
            }
            Divider()
            Button { controller.newSpace() } label: {
                Label { Text("New Space") } icon: { MenuIcon.image("ui.plus") }
            }
            .keyboardShortcut("n", modifiers: .command)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: TabBar.height, height: TabBar.height)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(AttachPressStyle())
        .composerGlass(Circle(), theme: theme)
        .hoverEffect(.highlight)
        .accessibilityLabel("New")
        .onAppear { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
    }
}
