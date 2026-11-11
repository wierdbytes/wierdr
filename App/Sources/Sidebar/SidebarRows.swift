import SwiftUI
import WierdrModel

/// One row under a space card: an agent (52 pt), a plain terminal (28 pt) or a
/// mod pane, with the split-tab bracket, tap-to-focus, context menu and swipes.
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
        let focused = controller.focusedPane?.id == row.paneID
        let tab = ws.tab(row.tabID)
        content(focused: focused, tab: tab)
            .overlay(alignment: .leading) {
                if bracket != .none {
                    BracketShape(position: bracket)
                        .stroke(theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 12)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { controller.focus(pane: row.paneID) }
            .contextMenu { menu }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipes }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingSwipes }
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func content(focused: Bool, tab: Tab?) -> some View {
        switch row.kind {
        case .agent:
            if let t = row.terminal {
                AgentRow(terminal: t, tab: tab, focused: focused, space: showsSpace ? space : nil)
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

    @ViewBuilder
    private var trailingSwipes: some View {
        Button(role: .destructive) { controller.closePane(row.paneID) } label: { Label("Close", systemImage: "xmark") }
            .tint(theme.blocked)
        if let t = row.terminal, t.isAgent {
            switch t.status {
            case .idle:
                Button { controller.markUnread(t.address) } label: { Label("Unread", systemImage: "circle.fill") }
                    .tint(theme.done)
            case .done:
                Button { controller.markRead(t.address) } label: {
                    // Swipe actions fill their symbols; the idle mark is a ring.
                    Label { Text("Idle") } icon: { Image(uiImage: UIImage(systemName: "circle") ?? UIImage()) }
                }
                .tint(theme.idle)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Agent row (§4.4)

struct AgentRow: View {
    var terminal: TerminalInfo
    var tab: Tab?
    var focused: Bool
    /// Shown before the model (rows of several spaces in one list).
    var space: Space? = nil

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// iPhone: a little larger, for fingers and arm's length.
    @Environment(\.isCompactLayout) private var compact
    @State private var hovering = false

    var body: some View {
        let children = controller.workspace.children(of: terminal.address)
        let expanded = controller.expandedAgents.contains(terminal.address) && !children.isEmpty
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                main(now: context.date, children: children, expanded: expanded)
            }
            if expanded {
                ForEach(Array(children.enumerated()), id: \.element.id) { i, child in
                    SubAgentRow(terminal: child, last: i == children.count - 1)
                }
            }
        }
    }

    /// Second ticks only while something visibly changes each second.
    private var tickInterval: TimeInterval {
        let now = Date()
        let young = terminal.statusChangedAt.map { now.timeIntervalSince($0) < 3600 } ?? false
        let cacheLive = terminal.meta?.cacheUntil.map { $0 > now } ?? false
        return young || cacheLive ? 1 : 30
    }

    private func main(now: Date, children: [TerminalInfo], expanded: Bool) -> some View {
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
                    let subs = (meta?.subagents ?? 0) + children.count
                    if subs > 0 {
                        SubAgentBadge(count: subs, open: expanded, tappable: !children.isEmpty) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expanded { controller.expandedAgents.remove(terminal.address) }
                                else { controller.expandedAgents.insert(terminal.address) }
                            }
                        }
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
        return parts.joined(separator: ", ")
    }
}

/// Sub-agents badge: `git-branch` icon + count; tappable when hc child agents exist.
struct SubAgentBadge: View {
    var count: Int
    var open: Bool
    var tappable: Bool
    var action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Icon("git-branch", size: 11, color: open ? theme.foreground : theme.muted)
            Text("\(count)")
                .font(.ui(11))
                .foregroundStyle(open ? theme.foreground : theme.muted)
                .frame(minWidth: 14)
        }
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(open ? theme.selected : (hovering && tappable ? theme.raised : theme.hover), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if tappable { action() } }
        .accessibilityLabel("\(count) sub-agents")
    }
}

/// An expanded sub-agent (§4.4.1), 26 pt, with a tree connector.
struct SubAgentRow: View {
    var terminal: TerminalInfo
    var last: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        HStack(spacing: 8) {
            Path { p in
                p.move(to: CGPoint(x: 4, y: 0))
                p.addLine(to: CGPoint(x: 4, y: last ? 7 : rowHeight))
                p.move(to: CGPoint(x: 4, y: 7))
                p.addQuadCurve(to: CGPoint(x: 9, y: 13), control: CGPoint(x: 4, y: 13))
            }
            .stroke(theme.input, lineWidth: 1.5)
            .frame(width: 9, height: rowHeight)
            ProgramIcon(program: terminal.program, size: 14, color: theme.foreground)
            Text(terminal.name ?? terminal.program.name)
                .font(.ui(compact ? 13.5 : 12.5))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatusMark(status: kidStatus)
        }
        .padding(.leading, 17)
        .padding(.trailing, 8)
        .frame(height: rowHeight)
    }

    private var rowHeight: CGFloat { compact ? 32 : 26 }

    /// Child status: core word, `error` → blocked, `done` → idle.
    private var kidStatus: AgentStatus? {
        switch terminal.state {
        case "working": return .working
        case "blocked", "error": return .blocked
        case "idle", "done": return .idle
        default: return terminal.status
        }
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
