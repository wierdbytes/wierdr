import SwiftUI
import WierdrModel

/// The iPhone's list, Telegram's chat list turned for one hand: a tab per space after
/// "All" (`PhoneSpaceTabs`), their pages side by side (`PhoneSpacePager`: a swipe in the
/// middle of the screen pages between them), each drawn bottom up (the newest and pinned
/// rows lowest, `PhoneAgentList`), and a header floating over the pages' bottom (they
/// scroll under it), all of it within the thumb's reach: the strip with + at its right,
/// under it settings, the status counts (or the connection's state) and the
/// subscription limits (`PhoneLimits`). The pages run to the screen's top (their rows
/// scroll under the status bar). Go to comes out of a page pulled up past its bottom
/// (`PhoneAgentList`, `PullToSearch`). No agent is "current" here: the list shows no focus and never scrolls to one.
///
/// The tab shown is remembered (`phone.tab`: "all" or the space's id); when its
/// space goes, its neighbour takes over. Without spaces the strip fades out (+ stays
/// where it is) and swipes don't page.
///
/// Reordering the tabs (`PhoneTabReorder`, Telegram's): the header's row is a Done
/// button over the title, + goes (the strip takes its room), the list under the strip
/// dims to half and takes no touches, and swipes don't page. Done, or a pane pushed, ends it and saves the order.
struct PhoneHome: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var paging = PhoneSpacePaging()
    @State private var reorder = PhoneTabReorder()
    @State private var safeTop: CGFloat = 0
    @State private var safeBottom: CGFloat = 0

    var body: some View {
        let tabs = self.tabs
        let showsTabs = tabs.count > 1
        // The header's top from the screen's bottom: the pages' room for it.
        let bottomGap = PhoneHomeHeader.bottomGap(safeBottom: safeBottom)
        let headerHeight = PhoneHomeHeader.height + bottomGap
        // Read here: the pages are made outside SwiftUI's update (`PhoneSpacePager`).
        let scrollToNewest = paging.scrollToNewest
        let topInset = safeTop
        ZStack(alignment: .bottom) {
            PhoneSpacePager(paging: paging, bottomInset: headerHeight,
                            isEnabled: showsTabs && controller.compactColumn == .sidebar && !reorder.isActive
                                && !controller.showSwitcher,
                            pageInputs: [AnyHashable(headerHeight), AnyHashable(topInset), AnyHashable(showsTabs),
                                         AnyHashable(scrollToNewest)]) { scope in
                PhoneAgentList(scope: scope, topInset: topInset, bottomInset: headerHeight, edgeSwipesOnly: showsTabs,
                               scrollToNewest: scrollToNewest[scope] ?? 0)
            }
            .modifier(PhoneReorderDim(isOn: reorder.isActive))
            PhoneEdgeFade(edge: .top, height: PhoneEdgeFade.statusBar(safeTop))
                .frame(maxHeight: .infinity, alignment: .top)
            PhoneEdgeFade(edge: .bottom, height: headerHeight)
            PhoneHomeHeader(tabs: tabs, paging: paging, reorder: reorder, showsTabs: showsTabs)
                .padding(.bottom, bottomGap)
            if case .failed = controller.workspace.phase {
                // The reason and Retry, over the header (its title says "Not Connected").
                ConnectionBanner(inset: headerHeight + 8, edge: .bottom)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .animation(PhonePagingMotion.relayout, value: showsTabs)
        .overlay(alignment: .bottom) {
            // Over the header (this overlay keeps to the safe area).
            ToastStack().padding(.horizontal, 12).padding(.bottom, headerHeight - safeBottom + 10)
        }
        .background(theme.chrome.ignoresSafeArea())
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
            safeTop = $0.top
            safeBottom = $0.bottom
        }
        .onChange(of: tabs.map(\.scope), initial: true) { _, scopes in
            // The pages are only put in their places (a tab dragged over moves them by a page).
            withTransaction(Transaction(animation: nil)) {
                paging.update(scopes: scopes, keeping: paging.preferredScope)
            }
        }
        .onAppear { reorder.controller = controller }
        // Go to chose a space: its tab, as a tap on it in the strip.
        .onChange(of: controller.listTabRequest, initial: true) { _, id in
            guard let id else { return }
            controller.listTabRequest = nil
            reorder.done()
            if let i = paging.scopes.firstIndex(of: .space(id)) { paging.select(i) }
        }
        // A pane pushed over the list ends reordering, as Done; so do fewer than two spaces.
        .onChange(of: controller.compactColumn) { _, column in
            if column == .detail { reorder.done() }
        }
        .onChange(of: controller.workspace.spaces.map(\.id)) { _, ids in
            if ids.count < 2 { reorder.done() }
            reorder.settle()
        }
        .onDisappear { reorder.done() }
    }

    /// "All", then a tab per space in Herdr's order (or as reordered, `PhoneTabReorder`),
    /// with how many of its agents have the most urgent status (needs you, done, working).
    private var tabs: [PhoneSpaceTab] {
        let ws = controller.workspace
        return [PhoneSpaceTab(scope: .all, title: "All")] + reorder.arranged(ws.spaces).map { space in
            let counts = ws.agentCounts(in: space.id)
            let status = [AgentStatus.blocked, .done, .working].first { (counts[$0] ?? 0) > 0 }
            return PhoneSpaceTab(scope: .space(space.id), title: space.displayName,
                                 unread: status.flatMap { counts[$0] } ?? 0, status: status ?? .done, space: space)
        }
    }
}

/// Telegram's chat-list header, moved to the bottom of the screen for the thumb: 3 pt
/// under its top the strip and + in a glass circle as tall as the strip, 8 pt after it;
/// 10 pt under them a 44-pt row (settings in a glass circle where Telegram has Edit,
/// the title in the middle, the limits at the right, 16 pt from the sides;
/// `PhoneHeaderRow`), its bottom 28 pt over the screen's, as the pane screen's message
/// field's (`bottomGap`). Without spaces only + is in the strip's row, in the same
/// place. While the tabs are reordered, the row has Done (where settings is), the
/// title and the limits dimmed, and the strip takes +'s room.
private struct PhoneHomeHeader: View {
    var tabs: [PhoneSpaceTab]
    var paging: PhoneSpacePaging
    var reorder: PhoneTabReorder
    var showsTabs: Bool

    static let rowHeight: CGFloat = 44
    static let sideInset: CGFloat = 16
    /// Between the strip and +.
    static let newSpacing: CGFloat = 8

    /// The header's height over its row's bottom (the strip's row stays without spaces: + is in it).
    static let height: CGFloat = 3 + PhoneSpaceTabs.height + 10 + rowHeight

    /// From the row's bottom to the screen's: Telegram's 28 pt, into the home
    /// indicator's room (as the message field's); without one, 8 pt.
    static func bottomGap(safeBottom: CGFloat) -> CGFloat { safeBottom > 0 ? 28 : 8 }

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            strip
                .frame(height: PhoneSpaceTabs.height)
                .padding(.horizontal, Self.sideInset)
            row
                .frame(height: Self.rowHeight)
                .padding(.top, 10)
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private var row: some View {
        PhoneHeaderRow {
            HStack(spacing: 0) {
                ComposerGlassGroup {
                    if reorder.isActive {
                        done
                    } else {
                        Button { controller.showSettings = true } label: {
                            Icon("settings", size: 21, color: theme.foreground)
                                .frame(width: Self.rowHeight, height: Self.rowHeight)
                                .contentShape(Circle())
                        }
                        .buttonStyle(AttachPressStyle())
                        .composerGlass(Circle(), theme: theme)
                        .accessibilityLabel("Settings")
                    }
                }
            }
            PhoneHomeTitle()
            HStack(spacing: 0) {
                PhoneLimits(height: Self.rowHeight)
                    .modifier(PhoneReorderDim(isOn: reorder.isActive))
                if !reorder.isActive {
                    // Go to is a pull of the list; VoiceOver's is here.
                    GoToAccessibilityButton(hint: "Or pull the list up.")
                }
            }
        }
        .padding(.horizontal, Self.sideInset)
    }

    /// The strip (none without spaces) and + at its right (none while reordering).
    private var strip: some View {
        HStack(spacing: Self.newSpacing) {
            if showsTabs {
                PhoneSpaceTabs(tabs: tabs, paging: paging, reorder: reorder)
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
            if !reorder.isActive {
                ComposerGlassGroup {
                    PhoneNewMenu(paging: paging, tabs: showsTabs ? tabs : [])
                        .composerGlass(Circle(), theme: theme)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    /// Reordering the tabs: Telegram's bold Done in its own glass pill (12 pt either
    /// side, at least as wide as tall), where settings is; it saves the order.
    private var done: some View {
        Button { reorder.done() } label: {
            Text("Done")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 12)
                .frame(minWidth: Self.rowHeight, minHeight: Self.rowHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(AttachPressStyle())
        .composerGlass(Capsule(), theme: theme)
    }
}

/// The header's row: its leading button at the left, what's at its right (the limits)
/// at the right, and the title (three views, in that order) in the middle of the row,
/// so of the screen, when it fits there clear of both by 8 pt; else as near the middle
/// as it fits between them, and as wide as the room there.
private struct PhoneHeaderRow: Layout {
    static let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: proposal.width ?? sizes.reduce(0) { $0 + $1.width } + 2 * Self.spacing,
                      height: proposal.height ?? sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let (leading, title, trailing) = (subviews[0], subviews[1], subviews[2])
        let l = leading.sizeThatFits(.unspecified), t = trailing.sizeThatFits(.unspecified)
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(l))
        trailing.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(t))
        let lo = bounds.minX + l.width + Self.spacing
        let hi = bounds.maxX - t.width - Self.spacing
        let room = max(0, hi - lo)
        let width = min(room, title.sizeThatFits(ProposedViewSize(width: room, height: bounds.height)).width)
        let x = min(max(bounds.midX - width / 2, lo), hi - width)
        title.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// What's under the strip while the tabs are reordered: half dimmed, taking no touches.
private struct PhoneReorderDim: ViewModifier {
    var isOn: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isOn ? 0.5 : 1)
            .allowsHitTesting(!isOn)
            .accessibilityHidden(isOn)
    }
}

/// The header's title: the agents' counts by status (`PhoneStatusCounts`; "Agents" while
/// there are none); while not live, Telegram's "Connecting…" in its place (a spinner
/// before it), "Not Connected" when it failed (`ConnectionBanner` says why).
private struct PhoneHomeTitle: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let counts = PhoneStatusCounts.Entry.all(in: controller.workspace)
        if case .live = controller.workspace.phase, !counts.isEmpty {
            PhoneStatusCounts(entries: counts)
        } else {
            text
        }
    }

    @ViewBuilder
    private var text: some View {
        let (text, spinner, why) = state
        // The text centered, the spinner before it (and its twin, hidden, after it).
        HStack(spacing: 7) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            if spinner { ProgressView().controlSize(.small).hidden() }
        }
        .animation(.easeInOut(duration: 0.2), value: text)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(why ?? "")
    }

    private var state: (String, Bool, String?) {
        switch controller.workspace.phase {
        case .live: return ("Agents", false, nil)
        case .connecting: return ("Connecting…", true, nil)
        case .reconnecting(let why): return ("Reconnecting…", true, why)
        case .failed(let why): return ("Not Connected", false, why)
        }
    }
}

/// The agents' counts by status in the header's middle (needs you, done, working, idle;
/// only those with any; every sub-agent counts, as it reads under its parent): each a
/// round badge filled with its status's color, as the pane's back button has. A tap
/// opens the first agent with that status in the list's order (the "All" tab's: an
/// agent, then its sub-agents; one without a pane shows as a tap on its row does).
private struct PhoneStatusCounts: View {
    struct Entry: Equatable {
        var status: AgentStatus
        var count: Int
        /// The first agent with this status.
        var first: CountedAgent

        /// Every status with agents, most urgent first.
        @MainActor static func all(in workspace: Workspace) -> [Entry] {
            let agents = workspace.phoneList(space: nil).agents.map(\.row).countedAgents
            let counts = agents.byStatus
            return [AgentStatus.blocked, .done, .working, .idle].compactMap { s in
                guard let n = counts[s], let first = agents.first(where: { $0.status == s }) else { return nil }
                return Entry(status: s, count: n, first: first)
            }
        }
    }

    var entries: [Entry]

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(entries, id: \.status) { entry in
                Button { open(entry.first) } label: {
                    Text("\(entry.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(theme.color(for: entry.status), in: Capsule())
                        .frame(minWidth: 34, minHeight: PhoneHomeHeader.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AttachPressStyle())
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("\(entry.count) \(Format.statusWord(entry.status))")
                .accessibilityHint("Opens the first one")
            }
        }
        .animation(.snappy(duration: 0.3), value: entries.map(\.status))
        .animation(.snappy(duration: 0.3), value: entries.map(\.count))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agents")
    }

    /// An agent's pane; a sub-agent as a tap on its row shows it (`open`).
    private func open(_ agent: CountedAgent) {
        if let kid = agent.kid {
            controller.open(kid, from: agent.rowPane)
        } else {
            controller.focus(pane: agent.rowPane)
        }
    }
}

/// Telegram's edge effect behind the list's header at the screen's bottom (and the
/// status bar at its top, here and over Go to's panel): the list's background at 85 %,
/// solid to 54 pt before its end, then fading out (Telegram's curve); it runs 14 pt
/// past the header. The rows scroll under it.
struct PhoneEdgeFade: View {
    /// The screen's edge it's at.
    var edge: VerticalEdge

    /// Under the status bar (`safeTop` its height): the text there mostly covered, the
    /// fade's end a little under it.
    static func statusBar(_ safeTop: CGFloat) -> CGFloat { safeTop > 0 ? safeTop + 10 : 0 }
    /// The header's height from that edge.
    var height: CGFloat
    @Environment(\.theme) private var theme

    /// Telegram's fade over its last 54 pt: (where, how much shows).
    private static let fade: [(CGFloat, CGFloat)] = [
        (0, 1), (0.132, 0.972), (0.233, 0.917), (0.314, 0.829), (0.394, 0.704), (0.47, 0.546),
        (0.547, 0.389), (0.606, 0.273), (0.659, 0.19), (0.728, 0.106), (0.791, 0.056), (1, 0),
    ]

    var body: some View {
        let total = height + 14
        let fade = min(54, total)
        let solid = (total - fade) / total
        Rectangle()
            .fill(theme.chrome.opacity(0.85))
            .mask {
                LinearGradient(stops: Self.fade.map { at, alpha in
                    Gradient.Stop(color: .black.opacity(alpha), location: solid + at * fade / total)
                }, startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            }
            .frame(height: total)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The header's + (at the strip's right), Telegram's compose. On a space's tab: a new tab (shell or agent)
/// in that space, on its computer. On "All": a new space, in the folder of the last
/// pane you looked at (as the desktop's New Space), on its computer. It follows the
/// tab shown itself (not the header: a new tab redraws only it).
private struct PhoneNewMenu: View {
    var paging: PhoneSpacePaging
    /// The strip's tabs (none without the strip: then always a new space).
    var tabs: [PhoneSpaceTab]
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let selected = paging.selectedScope
        let space = selected == .all ? nil : tabs.first { $0.scope == selected }?.space
        let machine = space != nil ? space?.machine : controller.activeSpace?.machine
        Menu {
            if let space {
                Section("New tab in \(space.displayName)") {
                    LaunchMenuItems(machine: space.machine) { launch in controller.newTab(launch: launch, in: space) }
                }
            } else {
                PhoneNewSpaceItems()
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: PhoneSpaceTabs.height, height: PhoneSpaceTabs.height)
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel(space == nil ? "New Space" : "New Tab")
        .onAppear { controller.workspace.refreshLaunchers(machine: machine) }
        .onChange(of: machine) { _, machine in controller.workspace.refreshLaunchers(machine: machine) }
    }
}

/// The new-space menu's items: a terminal or an installed agent, in the folder of the
/// last pane you looked at, on its computer (the header's + and the "All" tab's menu).
struct PhoneNewSpaceItems: View {
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        let machine = controller.activeSpace?.machine
        let folder = controller.workspace.terminal(controller.focusedPane?.terminal)?.cwd
        Section(folder.map { "New space in \(Format.tilde($0, home: controller.workspace.home))" } ?? "New space") {
            LaunchMenuItems(machine: machine) { launch in controller.newSpace(launch: launch) }
        }
    }
}

/// Menu items to start a terminal or an installed agent (`New Tab` / `New Space`).
struct LaunchMenuItems: View {
    var machine: String?
    var action: (Launch) -> Void
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        let launchers = controller.workspace.launchers[machine ?? ""] ?? []
        Button { action(.shell) } label: {
            Label { Text("Terminal") } icon: { MenuIcon.image("program.shell") }
        }
        if launchers.isEmpty {
            Text("Checking installed agents…")
        }
        ForEach(launchers.filter { $0.installed == true }) { launcher in
            Button { action(.agent(launcher, task: nil)) } label: {
                Label { Text(launcher.program.name) } icon: { MenuIcon.image(launcher.program.iconAsset) }
            }
        }
    }
}
