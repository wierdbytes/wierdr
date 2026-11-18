import SwiftUI
import WierdrModel

/// Sizes of the iPhone list's rows (Telegram's chat row at the default text size,
/// without the 60-pt avatar).
enum PhoneRowMetrics {
    /// Side insets; the text and the separators start here.
    static let inset: CGFloat = 16
    static let agentHeight: CGFloat = 56
    static let kidHeight: CGFloat = 50
    static let kidTerminalHeight: CGFloat = 36
    static let paneHeight: CGFloat = 60
    /// The pin glyph.
    static let badge: CGFloat = 20
    /// A terminal row's icon; its text (and separator) start after it.
    static let paneIcon: CGFloat = 22
    static let paneTextLeading: CGFloat = inset + paneIcon + 12
}

/// An agent's row, Telegram's chat row without the avatar (56 pt, full width):
/// 1. its title, and where Telegram has the date: its machine (dim) and how long
///    it has been in its state, on a pill of its status's color: needs you (red),
///    done (green), working (yellow), plain while idle (`PhoneAgeLabel`);
/// 2. its context's ring, its model (cut first when room runs out), @effort, its
///    sub-agents (`KidCounts`: the whole tree's, with those run in-process; tap: fold or
///    unfold them) and its own terminals (with its background shells; tap: show or hide
///    them, folded until then; its sub-agents' are on their rows); on the right its
///    space's name on a gray chip as theirs (in Go to; cut when room runs out) and the
///    pin glyph.
/// With rows of its tree over it, their line comes down its ring's axis into its top.
struct PhoneAgentRowContent: View {
    var terminal: TerminalInfo
    var tab: Tab?
    var space: Space
    /// The space's name on line 2 (Go to, where rows of all spaces mix; a card names its space).
    var showsSpace: Bool
    /// Its tree (`SidebarRow.tree`, all of it): sub-agents, terminals, records.
    var tree: [TreeNode]
    /// Rows of its tree show over it (their line comes into its top).
    var hasKids: Bool
    /// The title's letters a search matched (`Fuzzy`), drawn in the accent color.
    var titleMatch: [Int] = []

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: tickInterval)) { context in
            content(now: context.date)
        }
    }

    /// Second ticks only while something visibly changes each second (its age).
    private var tickInterval: TimeInterval {
        let now = Date()
        let young = terminal.statusChangedAt.map { now.timeIntervalSince($0) < 3600 } ?? false
        return young ? 1 : 30
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine(now: now).frame(height: 22)
            secondLine.frame(height: 22)
        }
        .padding(.top, 6)
        .padding(.horizontal, PhoneRowMetrics.inset)
        .frame(height: PhoneRowMetrics.agentHeight, alignment: .top)
        .background(alignment: .topLeading) {
            if hasKids {
                TreeLines(lines: [], height: PhoneRowMetrics.agentHeight, mid: 0, stub: Tree.rootStub)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: now))
        .accessibilityActions {
            if hasAgentRows {
                Button(agentsOpen ? "Hide Sub-agents" : "Show Sub-agents") { controller.toggleKids(of: terminal.address) }
            }
            if terminals.total > 0 {
                Button(terminalsOpen ? "Hide Terminals" : "Show Terminals") { controller.toggleTerminals(of: terminal.address) }
            }
        }
    }

    private var agentsOpen: Bool { controller.showsKids(of: terminal.address) }
    private var terminalsOpen: Bool { controller.openTerminals.contains(terminal.address) }
    /// Its tree has sub-agents' rows to fold (pi's in-process ones have none).
    private var hasAgentRows: Bool { tree.contains { !$0.isTerminal } }
    /// Its own terminals (`>_`).
    private var terminals: TerminalTally { TreeFolds.terminals(of: terminal.address, in: tree) }

    // MARK: Lines

    private func titleLine(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MatchText.text(Format.agentTitle(terminal, tab: tab), matched: titleMatch, color: theme.accent)
                .font(.ui(16, .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let machine = terminal.machine {
                    Text(machine)
                        .font(.ui(13))
                        .foregroundStyle(theme.dim)
                        .lineLimit(1)
                }
                PhoneAgeLabel(age: Format.age(since: terminal.statusChangedAt, now: now), status: terminal.status)
            }
            .fixedSize()
        }
    }

    /// The context's ring, model, @effort (the model gives way first), the sub-agents' and
    /// terminals' chips, then on the right the space (Go to) and the pin.
    private var secondLine: some View {
        let counts = KidCounts(terminal: terminal, tree: tree)
        let address = terminal.address
        return HStack(spacing: 8) {
            PhoneModelLine(terminal: terminal, size: 13, ring: .leading)
            if counts.agents > 0 {
                // In-process sub-agents without records (pi's) have no rows to fold.
                PhoneKidBadge(icon: "bot", count: counts.agents, open: agentsOpen && hasAgentRows,
                              alert: counts.alert, label: kidLabel(counts),
                              action: hasAgentRows ? { controller.toggleKids(of: address) } : nil)
                    .fixedSize()
            }
            if counts.allTerminals > 0 {
                PhoneKidBadge(icon: "terminal", count: counts.allTerminals, open: terminalsOpen, alert: false,
                              label: PhoneKidBadge.terminalLabel(TerminalTally(terminals: counts.terminals, shells: counts.shells)),
                              action: { controller.toggleTerminals(of: address) })
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if showsSpace {
                PhoneSpaceTag(name: space.displayName)
            }
            if terminal.pinned {
                Icon("ui.tg-pin", size: PhoneRowMetrics.badge, color: theme.dim)
                    .accessibilityLabel("Pinned")
                    // The glyph comes and goes at once (Telegram's), not with the row's move.
                    .transition(.identity)
            }
        }
    }

    // MARK: Labels

    private func kidLabel(_ counts: KidCounts) -> String {
        var parts: [String] = []
        let agents = counts.terminalAgents, inner = counts.inProcess
        if agents > 0 { parts.append(agents == 1 ? "1 sub-agent" : "\(agents) sub-agents") }
        if inner > 0 { parts.append("\(inner) in \(terminal.program.name)") }
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
        let counts = KidCounts(terminal: terminal, tree: tree)
        if counts.agents > 0 { parts.append(counts.agents == 1 ? "1 sub-agent" : "\(counts.agents) sub-agents") }
        if counts.allTerminals > 0 {
            parts.append(PhoneKidBadge.terminalLabel(TerminalTally(terminals: counts.terminals, shells: counts.shells)))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Pieces

/// An agent's model line: its model, @effort and its context's ring. The model is cut
/// first when room runs out; @effort and the ring stay whole.
struct PhoneModelLine: View {
    /// Where its context's ring goes.
    enum Ring {
        /// Before the model, and the line only as wide as it is (an agent's and a sub-agent's
        /// row, where their chips follow; under the title's first letter).
        case leading
        /// After @effort, the line taking the room left.
        case trailing
    }

    var meta: AgentMeta?
    /// The model slot without a model (no `agent.*`): its program's name.
    var fallback: String
    var size: CGFloat
    /// Idle dims the model.
    var status: AgentStatus?
    var ring: Ring = .trailing
    @Environment(\.theme) private var theme

    /// A terminal's: its `agent.*`, its program; `status` a sub-agent's own (`kidStatus`),
    /// else the terminal's.
    init(terminal: TerminalInfo, size: CGFloat, status: AgentStatus?? = nil, ring: Ring = .trailing) {
        self.init(meta: terminal.meta, fallback: terminal.program.name, size: size,
                  status: status ?? terminal.status, ring: ring)
    }

    /// A record's (`TaskRecord.meta`), in its terminal's program's name without one.
    init(meta: AgentMeta?, fallback: String, size: CGFloat, status: AgentStatus?, ring: Ring = .trailing) {
        self.meta = meta; self.fallback = fallback; self.size = size; self.status = status
        self.ring = ring
    }

    var body: some View {
        let quiet = status == .idle
        HStack(spacing: 8) {
            if ring == .leading {
                PhoneContextRing(meta: meta).fixedSize()
            }
            HStack(spacing: 5) {
                Text(meta?.model ?? fallback)
                    .foregroundStyle(quiet ? theme.dim : theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let effort = meta?.effort, !effort.isEmpty {
                    PhoneRowText.effort(effort, theme: theme)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if ring == .trailing {
                PhoneContextRing(meta: meta).fixedSize()
                Spacer(minLength: 0)
            }
        }
        .font(.mono(size))
    }
}

/// A space's name on a gray chip, as the sub-agent and terminal counts (`PhoneKidBadge`),
/// no avatar; it is cut when room runs out.
struct PhoneSpaceTag: View {
    var name: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(name)
            .font(.ui(13, .medium))
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
    /// `@effort` in its color; `max` (and Codex's `ultra`) in a per-letter gradient.
    static func effort(_ effort: String, theme: Theme) -> Text {
        if Theme.isGradientEffort(effort) {
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

/// How long an agent has been in its state, where Telegram has the date: on a pill
/// filled with its status's color (needs you, done, working), as the header's counts
/// (`StatusBadges`); plain muted text while idle.
struct PhoneAgeLabel: View {
    var age: String?
    var status: AgentStatus?
    @Environment(\.theme) private var theme

    var body: some View {
        let text = Text(age ?? "").font(.mono(13))
        if let status, status != .idle {
            text
                .foregroundStyle(theme.background)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(theme.color(for: status), in: Capsule())
        } else {
            text.foregroundStyle(theme.muted)
        }
    }
}

/// The context window's use inline, as a ring: its fraction an arc from the top,
/// clockwise, in the context color over a dim track.
struct PhoneContextRing: View {
    var meta: AgentMeta?
    @Environment(\.theme) private var theme

    static let size: CGFloat = 16
    static let line: CGFloat = 2.5

    var body: some View {
        if let meta, let ctx = meta.ctx, ctx > 0, let max = meta.ctxMax, max > 0 {
            let fraction = min(1, Swift.max(0, Double(ctx) / Double(max)))
            let d = Self.size
            ZStack {
                Circle()
                    .stroke(theme.input, lineWidth: Self.line)
                Circle()
                    .trim(from: 0, to: Swift.max(0.02, fraction))
                    .stroke(theme.contextBarColor(fraction), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(Self.line / 2)
            .frame(width: d + Self.line, height: d + Self.line)
            .accessibilityHidden(true)
        }
    }
}

/// An agent's count chip (bot 3, >_ 1): its sub-agents, its terminals; a tap folds them
/// in or out over the row (`ChildBadge` in the list's sizes). `compact`: a sub-agent's,
/// on its smaller second line.
struct PhoneKidBadge: View {
    var icon: String
    var count: Int
    var open: Bool
    /// One of them needs you.
    var alert: Bool
    var label: String
    var compact = false
    var action: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        let color = alert ? theme.blocked : (open ? theme.foreground : theme.muted)
        let chip = HStack(spacing: compact ? 3 : 4) {
            Icon(icon, size: compact ? 12 : 13, color: color)
            Text("\(count)")
                .font(.ui(compact ? 12 : 13, .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, compact ? 6 : 7)
        .frame(height: compact ? 18 : 22)
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

    /// "2 terminals + 1 background shell".
    static func terminalLabel(_ tally: TerminalTally) -> String {
        var parts: [String] = []
        let t = tally.terminals, s = tally.shells
        if t > 0 { parts.append(t == 1 ? "1 terminal" : "\(t) terminals") }
        if s > 0 { parts.append(s == 1 ? "1 background shell" : "\(s) background shells") }
        return parts.joined(separator: " + ")
    }
}

// MARK: - Sub-agents

/// The marks' column of a row of an agent's tree (`Tree`): a sub-agent's status dot, a
/// terminal's icon, centred on its depth's axis, midway between its elbow and its text.
private struct TreeMark<Content: View>: View {
    @ViewBuilder var content: Content
    /// The column keeps its width without a mark (no context ring): the text stays in line.
    var body: some View {
        Color.clear
            .frame(width: Tree.mark, height: 1)
            .overlay { content.fixedSize() }
    }
}

/// The tree's line metrics of a row: a mark's half width and where the line of its
/// children (over it) stops above its mark.
private enum TreeRow {
    /// The status dot (`StatusMark`, 7 pt).
    static let dot: CGFloat = 3.5
    /// A terminal's icon (15 pt).
    static let icon: CGFloat = 7.5
    /// A sub-agent's first line's middle (its dot's).
    static let agentMid: CGFloat = 6 + 11
    /// Its children's line down to its dot.
    static let agentStub: CGFloat = agentMid - dot - Tree.markGap
}

/// A sub-agent over its agent (the lists are drawn bottom up: an agent's block is its
/// sub-agents, then the agent), in the agent's block (no separator between them), on the
/// tree's lines upside down (`TreeLines`), its mark on its depth's axis (`Tree`): its
/// status dot, title and age; under the title, from its first letter as an agent's row, its
/// context's ring, model, @effort and the chip of the terminals it started (`>_`, a tap shows or hides them; folded until then). 50 pt.
/// A plain terminal an agent started: its program's icon and name, 36 pt.
struct PhoneKidRowContent: View {
    var kid: SubAgent
    /// Rows of its own children show over it: their line comes down to its mark.
    var hasKids: Bool
    /// The terminals it started (`TreeFolds.terminals(of:in:)`): its `>_` chip.
    var terminals = TerminalTally()
    /// A sub-agent's title's letters a search matched (`Fuzzy`), in the accent color.
    var titleMatch: [Int] = []
    @Environment(WorkspaceController.self) private var controller
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
    private var depth: Int { kid.lines.count }
    private var terminalsOpen: Bool { controller.openTerminals.contains(t.address) }

    /// Second ticks while its age visibly moves each second.
    private var tickInterval: TimeInterval {
        let now = Date()
        let young = t.statusChangedAt.map { now.timeIntervalSince($0) < 3600 } ?? false
        return young ? 1 : 30
    }

    private func agent(now: Date) -> some View {
        let h = PhoneRowMetrics.kidHeight
        let status = t.kidStatus
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TreeMark { StatusMark(status: status) }
                MatchText.text(Format.kidTitle(t), matched: titleMatch, color: theme.accent)
                    .font(.ui(15))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.age(since: t.statusChangedAt, now: now) ?? "")
                    .font(.mono(13))
                    .foregroundStyle(theme.muted)
                    .fixedSize()
                    .padding(.leading, 8)
            }
            .frame(height: 22)
            HStack(spacing: 8) {
                PhoneModelLine(terminal: t, size: 12.5, status: .some(status), ring: .leading)
                if terminals.total > 0 {
                    PhoneKidBadge(icon: "terminal", count: terminals.total, open: terminalsOpen, alert: false,
                                  label: PhoneKidBadge.terminalLabel(terminals), compact: true,
                                  action: { controller.toggleTerminals(of: t.address) })
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Tree.textLeading)
            .frame(height: 18)
        }
        .padding(.top, 6)
        .padding(.leading, Tree.leading(depth))
        .padding(.trailing, PhoneRowMetrics.inset)
        .frame(height: h, alignment: .top)
        .background(alignment: .topLeading) {
            TreeLines(lines: kid.lines, height: h, mid: TreeRow.agentMid,
                      stub: hasKids ? TreeRow.agentStub : nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: now, status: status))
        .accessibilityActions {
            if terminals.total > 0 {
                Button(terminalsOpen ? "Hide Terminals" : "Show Terminals") { controller.toggleTerminals(of: t.address) }
            }
        }
    }

    private var terminal: some View {
        let h = PhoneRowMetrics.kidTerminalHeight
        return HStack(spacing: 0) {
            TreeMark {
                if t.program.key != "program" {
                    ProgramIcon(program: t.program, size: 15, color: theme.foreground)
                } else {
                    Icon("terminal", size: 15, color: theme.muted)
                }
            }
            Text(Format.kidTitle(t, plain: true))
                .font(.ui(15))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Tree.leading(depth))
        .padding(.trailing, PhoneRowMetrics.inset)
        .frame(height: h)
        .background(alignment: .topLeading) {
            TreeLines(lines: kid.lines, height: h, mid: h / 2,
                      stub: hasKids ? h / 2 - TreeRow.icon - Tree.markGap : nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal \(Format.kidTitle(t, plain: true))\(kid.paneID != nil ? ", kept" : "")")
    }

    private func accessibilityText(now: Date, status: AgentStatus?) -> String {
        var parts = ["Sub-agent", Format.kidTitle(t), Format.statusWord(status)]
        if let m = t.meta?.model { parts.append(m) }
        if let c = Format.context(t.meta?.ctx) { parts.append("\(c) context") }
        if let a = Format.age(since: t.statusChangedAt, now: now) { parts.append(a) }
        if terminals.total > 0 { parts.append(PhoneKidBadge.terminalLabel(terminals)) }
        if kid.paneID != nil { parts.append("kept") }
        return parts.joined(separator: ", ")
    }
}

/// A record in an agent's tree (`RecordKid`): work a terminal of the tree runs in-process
/// and reports as a 7501 record or in `agent.subagents_meta` (Claude Code's and Codex's
/// sub-agents, Claude's teammates and background shells). A sub-agent or teammate is drawn
/// as a sub-agent with a terminal (`PhoneKidRowContent`, 50 pt): its status's dot (working,
/// needs you, idle: a teammate between turns) and title, how long it has been so; under
/// the title its context's ring, model and @effort (`TaskRecord.meta`; without it the terminal's
/// program's name, and no age). A shell as a plain terminal (36 pt): the dot and its title.
/// No swipes, no menu: a tap opens the terminal reporting it.
struct PhoneRecordRowContent: View {
    var kid: RecordKid
    /// Its title's letters a search matched (`Fuzzy`), in the accent color.
    var titleMatch: [Int] = []
    @Environment(\.theme) private var theme

    var body: some View {
        if kid.record.kind == .agent {
            TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                agent(now: context.date)
            }
        } else {
            shell
        }
    }

    private var depth: Int { kid.lines.count }

    /// Second ticks while its age visibly moves each second.
    private var tickInterval: TimeInterval {
        let young = kid.record.ageSince.map { Date().timeIntervalSince($0) < 3600 } ?? false
        return young ? 1 : 30
    }

    private func agent(now: Date) -> some View {
        let h = PhoneRowMetrics.kidHeight
        let r = kid.record
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                TreeMark { StatusMark(status: r.status) }
                MatchText.text(r.title, matched: titleMatch, color: theme.accent)
                    .font(.ui(15))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Format.age(since: r.ageSince, now: now) ?? "")
                    .font(.mono(13))
                    .foregroundStyle(theme.muted)
                    .fixedSize()
                    .padding(.leading, 8)
            }
            .frame(height: 22)
            PhoneModelLine(meta: r.meta, fallback: kid.program ?? "", size: 12.5, status: r.status, ring: .leading)
                .padding(.leading, Tree.textLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 18)
        }
        .padding(.top, 6)
        .padding(.leading, Tree.leading(depth))
        .padding(.trailing, PhoneRowMetrics.inset)
        .frame(height: h, alignment: .top)
        .background(alignment: .topLeading) {
            TreeLines(lines: kid.lines, height: h, mid: TreeRow.agentMid)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(r, now: now))
        .accessibilityHint("Opens its agent")
    }

    private var shell: some View {
        let h = PhoneRowMetrics.kidTerminalHeight
        let r = kid.record
        return HStack(spacing: 0) {
            TreeMark { StatusMark(status: r.status) }
            MatchText.text(r.title, matched: titleMatch, color: theme.accent)
                .font(.ui(15))
                .foregroundStyle(r.status == .idle ? theme.muted : theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Tree.leading(depth))
        .padding(.trailing, PhoneRowMetrics.inset)
        .frame(height: h)
        .background(alignment: .topLeading) {
            TreeLines(lines: kid.lines, height: h, mid: h / 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(r, now: Date()))
        .accessibilityHint("Opens its agent")
    }

    static func accessibilityText(_ r: TaskRecord, now: Date) -> String {
        var parts = [r.kind == .shell ? "Background shell" : "Background sub-agent", r.title, Format.statusWord(r.status)]
        if let n = r.name, n != r.title { parts.append("named \(n)") }
        if r.status == .blocked, let m = r.message, m != r.title { parts.append(m) }
        if let m = r.meta?.model { parts.append(m) }
        if let e = r.meta?.effort { parts.append("effort \(e)") }
        if let c = Format.context(r.meta?.ctx) { parts.append("\(c) context") }
        if let a = Format.age(since: r.ageSince, now: now) { parts.append(a) }
        if let p = r.progress { parts.append("\(p) percent") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Terminals and panels

/// A plain terminal of a space: its program's icon, the process's name and
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
                    .font(.ui(16, .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(detail)
                    .font(.mono(13))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let machine = t?.machine {
                Text(machine)
                    .font(.ui(13))
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
