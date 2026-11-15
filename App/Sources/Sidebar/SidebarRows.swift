import SwiftUI
import WierdrModel

/// One row under a space card: an agent (52 pt), a plain terminal (28 pt) or a
/// mod pane, with the split-tab bracket, tap-to-focus, context menu and swipes.
/// An agent's sub-agents are rows of their own under it (`CardItem.kid`).
struct SidebarRowView: View {
    var row: SidebarRow
    var space: Space
    var bracket: Bracket
    /// Agent rows name their space (the iPhone's agents list, where rows of all spaces mix).
    var showsSpace = false

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let ws = controller.workspace
        // The focus ring: the focused pane's row, unless a sub-agent shows in its place.
        let focused = controller.ringedPane == row.paneID
        let tab = ws.tab(row.tabID)
        content(focused: focused, tab: tab, open: controller.showsKids(of: row))
            .overlay(alignment: .leading) { BracketOverlay(bracket: bracket) }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { controller.focus(pane: row.paneID) }
            .contextMenu { menu }
            // Only to the right: a swipe left closes the overlaid sidebar / the iPhone's list
            // (Unread/Idle and Close are in the long-press menu).
            .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipes }
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func content(focused: Bool, tab: Tab?, open: Bool) -> some View {
        switch row.kind {
        case .agent:
            if let t = row.terminal {
                AgentRow(terminal: t, tab: tab, focused: focused, subtree: row.subtree, open: open,
                         space: showsSpace ? space : nil)
            }
        case .terminal:
            TerminalRow(terminal: row.terminal, focused: focused)
        case .mod:
            ModRow(name: row.mod ?? "panel", focused: focused)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let t = row.terminal, t.isAgent {
            Button { controller.setPinned(t.address, !t.pinned) } label: {
                Label(t.pinned ? "Unpin" : "Pin", image: t.pinned ? "ui.pin-off" : "ui.pin")
            }
            switch t.status {
            case .idle:
                Button { controller.markUnread(t.address) } label: { Label("Mark Unread", systemImage: "circle.fill") }
            case .done:
                Button { controller.markRead(t.address) } label: { Label("Mark Idle", systemImage: "circle") }
            default:
                EmptyView()
            }
            Divider()
        }
        Button { controller.focus(pane: row.paneID); controller.split(.right, pane: row.paneID) } label: {
            Label("Split Right", image: "ui.split-right")
        }
        Button(role: .destructive) { controller.closePane(row.paneID) } label: { Label("Close Pane", image: "ui.x") }
    }

    @ViewBuilder
    private var leadingSwipes: some View {
        if let t = row.terminal, t.isAgent {
            Button { controller.setPinned(t.address, !t.pinned) } label: {
                Label(t.pinned ? "Unpin" : "Pin", systemImage: t.pinned ? "pin.slash" : "pin")
            }
            .tint(theme.accent)
        }
    }
}

/// The split tab's bracket beside a row (§4.11).
struct BracketOverlay: View {
    var bracket: Bracket
    @Environment(\.theme) private var theme

    var body: some View {
        if bracket != .none {
            BracketShape(position: bracket)
                .stroke(theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12)
                .allowsHitTesting(false)
        }
    }
}

/// A row of the list under a space card (or in the iPhone's agents list): a
/// sidebar row, or a sub-agent shown under its agent's row (while the agent's
/// badge doesn't fold them away), as the desktop's tree.
enum CardItem: Identifiable {
    case row(SidebarRow)
    case kid(SubAgent, under: SidebarRow)

    var id: String {
        switch self {
        case .row(let r): return r.paneID
        case .kid(let k, _): return "kid:\(k.terminal.address)"
        }
    }

    /// The row it belongs to (itself, or the agent it shows under).
    var row: SidebarRow {
        switch self {
        case .row(let r), .kid(_, let r): return r
        }
    }
}

extension WorkspaceController {
    /// An agent's sub-agents show under it (unless its badge folded them).
    func showsKids(of row: SidebarRow) -> Bool {
        row.kind == .agent && !row.subtree.isEmpty && !foldedAgents.contains(row.terminal?.address ?? "")
    }

    /// The list row showing a pane: its own, or (a kept sub-agent's) its row under its agent.
    func listID(ofPane paneID: String) -> String {
        let pane = workspace.location(ofPane: paneID)?.tab.panes.first { $0.id == paneID }
        if let address = pane?.terminal, workspace.isNested(address) { return "kid:\(address)" }
        return paneID
    }

    /// Rows with the sub-agents that show under them.
    func cardItems(_ rows: [SidebarRow]) -> [CardItem] {
        rows.flatMap { row -> [CardItem] in
            [.row(row)] + (showsKids(of: row) ? row.subtree.map { .kid($0, under: row) } : [])
        }
    }
}

/// A sub-agent's row under its agent: two lines for a sub-agent, one for a terminal.
struct SubAgentRowView: View {
    var kid: SubAgent
    var parent: SidebarRow
    var bracket: Bracket = .none

    var body: some View {
        Group {
            if kid.isAgent {
                KidRow(kid: kid, rowPane: parent.paneID)
            } else {
                SubTerminalRow(kid: kid, rowPane: parent.paneID)
            }
        }
        .overlay(alignment: .leading) { BracketOverlay(bracket: bracket) }
    }
}

// MARK: - Agent row (§4.4)

struct AgentRow: View {
    var terminal: TerminalInfo
    var tab: Tab?
    var focused: Bool
    /// Its sub-agents and terminals (`hc run`), for its badges.
    var subtree: [SubAgent] = []
    /// They show under it (its badges read open).
    var open = false
    /// Shown before the model (rows of several spaces in one list).
    var space: Space? = nil

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// iPhone: a little larger, for fingers and arm's length.
    @Environment(\.isCompactLayout) private var compact
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            main(now: context.date)
        }
    }

    /// Second ticks only while something visibly changes each second.
    private var tickInterval: TimeInterval {
        let now = Date()
        let young = terminal.statusChangedAt.map { now.timeIntervalSince($0) < 3600 } ?? false
        let cacheLive = terminal.meta?.cacheUntil.map { $0 > now } ?? false
        return young || cacheLive ? 1 : 30
    }

    /// Folds its sub-agents in or out (the badges).
    private func toggle() {
        withAnimation(.easeOut(duration: 0.2)) {
            if controller.foldedAgents.contains(terminal.address) {
                controller.foldedAgents.remove(terminal.address)
            } else {
                controller.foldedAgents.insert(terminal.address)
            }
        }
    }

    private func main(now: Date) -> some View {
        let meta = terminal.meta
        let status = terminal.status
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                StatusMark(status: status)
                    .frame(width: 18)
                Text(Format.agentTitle(terminal, tab: tab))
                    .font(.ui(compact ? 14.5 : 13, .medium))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: compact ? 22 : 20)
            HStack(spacing: 9) {
                Group {
                    if let space { SpaceAvatar(space: space, size: 15) } else { providerIcon }
                }
                .frame(width: 18)
                HStack(spacing: 4) {
                    if let space {
                        Text(space.displayName)
                            .font(.ui(compact ? 12.5 : 11.5, .medium))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                            .layoutPriority(2)
                        Text("·").foregroundStyle(theme.dim)
                    }
                    Text(meta?.model ?? terminal.program.name)
                        .foregroundStyle(status == .idle && !focused ? theme.dim : theme.muted)
                        .lineLimit(1)
                        // "Op…" at least, beside a space's name and the badges.
                        .frame(minWidth: 28, alignment: .leading)
                    if let effort = meta?.effort, !effort.isEmpty {
                        effortText(effort)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(.mono(compact ? 11.5 : 10.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    if let machine = terminal.machine {
                        Text(machine).font(.ui(10)).foregroundStyle(theme.dim)
                    }
                    // hc sub-agents and terminals fold in and out; pi's in-process
                    // sub-agents (pi-herdr's count) have no terminal, they only add to the count.
                    let kidAgents = subtree.filter(\.isAgent).count
                    let kidTerms = subtree.count - kidAgents
                    let inner = meta?.subagents ?? 0
                    if kidAgents + inner > 0 {
                        ChildBadge(icon: "bot", count: kidAgents + inner, open: open,
                                   label: badgeLabel(kidAgents, inner), action: kidAgents > 0 ? toggle : nil)
                    }
                    if kidTerms > 0 {
                        ChildBadge(icon: "terminal", count: kidTerms, open: open,
                                   label: kidTerms == 1 ? "1 terminal" : "\(kidTerms) terminals", action: toggle)
                    }
                    Text(Format.context(meta?.ctx) ?? "")
                        .font(.mono(compact ? 11.5 : 10.5))
                        .foregroundStyle(theme.contextNumberColor(cacheUntil: meta?.cacheUntil, now: now))
                        .frame(width: compact ? 38 : 34, alignment: .trailing)
                    Text(Format.age(since: terminal.statusChangedAt, now: now) ?? "")
                        .font(.mono(compact ? 11.5 : 10.5))
                        .foregroundStyle(theme.dim)
                        .frame(width: compact ? 29 : 26, alignment: .trailing)
                        .overlay(alignment: .trailing) { if hovering { pinButton } }
                }
                .fixedSize()
            }
            .frame(height: compact ? 20 : 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: compact ? 58 : 52)
        .background(background(status), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) { contextBar(now: now) }
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent, lineWidth: 1) }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: now))
        .accessibilityActions {
            if !subtree.isEmpty {
                Button(open ? "Hide Sub-agents" : "Show Sub-agents") { toggle() }
            }
        }
    }

    private func badgeLabel(_ agents: Int, _ inner: Int) -> String {
        var parts: [String] = []
        if agents > 0 { parts.append(agents == 1 ? "1 sub-agent" : "\(agents) sub-agents") }
        if inner > 0 { parts.append("\(inner) in pi") }
        return parts.joined(separator: " + ")
    }

    private func background(_ status: AgentStatus?) -> Color {
        switch status {
        case .working: return theme.working.opacity(hovering ? 0.24 : 0.15)
        case .done: return theme.done.opacity(hovering ? 0.24 : 0.15)
        case .blocked: return theme.blocked.opacity(hovering ? 0.24 : 0.15)
        default:
            if hovering { return theme.hover }
            return focused ? theme.selected : .clear
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let asset = terminal.meta?.providerAsset {
            Icon(asset, size: 13, color: theme.muted)
        } else {
            ProgramIcon(program: terminal.program, size: 14, color: theme.muted)
        }
    }

    private func effortText(_ effort: String) -> Text {
        if effort.lowercased() == "max" {
            let colors = theme.maxEffortGradient
            let word = Array("@" + effort)
            return word.enumerated().reduce(Text("")) { acc, item in
                let t = Double(item.offset) / Double(max(1, word.count - 1)) * Double(colors.count - 1)
                return acc + Text(String(item.element)).foregroundColor(colors[min(colors.count - 1, Int(t.rounded()))])
            }
        }
        return Text("@" + effort).foregroundColor(theme.effortColor(effort))
    }

    @ViewBuilder
    private func contextBar(now: Date) -> some View {
        if let meta = terminal.meta, let ctx = meta.ctx, let max = meta.ctxMax, max > 0 {
            let fraction = min(1, Swift.max(0, Double(ctx) / Double(max)))
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 1).fill(theme.raised).frame(height: 2)
                    RoundedRectangle(cornerRadius: 1).fill(theme.contextBarColor(fraction).opacity(0.6))
                        .frame(width: Swift.max(2, w * fraction), height: 2)
                    if let until = meta.cacheUntil, let ttl = meta.cacheTTL, ttl > 0, until > now {
                        let left = Swift.min(1, until.timeIntervalSince(now) / ttl)
                        Rectangle().fill(theme.foreground.opacity(0.5))
                            .frame(width: 2, height: 6)
                            .offset(x: (left * (w - 2)).rounded())
                    }
                }
                .frame(width: w, height: 6, alignment: .bottomLeading)
            }
            .frame(height: 6)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)
            .allowsHitTesting(false)
        }
    }

    private var pinButton: some View {
        Button { controller.setPinned(terminal.address, !terminal.pinned) } label: {
            Icon(terminal.pinned ? "pin-off" : "pin", size: 13, color: theme.dim)
                .padding(2)
                .background(theme.hover, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(terminal.pinned ? "Unpin" : "Pin")
    }

    private func accessibilityText(now: Date) -> String {
        var parts = [Format.agentTitle(terminal, tab: tab), Format.statusWord(terminal.status)]
        if let space { parts.append("in \(space.displayName)") }
        if let m = terminal.meta?.model { parts.append(m) }
        if let e = terminal.meta?.effort { parts.append("effort \(e)") }
        if let c = Format.context(terminal.meta?.ctx) { parts.append("\(c) context") }
        if let a = Format.age(since: terminal.statusChangedAt, now: now) { parts.append(a) }
        if terminal.pinned { parts.append("pinned") }
        let kids = subtree.filter(\.isAgent).count + (terminal.meta?.subagents ?? 0)
        if kids > 0 { parts.append(kids == 1 ? "1 sub-agent" : "\(kids) sub-agents") }
        return parts.joined(separator: ", ")
    }
}

/// A count chip on an agent's row (bot 3, >_ 1): its sub-agents, its terminals;
/// with an action it folds them in or out under the row.
struct ChildBadge: View {
    var icon: String
    var count: Int
    var open: Bool
    var label: String
    var action: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Icon(icon, size: 11, color: open || (hovering && action != nil) ? theme.foreground : theme.muted)
            // Room for two digits, so 9 -> 10 doesn't push its neighbours.
            Text("\(count)")
                .font(.ui(11))
                .foregroundStyle(open || (hovering && action != nil) ? theme.foreground : theme.muted)
                .frame(minWidth: 14)
        }
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(open ? theme.selected : (hovering && action != nil ? theme.raised : theme.hover), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
        .accessibilityLabel(label)
    }
}

// MARK: - Sub-agents (wierd-agents' tree)

/// Sizes of the tree under an agent's row: a sub-agent's two lines and a plain
/// terminal's one, the tree's columns (each child row has the card's 4-pt gap above it).
private enum Tree {
    static let columnWidth: CGFloat = 9
    static let columnGap: CGFloat = 4
    static let stroke: CGFloat = 1.5
    /// How far a line reaches up into the room above its row, joining its sibling's.
    static let up: CGFloat = 4
    static let elbowRadius: CGFloat = 6

    static func kidHeight(_ compact: Bool) -> CGFloat { compact ? 48 : 42 }
    static func termHeight(_ compact: Bool) -> CGFloat { compact ? 32 : 26 }
    /// The middle of a sub-agent's first line (where its elbow comes in).
    static func kidMid(_ compact: Bool) -> CGFloat { compact ? 14.5 : 13 }
}

/// The tree's columns in front of a child: `├`/`└` an elbow into its first
/// line's middle (`mid`); `├` and `│` go on down to the row's end; every line
/// reaches up into the room above, so siblings join into one line.
struct TreeLines: View {
    var lines: [SubAgent.Line]
    var height: CGFloat
    var mid: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Tree.columnGap) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                column(line)
                    .stroke(theme.input, style: StrokeStyle(lineWidth: Tree.stroke, lineCap: .butt))
                    .frame(width: Tree.columnWidth, height: height)
            }
        }
        .padding(.trailing, Tree.columnGap)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func column(_ line: SubAgent.Line) -> Path {
        var p = Path()
        let x = Tree.stroke / 2
        let top = -Tree.up
        switch line {
        case .blank:
            break
        case .pipe:
            p.move(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x, y: height))
        case .tee, .elbow:
            let y = mid - Tree.stroke / 2
            p.move(to: CGPoint(x: x, y: top))
            p.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: Tree.columnWidth, y: y), radius: Tree.elbowRadius)
            p.addLine(to: CGPoint(x: Tree.columnWidth, y: y))
            if line == .tee {
                p.move(to: CGPoint(x: x, y: mid - Tree.elbowRadius))
                p.addLine(to: CGPoint(x: x, y: height))
            }
        }
        return p
    }
}

/// What a child row shares: lit while it's shown (looked at, or its kept pane
/// focused), a tap opens it, the long-press menu keeps it.
private struct KidRowChrome: ViewModifier {
    var kid: SubAgent
    var rowPane: String
    var on: Bool
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var hovering = false

    func body(content: Content) -> some View {
        let ringed = controller.isRinged(kid)
        content
            .padding(.leading, 17)
            .padding(.trailing, 8)
            .background(on ? theme.raised : (hovering ? theme.hover : .clear), in: RoundedRectangle(cornerRadius: 8))
            // The focus ring, as an agent's row has it: over the row, so nothing in it moves.
            .overlay {
                if ringed { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent, lineWidth: 1).allowsHitTesting(false) }
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { controller.open(kid, from: rowPane) }
            .contextMenu {
                if let pane = kid.paneID {
                    Button { controller.focus(pane: pane) } label: { Label("Go to Its Tab", image: "ui.terminal") }
                } else {
                    Button { controller.open(kid, from: rowPane) } label: { Label("Show", image: "ui.terminal") }
                    Button { controller.keep(kid.terminal.address) } label: { Label("Keep as Tab", image: "ui.plus") }
                }
                Divider()
                Button(role: .destructive) { controller.close(kid) } label: { Label("Close", image: "ui.x") }
            }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

extension WorkspaceController {
    /// A child row is lit while it's shown: looked at, or its pane (kept) focused.
    func isShown(_ kid: SubAgent) -> Bool {
        peek == kid.terminal.address || (kid.paneID != nil && focusedPane?.id == kid.paneID)
    }

    /// The row with the focus ring: the focused pane's, but on the iPhone, while a
    /// sub-agent shows in its place, none (the sub-agent's row has it).
    var ringedPane: String? {
        singlePane && peek != nil ? nil : focusedPane?.id
    }

    /// A child row wears the focus ring while it's what the screen shows: its kept
    /// pane is focused, or (iPhone) it shows in its parent's place. The iPad's
    /// window over the panel leaves the ring on the focused pane's row.
    func isRinged(_ kid: SubAgent) -> Bool {
        if singlePane, let peek { return peek == kid.terminal.address }
        return kid.paneID != nil && kid.paneID == focusedPane?.id
    }
}

/// A sub-agent, read like its parent: its status and what it's on; under that
/// its model and @effort, and on the right its context size and how long it has
/// been in its state, in its parent's columns. 42 pt.
struct KidRow: View {
    var kid: SubAgent
    var rowPane: String
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        let on = controller.isShown(kid)
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            content(now: context.date, on: on)
        }
        .modifier(KidRowChrome(kid: kid, rowPane: rowPane, on: on))
    }

    private var t: TerminalInfo { kid.terminal }

    private var tickInterval: TimeInterval {
        let young = t.statusChangedAt.map { Date().timeIntervalSince($0) < 3600 } ?? false
        return young ? 1 : 30
    }

    private func content(now: Date, on: Bool) -> some View {
        let h = Tree.kidHeight(compact)
        let status = t.kidStatus
        let quiet = status == .idle && !on
        let meta = t.meta
        return HStack(alignment: .top, spacing: 0) {
            TreeLines(lines: kid.lines, height: h, mid: Tree.kidMid(compact))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    StatusMark(status: status).frame(width: 14)
                    Text(Format.kidTitle(t))
                        .font(.ui(compact ? 13.5 : 12.5))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: compact ? 23 : 20)
                HStack(spacing: 7) {
                    HStack(spacing: 4) {
                        Text(meta?.model ?? t.program.name)
                            .foregroundStyle(quiet ? theme.dim : theme.muted)
                            .lineLimit(1)
                        if let effort = meta?.effort, !effort.isEmpty {
                            Text("@" + effort).foregroundStyle(theme.effortColor(effort)).lineLimit(1).layoutPriority(1)
                        }
                    }
                    .font(.mono(compact ? 11.5 : 10.5))
                    .padding(.leading, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let ctx = Format.context(meta?.ctx) {
                        Text(ctx)
                            .font(.mono(compact ? 11.5 : 10.5))
                            .foregroundStyle(theme.contextNumberColor(cacheUntil: meta?.cacheUntil, now: now))
                            .frame(width: compact ? 38 : 34, alignment: .trailing)
                    }
                    Text(Format.age(since: t.statusChangedAt, now: now) ?? "")
                        .font(.mono(compact ? 11.5 : 10.5))
                        .foregroundStyle(theme.dim)
                        .frame(width: compact ? 29 : 26, alignment: .trailing)
                }
                .frame(height: compact ? 19 : 16)
            }
            .padding(.top, 3)
        }
        .frame(height: h, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: now, status: status))
    }

    private func accessibilityText(now: Date, status: AgentStatus?) -> String {
        var parts = ["Sub-agent", Format.kidTitle(t), Format.statusWord(status)]
        if let m = t.meta?.model { parts.append(m) }
        if let c = Format.context(t.meta?.ctx) { parts.append("\(c) context") }
        if let a = Format.age(since: t.statusChangedAt, now: now) { parts.append(a) }
        if kid.paneID != nil { parts.append("kept") }
        return parts.joined(separator: ", ")
    }
}

/// A plain terminal an agent started: its program's icon and name. 26 pt.
struct SubTerminalRow: View {
    var kid: SubAgent
    var rowPane: String
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        let on = controller.isShown(kid)
        let h = Tree.termHeight(compact)
        let t = kid.terminal
        HStack(spacing: 0) {
            TreeLines(lines: kid.lines, height: h, mid: h / 2)
            Group {
                if t.program.key != "program" {
                    ProgramIcon(program: t.program, size: 14, color: theme.foreground)
                } else {
                    Icon("terminal", size: 14, color: theme.muted)
                }
            }
            .frame(width: 14)
            .padding(.trailing, 8)
            Text(Format.kidTitle(t, plain: true))
                .font(.ui(compact ? 13.5 : 12.5))
                .foregroundStyle(on ? theme.foreground : theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: h)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal \(Format.kidTitle(t, plain: true))\(kid.paneID != nil ? ", kept" : "")")
        .modifier(KidRowChrome(kid: kid, rowPane: rowPane, on: on))
    }
}

// MARK: - Plain terminal row (§4.9)

struct TerminalRow: View {
    var terminal: TerminalInfo?
    var focused: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact
    @State private var hovering = false

    var body: some View {
        let home = controller.workspace.home
        HStack(spacing: 9) {
            Group {
                if let t = terminal, t.program.key != "program" {
                    ProgramIcon(program: t.program, size: 14, color: theme.muted)
                } else {
                    Icon("terminal", size: 14, color: theme.muted)
                }
            }
            .frame(width: 18)
            Text(terminal.map(Format.processName) ?? "terminal")
                .font(.ui(compact ? 14.5 : 13))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(terminal.map { Format.folder($0, home: home) } ?? "")
                .font(.mono(compact ? 11.5 : 10.5))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 38 : 28)
        .background(focused ? theme.selected : (hovering ? theme.hover : .clear), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent, lineWidth: 1) }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(terminal.map(Format.processName) ?? "terminal"), \(terminal.map { Format.folder($0, home: home) } ?? "")")
    }
}

/// A desktop mod pane (not rendered on iPad).
struct ModRow: View {
    var name: String
    var focused: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        HStack(spacing: 9) {
            Icon("file-text", size: 14, color: theme.muted).frame(width: 18)
            Text(name).font(.ui(compact ? 14.5 : 13)).foregroundStyle(theme.foreground).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 38 : 28)
        .background(focused ? theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent, lineWidth: 1) }
        }
    }
}
