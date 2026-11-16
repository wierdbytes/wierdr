import SwiftUI
import WierdrModel

/// The sidebar's header, at the bottom of the screen for the thumb (iPhone and iPad alike),
/// floating over the list's bottom (the rows scroll under it). Two 44-pt rows, 8 pt apart,
/// 16 pt from the sides:
/// - on the iPad the sidebar's toggle at the left; the subscription limits at the right
///   (`PhoneLimits`; none without data, and then on the iPhone no row);
/// - settings in a glass circle at the left, the agents' counts by status in the middle
///   (or the connection's state, `SidebarTitle`), + at the right (`SidebarNewMenu`),
///   placed by `SidebarHeaderRow`.
/// Its bottom is 28 pt over the screen's, as the pane screen's message field's (`bottomGap`).
struct SidebarHeader: View {
    static let rowHeight: CGFloat = 44
    static let sideInset: CGFloat = 16
    static let rowSpacing: CGFloat = 8

    /// Whether it has the row over its main one: the limits, or the iPad's toggle.
    @MainActor static func hasTopRow(_ controller: WorkspaceController, compact: Bool) -> Bool {
        !compact || !controller.workspace.limits.isEmpty
    }

    /// The header's height over its row's bottom.
    static func height(topRow: Bool) -> CGFloat {
        rowHeight + (topRow ? rowSpacing + rowHeight : 0)
    }

    /// From the row's bottom to the screen's: Telegram's 28 pt, into the home
    /// indicator's room (as the message field's); without one, 8 pt.
    static func bottomGap(safeBottom: CGFloat) -> CGFloat { safeBottom > 0 ? 28 : 8 }

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// The iPad's split view (the sidebar beside the panel): its toggle is here.
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            if Self.hasTopRow(controller, compact: compact) {
                HStack(spacing: Self.rowSpacing) {
                    if !compact {
                        ComposerGlassGroup {
                            circle(icon: "sidebar", label: "Hide Sidebar") { controller.toggleSidebar() }
                        }
                    }
                    if !controller.workspace.limits.isEmpty {
                        // The rings; scrolled sideways when the sidebar is too narrow for them.
                        ViewThatFits(in: .horizontal) {
                            PhoneLimits(height: Self.rowHeight)
                            ScrollView(.horizontal, showsIndicators: false) {
                                PhoneLimits(height: Self.rowHeight)
                            }
                            .defaultScrollAnchor(.trailing)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: Self.rowHeight)
                .padding(.horizontal, Self.sideInset)
            }
            SidebarHeaderRow {
                ComposerGlassGroup {
                    circle(icon: "settings", label: "Settings") { controller.showSettings = true }
                }
                SidebarTitle()
                HStack(spacing: 0) {
                    // Go to is a pull of the list; VoiceOver's is here.
                    GoToAccessibilityButton(hint: "Or pull the list up.")
                    ComposerGlassGroup {
                        SidebarNewMenu()
                            .composerGlass(Circle(), theme: theme)
                    }
                }
            }
            .frame(height: Self.rowHeight)
            .padding(.horizontal, Self.sideInset)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.25), value: controller.workspace.limits.isEmpty)
    }

    private func circle(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(icon, size: 21, color: theme.foreground)
                .frame(width: Self.rowHeight, height: Self.rowHeight)
                .contentShape(Circle())
        }
        .buttonStyle(AttachPressStyle())
        .composerGlass(Circle(), theme: theme)
        .accessibilityLabel(label)
    }
}

/// The header's row: its leading buttons at the left, what's at its right at the right,
/// and the title (three views, in that order) in the middle of the row, so of the
/// sidebar, when it fits there clear of both by 8 pt; else as near the middle as it
/// fits between them, and as wide as the room there.
struct SidebarHeaderRow: Layout {
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

/// The header's title: the agents' counts by status (`SidebarStatusCounts`; "Agents" while
/// there are none); while not live, Telegram's "Connecting…" in its place (a spinner
/// before it), "Not Connected" when it failed (`ConnectionBanner` says why).
struct SidebarTitle: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let counts = SidebarStatusCounts.Entry.all(in: controller.workspace)
        if case .live = controller.workspace.phase, !counts.isEmpty {
            SidebarStatusCounts(entries: counts)
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
/// opens the first agent with that status in the order of the iPhone's old "All" list
/// (`Workspace.phoneList`: an agent, then its sub-agents; one without a pane shows as a
/// tap on its row does).
struct SidebarStatusCounts: View {
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
                        .frame(minWidth: 34, minHeight: SidebarHeader.rowHeight)
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

/// Telegram's edge effect behind the sidebar's header at the screen's bottom (and the
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

/// The header's +, Telegram's compose: a new space (a terminal or an installed agent),
/// in the folder of the last pane you looked at (as the desktop's New Space), on its
/// computer. A new tab in a space is in its card's menu.
struct SidebarNewMenu: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let machine = controller.activeSpace?.machine
        Menu {
            NewSpaceItems()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: SidebarHeader.rowHeight, height: SidebarHeader.rowHeight)
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("New Space")
        .onAppear { controller.workspace.refreshLaunchers(machine: machine) }
        .onChange(of: machine) { _, machine in controller.workspace.refreshLaunchers(machine: machine) }
    }
}

/// The new-space menu's items: a terminal or an installed agent, in the folder of the
/// last pane you looked at, on its computer (the header's +).
struct NewSpaceItems: View {
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
