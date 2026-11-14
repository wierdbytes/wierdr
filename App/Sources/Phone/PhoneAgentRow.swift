import SwiftUI
import WierdrModel

/// Sizes of the iPhone list's rows (Telegram's chat row at the default text size,
/// without the 60-pt avatar).
enum PhoneRowMetrics {
    /// Side insets; the text and the separators start here.
    static let inset: CGFloat = 16
    static let agentHeight: CGFloat = 76
    static let kidHeight: CGFloat = 50
    static let kidTerminalHeight: CGFloat = 36
    static let paneHeight: CGFloat = 60
    /// The status badge (Telegram's unread badge) and the pin glyph in its place.
    static let badge: CGFloat = 20
    /// A terminal row's icon; its text (and separator) start after it.
    static let paneIcon: CGFloat = 22
    static let paneTextLeading: CGFloat = inset + paneIcon + 12
    /// Where the sub-agents' tree starts, under the agent's text.
    static let treeLeading: CGFloat = 22
}

/// An agent's row, Telegram's chat row without the avatar (76 pt, full width):
/// 1. its title, and where Telegram has the date: its machine (dim) and how long
///    it has been in its state;
/// 2. its context (the number in its cache color, a ring with the cache's countdown
///    mark), its model (cut first when room runs out) and @effort;
/// 3. its sub-agents and terminals (tap: fold or unfold them), its space's name on a
///    gray chip as theirs (on "All"; cut when room runs out); on the right, Telegram's
///    unread badge: needs you (red), done (green), working (the spinner), nothing
///    while idle; the pin glyph there when it's pinned and has no badge.
struct PhoneAgentRowContent: View {
    var terminal: TerminalInfo
    var tab: Tab?
    var space: Space
    /// "All": the space's name leads line 3 (a space's tab is the space).
    var showsSpace: Bool
    var subtree: [SubAgent]
    /// Its sub-agents show under it.
    var open: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            content(now: context.date)
        }
    }

    /// Second ticks only while something visibly changes each second (`AgentRow`'s rule).
    private var tickInterval: TimeInterval {
        let now = Date()
        let young = terminal.statusChangedAt.map { now.timeIntervalSince($0) < 3600 } ?? false
        let cacheLive = terminal.meta?.cacheUntil.map { $0 > now } ?? false
        return young || cacheLive ? 1 : 30
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine(now: now).frame(height: 22)
            contextLine(now: now).frame(height: 20)
            spaceLine.frame(height: 22)
        }
        .padding(.top, 7)
        .padding(.horizontal, PhoneRowMetrics.inset)
        .frame(height: PhoneRowMetrics.agentHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: now))
        .accessibilityActions {
            if !subtree.isEmpty {
                Button(open ? "Hide Sub-agents" : "Show Sub-agents") { toggleKids() }
            }
        }
    }

    // MARK: Lines

    private func titleLine(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Format.agentTitle(terminal, tab: tab))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let machine = terminal.machine {
                    Text(machine)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.dim)
                        .lineLimit(1)
                }
                Text(Format.age(since: terminal.statusChangedAt, now: now) ?? "")
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(theme.muted)
            }
            .fixedSize()
        }
    }

    /// Context, then model and @effort: the model gives way first, @effort stays whole.
    private func contextLine(now: Date) -> some View {
        PhoneModelLine(terminal: terminal, now: now, contextFirst: true, size: 15)
    }

    private var spaceLine: some View {
        let kidAgents = subtree.filter(\.isAgent)
        let kidTerms = subtree.count - kidAgents.count
        // pi's own in-process sub-agents (pi-herdr's count) have no terminal: they only add to the count.
        let inner = terminal.meta?.subagents ?? 0
        return HStack(spacing: 8) {
            if kidAgents.count + inner > 0 {
                PhoneKidBadge(icon: "bot", count: kidAgents.count + inner, open: open,
                              alert: kidAgents.contains { $0.terminal.status == .blocked },
                              label: kidLabel(kidAgents.count, inner),
                              action: kidAgents.isEmpty ? nil : toggleKids)
                    .fixedSize()
            }
            if kidTerms > 0 {
                PhoneKidBadge(icon: "terminal", count: kidTerms, open: open, alert: false,
                              label: kidTerms == 1 ? "1 terminal" : "\(kidTerms) terminals", action: toggleKids)
                    .fixedSize()
            }
            if showsSpace {
                PhoneSpaceTag(name: space.displayName)
            }
            Spacer(minLength: 0)
            PhoneStatusBadge(status: terminal.status, pinned: terminal.pinned)
        }
    }

    // MARK: Actions

    /// Folds its sub-agents in or out (its badges).
    private func toggleKids() {
        withAnimation(.easeOut(duration: 0.2)) {
            if controller.foldedAgents.contains(terminal.address) {
                controller.foldedAgents.remove(terminal.address)
            } else {
                controller.foldedAgents.insert(terminal.address)
            }
        }
    }

    private func kidLabel(_ agents: Int, _ inner: Int) -> String {
        var parts: [String] = []
        if agents > 0 { parts.append(agents == 1 ? "1 sub-agent" : "\(agents) sub-agents") }
        if inner > 0 { parts.append("\(inner) in pi") }
        return parts.joined(separator: " + ")
    }

    private func accessibilityText(now: Date) -> String {
        var parts = [Format.agentTitle(terminal, tab: tab), Format.statusWord(terminal.status)]
        if showsSpace { parts.append("in \(space.displayName)") }
        if let m = terminal.machine { parts.append("on \(m)") }
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

// MARK: - Pieces

/// An agent's model line: its context (the number in its cache color and the ring)
/// and its model and @effort. The model is cut first when room runs out; the
/// context and @effort stay whole. An agent's row has the context first, a
/// sub-agent's after @effort.
struct PhoneModelLine: View {
    var terminal: TerminalInfo
    var now: Date
    var contextFirst: Bool
    var size: CGFloat
    /// A sub-agent's status (its own `kidStatus`): idle dims the model.
    var status: AgentStatus?? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        let meta = terminal.meta
        let quiet = (status ?? terminal.status) == .idle
        HStack(spacing: 8) {
            if contextFirst { context(meta) }
            HStack(spacing: 5) {
                Text(meta?.model ?? terminal.program.name)
                    .foregroundStyle(quiet ? theme.dim : theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let effort = meta?.effort, !effort.isEmpty {
                    PhoneRowText.effort(effort, theme: theme)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if !contextFirst { context(meta) }
            Spacer(minLength: 0)
        }
        .font(.system(size: size))
    }

    @ViewBuilder
    private func context(_ meta: AgentMeta?) -> some View {
        if let ctx = Format.context(meta?.ctx) {
            HStack(spacing: 8) {
                Text(ctx)
                    .font(.system(size: size).monospacedDigit())
                    .foregroundStyle(theme.contextNumberColor(cacheUntil: meta?.cacheUntil, now: now))
                PhoneContextRing(meta: meta, now: now)
            }
            .fixedSize()
        }
    }
}

/// A space's name on a gray chip, as the sub-agent and terminal counts (`PhoneKidBadge`),
/// no avatar; it is cut when room runs out.
struct PhoneSpaceTag: View {
    var name: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.hover, in: Capsule())
    }
}

/// Text of the rows.
enum PhoneRowText {
    /// `@effort` in its color; `max` in a per-letter gradient (`AgentRow`'s).
    static func effort(_ effort: String, theme: Theme) -> Text {
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
}

/// The bottom-right badge, where Telegram has the unread count: needs you and done
/// solid circles (a chat marked unread), working the spinner, idle nothing; the
/// pin glyph instead when pinned without one (an unread badge hides the pin).
struct PhoneStatusBadge: View {
    var status: AgentStatus?
    var pinned: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let d = PhoneRowMetrics.badge
        Group {
            switch status {
            case .blocked:
                Circle().fill(theme.blocked).frame(width: d, height: d)
            case .done:
                Circle().fill(theme.done).frame(width: d, height: d)
            case .working:
                Spinner(size: d, color: theme.working)
            case .idle, nil:
                if pinned {
                    Icon("ui.tg-pin", size: d, color: theme.dim)
                        .accessibilityLabel("Pinned")
                }
            }
        }
        // The glyph comes and goes at once (Telegram's), not with the row's move.
        .transition(.identity)
    }
}

/// The context window's use inline, as a ring: its fraction an arc from the top,
/// clockwise, in the context color over a dim track, and the prompt cache's countdown
/// mark across the ring, going round back to the top as the cache runs out (the
/// bar's mark going left).
struct PhoneContextRing: View {
    var meta: AgentMeta?
    var now: Date
    @Environment(\.theme) private var theme

    static let size: CGFloat = 16
    static let line: CGFloat = 2.5

    var body: some View {
        if let meta, let ctx = meta.ctx, let max = meta.ctxMax, max > 0 {
            let fraction = min(1, Swift.max(0, Double(ctx) / Double(max)))
            let d = Self.size
            ZStack {
                Circle()
                    .stroke(theme.input, lineWidth: Self.line)
                Circle()
                    .trim(from: 0, to: Swift.max(0.02, fraction))
                    .stroke(theme.contextBarColor(fraction), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let until = meta.cacheUntil, let ttl = meta.cacheTTL, ttl > 0, until > now {
                    let left = Swift.min(1, until.timeIntervalSince(now) / ttl)
                    // A tick across the ring, from the middle out to its edge.
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(theme.foreground.opacity(0.6))
                        .frame(width: 1.5, height: d / 2 - 1)
                        .offset(y: -(d / 4 - 0.5) - 0.5)
                        .rotationEffect(.degrees(360 * left))
                }
            }
            .padding(Self.line / 2)
            .frame(width: d + Self.line, height: d + Self.line)
            .accessibilityHidden(true)
        }
    }
}

/// An agent's count chip (bot 3, >_ 1): its sub-agents, its terminals; a tap
/// folds them in or out under the row (`ChildBadge` in the list's sizes).
struct PhoneKidBadge: View {
    var icon: String
    var count: Int
    var open: Bool
    /// One of them needs you.
    var alert: Bool
    var label: String
    var action: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        let color = alert ? theme.blocked : (open ? theme.foreground : theme.muted)
        let chip = HStack(spacing: 4) {
            Icon(icon, size: 13, color: color)
            Text("\(count)")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(open ? theme.selected : theme.hover, in: Capsule())
        if let action {
            Button(action: action) { chip.contentShape(Capsule()) }
                .buttonStyle(PressStyle())
                .accessibilityLabel(label)
                .accessibilityHint(open ? "Hides them" : "Shows them")
        } else {
            chip.accessibilityLabel(label)
        }
    }
}

// MARK: - Sub-agents

/// A sub-agent under its agent, in the agent's block (no separator between
/// them), indented with the tree's lines: its status mark and title, its age;
/// under that its model, @effort and, as an agent's row has it, its context (the
/// number and the ring). 50 pt. A plain terminal an agent
/// started: its program's icon and name, 36 pt.
struct PhoneKidRowContent: View {
    var kid: SubAgent
    /// The first under its agent: its lines reach up into the agent's row (the
    /// others' start at their top, so lines of the rows above aren't drawn twice).
    var first: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        if kid.isAgent {
            TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                agent(now: context.date)
            }
        } else {
            terminal
        }
    }

    private var t: TerminalInfo { kid.terminal }

    /// `TreeLines` reaches 4 pt up into the room above its row (the sidebar's gap);
    /// here rows touch, so all but the first start at their own top.
    @ViewBuilder
    private func tree(height h: CGFloat, mid: CGFloat) -> some View {
        if first {
            TreeLines(lines: kid.lines, height: h, mid: mid)
        } else {
            TreeLines(lines: kid.lines, height: h - 4, mid: mid - 4)
                .offset(y: 4)
                .frame(height: h, alignment: .top)
        }
    }

    /// Second ticks while its age or its cache's countdown mark visibly moves each second.
    private var tickInterval: TimeInterval {
        let now = Date()
        let young = t.statusChangedAt.map { now.timeIntervalSince($0) < 3600 } ?? false
        let cacheLive = t.meta?.cacheUntil.map { $0 > now } ?? false
        return young || cacheLive ? 1 : 30
    }

    private func agent(now: Date) -> some View {
        let h = PhoneRowMetrics.kidHeight
        let status = t.kidStatus
        return HStack(alignment: .top, spacing: 0) {
            tree(height: h, mid: 6 + 11)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    StatusMark(status: status).frame(width: 14)
                    Text(Format.kidTitle(t))
                        .font(.system(size: 15))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.age(since: t.statusChangedAt, now: now) ?? "")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(theme.muted)
                        .fixedSize()
                }
                .frame(height: 22)
                PhoneModelLine(terminal: t, now: now, contextFirst: false, size: 14, status: .some(status))
                    .padding(.leading, 22)
                    .frame(height: 18)
            }
            .padding(.top, 6)
        }
        .padding(.leading, PhoneRowMetrics.treeLeading)
        .padding(.trailing, PhoneRowMetrics.inset)
        .frame(height: h, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: now, status: status))
    }

    private var terminal: some View {
        let h = PhoneRowMetrics.kidTerminalHeight
        return HStack(spacing: 0) {
            tree(height: h, mid: h / 2)
            Group {
                if t.program.key != "program" {
                    ProgramIcon(program: t.program, size: 15, color: theme.foreground)
                } else {
                    Icon("terminal", size: 15, color: theme.muted)
                }
            }
            .frame(width: 14)
            .padding(.trailing, 8)
            Text(Format.kidTitle(t, plain: true))
                .font(.system(size: 15))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, PhoneRowMetrics.treeLeading)
        .padding(.trailing, PhoneRowMetrics.inset)
        .frame(height: h)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal \(Format.kidTitle(t, plain: true))\(kid.paneID != nil ? ", kept" : "")")
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

// MARK: - Terminals and panels

/// A plain terminal of a space's tab: its program's icon, the process's name and
/// under it the folder (60 pt); a desktop panel (mod pane): its name.
struct PhonePaneRowContent: View {
    var row: SidebarRow
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let t = row.terminal
        let home = controller.workspace.home
        let name = row.kind == .mod ? (row.mod ?? "panel") : (t.map(Format.processName) ?? "terminal")
        let detail = row.kind == .mod ? "Desktop panel" : (t.map { Format.folder($0, home: home) } ?? "")
        HStack(spacing: 12) {
            Group {
                if row.kind == .mod {
                    Icon("file-text", size: 20, color: theme.muted)
                } else if let t, t.program.key != "program" {
                    ProgramIcon(program: t.program, size: PhoneRowMetrics.paneIcon, color: theme.foreground)
                } else {
                    Icon("terminal", size: 20, color: theme.muted)
                }
            }
            .frame(width: PhoneRowMetrics.paneIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let machine = t?.machine {
                Text(machine)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.dim)
                    .fixedSize()
            }
        }
        .padding(.horizontal, PhoneRowMetrics.inset)
        .frame(height: PhoneRowMetrics.paneHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(detail)")
    }
}
