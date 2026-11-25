import SwiftUI
import WierdrModel

/// The sidebar's header, at the bottom of the screen for the thumb (iPhone and iPad alike),
/// floating over the list's bottom (the rows scroll under it): one 44-pt row, 16 pt from
/// the sides, its bottom 28 pt over the screen's, as the pane screen's message field's
/// (`bottomGap`). At its left the subscription limits (`SidebarLimits`: as many rings as
/// fit; none without data), in its middle the agents' statuses as one ring, whose tap
/// opens the agents panel (or the connection's state, `SidebarTitle`), at its right, under
/// the right thumb, + in a glass circle (`SidebarMenu`: Settings and a new space).
/// Placed by `SidebarHeaderRow`.
struct SidebarHeader: View {
    static let height: CGFloat = 44
    static let sideInset: CGFloat = 16

    /// From the row's bottom to the screen's: Telegram's 28 pt, into the home
    /// indicator's room (as the message field's); without one, 8 pt.
    static func bottomGap(safeBottom: CGFloat) -> CGFloat { safeBottom > 0 ? 28 : 8 }

    @Environment(\.theme) private var theme

    var body: some View {
        SidebarHeaderRow {
            SidebarLimits()
                .tutorialAnchor(.limits)
            SidebarTitle()
                .tutorialAnchor(.statusRing)
            ComposerGlassGroup {
                SidebarMenu()
                    .composerGlass(Circle(), theme: theme)
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, Self.sideInset)
        .frame(maxWidth: .infinity, alignment: .bottom)
    }
}

/// The header's row: what's at its left (the limits), the title, and its right (+), three
/// views in that order. The right one at its size; the title (the status ring) gets its room
/// first, and the limits what's left beside it: they pick their widest form that fits
/// there (`SidebarLimits`), and only when even their narrowest doesn't fit beside the
/// title's widest, the title gives way to its narrowest (`SidebarTitle`). The title is in
/// the row's middle, so the sidebar's, when it fits there clear of both by 8 pt; else as
/// near the middle as it fits between them, and as wide as the room there.
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
        let h = bounds.height
        let t = trailing.sizeThatFits(.unspecified)
        trailing.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(t))
        // The room for the limits and the title, with the gap between them.
        let room = max(0, bounds.width - t.width - 2 * Self.spacing)
        let widest = title.sizeThatFits(.unspecified).width
        let narrowest = title.sizeThatFits(ProposedViewSize(width: 0, height: h)).width
        var l = leading.sizeThatFits(ProposedViewSize(width: max(0, room - widest), height: h))
        if l.width > room - widest + 0.5 {
            l = leading.sizeThatFits(ProposedViewSize(width: max(0, room - narrowest), height: h))
        }
        let lw = min(l.width, max(0, room - narrowest))
        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: lw, height: h))
        let lo = bounds.minX + lw + (lw > 0 ? Self.spacing : 0)
        let hi = bounds.maxX - t.width - Self.spacing
        let space = max(0, hi - lo)
        let width = min(space, title.sizeThatFits(ProposedViewSize(width: space, height: h)).width)
        let x = min(max(bounds.midX - width / 2, lo), hi - width)
        title.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: width, height: h))
    }
}

/// The limits in the header, in the widest form that fits (`PhoneLimits.Style`): every
/// limit's ring by its account's icon; the headline limit's ring alone, by the icon;
/// without the icons; and past that, those scrolled sideways.
struct SidebarLimits: View {
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        if !controller.workspace.limits.isEmpty {
            ViewThatFits(in: .horizontal) {
                PhoneLimits(height: SidebarHeader.height)
                PhoneLimits(height: SidebarHeader.height, style: .headline)
                PhoneLimits(height: SidebarHeader.height, style: .bare)
                ScrollView(.horizontal, showsIndicators: false) {
                    PhoneLimits(height: SidebarHeader.height, style: .bare)
                }
            }
            .transition(.opacity)
        }
    }
}

/// The header's title: the agents' statuses as one ring (`SidebarStatusRing`; "Agents"
/// while there are none); while not live, Telegram's "Connecting…" in its place (a
/// spinner before it), "Not Connected" when it failed (`ConnectionBanner` says why).
struct SidebarTitle: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let entries = SidebarStatusRing.Entry.all(in: controller.workspace)
        if case .live = controller.workspace.phase, !entries.isEmpty {
            SidebarStatusRing(entries: entries)
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
                .font(.ui(17, .semibold))
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

/// The agents' statuses in the header's middle, one ring (`StatusRing`: a dash per
/// agent, every sub-agent counting as it reads under its parent, the most urgent first;
/// inside, how many have the most urgent status). A tap opens the agents panel over the
/// spaces (`AgentsPanel`: every agent by status, the most urgent lowest, a search field
/// under them).
struct SidebarStatusRing: View {
    struct Entry: Equatable {
        var status: AgentStatus
        var count: Int

        /// Every status with agents, most urgent first.
        @MainActor static func all(in workspace: Workspace) -> [Entry] {
            let counts = workspace.phoneList(space: nil).agents.map(\.row).countedAgents.byStatus
            return [AgentStatus.blocked, .done, .working, .idle].compactMap { s in
                counts[s].map { Entry(status: s, count: $0) }
            }
        }
    }

    /// Every status with agents, most urgent first (`Entry.all`).
    var entries: [Entry]

    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        Button { controller.openAgents() } label: {
            StatusRing(counts: Dictionary(uniqueKeysWithValues: entries.map { ($0.status, $0.count) }))
                .frame(width: SidebarHeader.height, height: SidebarHeader.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .hoverEffect(.highlight)
        .accessibilityLabel("Agents")
        .accessibilityValue(entries.map { "\($0.count) \(Format.statusWord($0.status))" }.joined(separator: ", "))
        .accessibilityHint("Shows every agent by status, with a search.")
    }
}

/// The agents' statuses as one ring (the header's, `SidebarStatusRing`), the limits'
/// rings' kin, but larger, dashed and with a colored number: a dash per agent from the
/// top, clockwise, the most urgent first (needs you, done, working) in their colors and
/// idle ones faint, as a track, so the many idle ones don't drown the few that need you
/// (a dash per agent, as a story ring has one per story: a few are counted at a glance).
/// Past `dashes` agents a dash would be too short: then each status is one arc, at
/// least `least` of the ring. Inside, how many have the most urgent status, in its
/// color (idle's dim). A change moves the dashes (trims animate) and rolls the number.
struct StatusRing: View {
    var counts: [AgentStatus: Int]

    @Environment(\.theme) private var theme

    /// The dashes' middle and their line: the limits' ring is 9.5 and 2.5.
    static let radius: CGFloat = 14
    static let line: CGFloat = 3.5
    /// Between two dashes, along the ring.
    static let gap: CGFloat = 1.5
    /// The most dashes drawn (each 2.2 pt or more); past that, an arc per status.
    static let dashes = 24
    /// An arc's least share of the ring, past `dashes`.
    static let least = 0.1
    static var size: CGFloat { 2 * radius + line }

    /// Most urgent first: the ring's order from the top, clockwise.
    static let order: [AgentStatus] = [.blocked, .done, .working, .idle]

    /// A dash or an arc: its share of the ring, from the top.
    struct Segment: Equatable, Identifiable {
        var id: Int
        var status: AgentStatus
        var from: Double
        var to: Double
    }

    static func segments(_ counts: [AgentStatus: Int]) -> [Segment] {
        let present = order.compactMap { s in counts[s].flatMap { $0 > 0 ? (s, $0) : nil } }
        let total = present.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        let gap = Double(Self.gap / (2 * .pi * radius))
        if total <= dashes {
            let share = 1 / Double(total)
            return present.flatMap { s, n in Array(repeating: s, count: n) }.enumerated().map { i, s in
                Segment(id: i, status: s, from: Double(i) * share + gap / 2, to: Double(i + 1) * share - gap / 2)
            }
        }
        let weights = present.map { max(Double($0.1) / Double(total), least) }
        let sum = weights.reduce(0, +)
        var at = 0.0
        return zip(present, weights).map { entry, weight in
            let share = weight / sum
            defer { at += share }
            return Segment(id: dashes + (order.firstIndex(of: entry.0) ?? 0), status: entry.0,
                           from: at + gap / 2, to: at + share - gap / 2)
        }
    }

    var body: some View {
        let segments = Self.segments(counts)
        let top = Self.order.first { (counts[$0] ?? 0) > 0 }
        ZStack {
            ForEach(segments) { segment in
                Circle()
                    .trim(from: segment.from, to: segment.to)
                    .stroke(color(segment.status), style: StrokeStyle(lineWidth: Self.line, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 2 * Self.radius, height: 2 * Self.radius)
            }
            if let top {
                Text("\(counts[top] ?? 0)")
                    .font(.ui(14, .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(top == .idle ? theme.dim : theme.color(for: top))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 2 * (Self.radius - Self.line / 2) - 3)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.snappy(duration: 0.35), value: segments)
        .animation(.snappy(duration: 0.35), value: counts)
        .accessibilityHidden(true)
    }

    /// Idle's dashes faint, as the ring's track.
    private func color(_ status: AgentStatus) -> Color {
        status == .idle ? theme.color(for: .idle).opacity(0.45) : theme.color(for: status)
    }
}

/// Telegram's edge effect behind the sidebar's header at the screen's bottom (and the
/// status bar at its top, here and over the agents panel): the list's background at 85 %,
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
        // The chrome's color fading, rather than the chrome masked by a fade: a mask is an
        // offscreen pass of the render server every frame the list under it moves.
        LinearGradient(stops: Self.fade.map { at, alpha in
            Gradient.Stop(color: theme.chrome.opacity(0.85 * alpha), location: solid + at * fade / total)
        }, startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
            .frame(height: total)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The header's +, Telegram's compose, the sidebar's one button: its menu opens over it,
/// top to bottom Settings, then a new space (a terminal or an installed agent) in the
/// folder of the last pane you looked at (as the desktop's New Space), on its computer,
/// the new space's items lowest, nearest the thumb. A new tab in a space is in its card's
/// menu; the iPad hides its sidebar with the tab bar's sidebar button (or ⌘B).
struct SidebarMenu: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let machine = controller.activeSpace?.machine
        Menu {
            Button { controller.showSettings = true } label: {
                Label { Text("Settings") } icon: { MenuIcon.image("ui.settings") }
            }
            NewSpaceItems()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: SidebarHeader.height, height: SidebarHeader.height)
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("New Space, Settings")
        .onAppear { controller.workspace.refreshLaunchers(machine: machine) }
        .onChange(of: machine) { _, machine in controller.workspace.refreshLaunchers(machine: machine) }
    }
}

/// The new-space menu's items: a terminal or an installed agent, in the folder of the
/// last pane you looked at, on its computer (the header's +, `SidebarMenu`).
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
