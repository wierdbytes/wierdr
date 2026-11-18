import SwiftUI
import WierdrModel

/// Go to (⌘P, or a list pulled past its end, `PullToSearch`), in the iPhone list's look
/// and, as it, drawn bottom up for a thumb (`GoToResults.lines`): over the field the
/// spaces (this computer's lowest, each added machine's over them under a divider with
/// its name), over them the agents, each with its sub-agents over it, as the list has
/// them. Typing filters them fuzzily (`Fuzzy`): spaces by name, agents and sub-agents
/// by title, the best lowest, the matched letters lit. Return goes to the first, the
/// row right over the field. A space: in the iPhone layout the sidebar, its card
/// unfolded and in view; on the iPad it's selected; an agent, its pane.
///
/// The field is at the bottom, over the list, in glass as the message field; it
/// rises with the keyboard. It has the keyboard from the start; the button at its
/// right puts the keyboard away, and so does scrolling (it slides down, the field with it).
/// The button is there from the start, with the keyboard, not brought in as the field
/// takes it (`keyboardButton`): its own spring under the keyboard's rise and the screen's
/// push made it move by fits.
///
/// On the iPad it's a sheet: it closes as sheets do (a swipe down, a tap beside it)
/// and with Esc; while the keyboard is up, a swipe down puts the keyboard away instead
/// (`KeyboardFirstDismissal`). In the iPhone layout it's a screen pushed over the others
/// (`inPanel`, `PhoneGoToRoot`): a swipe right anywhere on it pops it, as a pane
/// screen's; Esc closes it too.
struct QuickSwitcher: View {
    /// The iPhone layout's screen (false: a sheet).
    var inPanel = false
    /// From the field's bottom to its safe area's (`PhoneGoToRoot` sets the screen's, whose
    /// safe area's bottom comes here instead).
    var barBottom: CGFloat = 8

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @State private var swipes = PhoneRowSwipes()
    @State private var position = ScrollPosition(edge: .bottom)
    /// The list's height under its insets.
    @State private var viewport: CGFloat = 0
    /// The button that puts the keyboard away shows: from the start (the keyboard comes
    /// with Go to), then as the field has the keyboard.
    @State private var keyboardButton = true

    var body: some View {
        let results = GoToResults(controller.workspace, query: query, tree: { controller.shownTree(of: $0, forced: $1) })
        let lines = results.lines
        let topHeader = lines.first?.id
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    row(line, next: i + 1 < lines.count ? lines[i + 1].id : nil, top: line.id == topHeader)
                }
            }
            .padding(.bottom, 4)
            // Rows short of the list's height sit at its bottom, by the field.
            .frame(minHeight: viewport, alignment: .bottom)
        }
        .scrollPosition($position)
        // At rest at its bottom, and the rows by the field stay put as the rows or the
        // room change (a query, the keyboard). Not `.alignment`: the minimum height does it.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // The rows' room: the list's visible height (its container's, without its insets).
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, h in
            viewport = max(0, h)
        }
        // Not `scrollDismissesKeyboard`: its keyboard went at once. Losing focus slides it down.
        .scrollDismissesKeyboard(.never)
        .onScrollPhaseChange { _, phase in
            if phase == .interacting, fieldFocused { fieldFocused = false }
        }
        .background(theme.chrome)
        .overlay {
            if lines.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .bottomBar { bar(first: results.first) }
        .background {
            // With the keyboard up a swipe down puts it away; with it down, closes the sheet.
            if !inPanel { KeyboardFirstDismissal { fieldFocused = false } }
        }
        .environment(swipes)
        .onChange(of: query) { _, _ in position.scrollTo(edge: .bottom) }
        .onChange(of: fieldFocused) { _, focused in keyboardButton = focused }
        .onAppear { fieldFocused = true }
    }

    // MARK: Rows

    /// `top`: the topmost line (a header there has less room over it).
    @ViewBuilder
    private func row(_ line: GoToLine, next: String?, top: Bool) -> some View {
        switch line.kind {
        case .header(let title):
            Text(title)
                .font(.ui(15, .semibold))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, PhoneRowMetrics.inset)
                .padding(.top, top ? 12 : 24)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .machine(let name):
            GoToMachineDivider(name: name)
        case .space(let hit):
            listRow(line, next: next, to: .space(hit.space)) {
                GoToSpaceRow(hit: hit)
            }
        case .agent(let hit):
            if let t = hit.item.row.terminal {
                listRow(line, next: next, to: .pane(hit.item.row.paneID, hit.item.space)) {
                    PhoneAgentRowContent(terminal: t, tab: controller.workspace.tab(hit.item.row.tabID),
                                         space: hit.item.space, showsSpace: true, tree: hit.item.row.tree,
                                         hasKids: !hit.shown.isEmpty, titleMatch: hit.titleMatch)
                }
            }
        case .kid(let kid, let parent, let hasKids, let match):
            listRow(line, next: next, to: .kid(kid, from: parent.item.row.paneID, parent.item.space)) {
                PhoneKidRowContent(kid: kid, hasKids: hasKids,
                                   terminals: TreeFolds.terminals(of: kid.terminal.address, in: parent.item.row.tree),
                                   titleMatch: match)
            }
        case .record(let record, let parent, let match):
            listRow(line, next: next, to: .record(record, in: parent.item.row, parent.item.space)) {
                PhoneRecordRowContent(kid: record, titleMatch: match)
            }
        }
    }

    /// The list's row chrome (its press highlight and separators), no swipes or menu.
    private func listRow<Content: View>(_ line: GoToLine, next: String?, to target: GoToTarget,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        PhoneListRow(id: line.id, pinned: false, separator: line.separator, nextID: next,
                     edgeSwipesOnly: false, tap: { go(target) }) {
            content()
        }
    }

    // MARK: Field

    /// The field in its glass capsule and, while it has the keyboard, a glass circle at
    /// its right that puts the keyboard away (as the message field's attach button, on
    /// the other side).
    private func bar(first: GoToTarget?) -> some View {
        ComposerGlassGroup {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Icon("search", size: 18, color: theme.muted)
                    TextField("Go to", text: $query,
                              prompt: Text("Spaces, agents").foregroundColor(theme.foreground.opacity(theme.isDark ? 0.48 : 0.40)))
                        .font(.system(size: 17))
                        .foregroundStyle(theme.foreground)
                        .tint(theme.accent)
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { if let first { go(first) } }
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .frame(height: 44)
                .contentShape(Capsule())
                // A tap on the capsule's margins brings the keyboard too.
                .onTapGesture { fieldFocused = true }
                .composerGlass(Capsule(), theme: theme, interactive: false)
                if keyboardButton {
                    Button { fieldFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(theme.foreground)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(AttachPressStyle())
                    .composerGlass(Circle(), theme: theme)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Hide Keyboard")
                }
            }
            .animation(.snappy(duration: 0.25), value: keyboardButton)
        }
        .background {
            // Esc closes (no button for it on screen).
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, barBottom)
    }

    // MARK: Going

    /// Closes it: the sheet, or the iPhone's screen (it pops, `PhoneNavController.setGoTo`).
    private func close() {
        if inPanel {
            controller.showSwitcher = false
        } else {
            dismiss()
        }
    }

    private func go(_ target: GoToTarget) {
        let space: Space
        switch target {
        case .space(let s):
            space = s
            if controller.singlePane {
                // The iPhone layout: the sidebar, its card unfolded and in view (a pane screen over it goes).
                controller.showSidebar()
                controller.revealSpace = s.id
            } else {
                controller.select(space: s)
                controller.showPanel()
            }
        case .pane(let pane, let s):
            space = s
            controller.focus(pane: pane)
        case .kid(let kid, let rowPane, let s):
            space = s
            controller.open(kid, from: rowPane)
        case .record(let record, let row, let s):
            space = s
            controller.open(record, in: row)
        }
        if controller.showsMachines { controller.foldedMachines.remove(space.machine ?? "") }
        close()
    }
}

// MARK: - Results

/// Where a row of Go to leads.
enum GoToTarget {
    case space(Space)
    /// An agent's pane (and its space).
    case pane(String, Space)
    /// A sub-agent, as a tap on its row in the list opens it.
    case kid(SubAgent, from: String, Space)
    /// A record: the terminal reporting it, as a tap on its row in the list opens it.
    case record(RecordKid, in: SidebarRow, Space)
}

/// A space that matched: what it holds and its agents' statuses.
struct GoToSpaceHit {
    var space: Space
    var tally: SpaceTally
    var counts: [AgentStatus: Int]
    var match: [Int]
    var score: Int
}

/// An agent that matched, itself or by one of its sub-agents.
struct GoToAgentHit {
    var item: InboxItem
    var titleMatch: [Int]
    /// Its tree's matched letters (sub-agents' and records' titles), by `TreeNode.id`.
    var kidMatches: [String: [Int]]
    /// The best of its own score and its sub-agents'.
    var score: Int
    /// What of its tree shows under it: as in the list, and the rows that matched.
    var shown: [TreeNode]
    /// Where Return goes: the agent, or its sub-agent that matched best.
    var target: GoToTarget
}

/// One line of Go to, with the separator under it (as `PhoneListLine`'s).
struct GoToLine: Identifiable {
    enum Kind {
        case header(String)
        /// A machine's spaces under it (nil: this computer's).
        case machine(String?)
        case space(GoToSpaceHit)
        case agent(GoToAgentHit)
        /// `hasKids`: rows of its own children show over it.
        case kid(SubAgent, parent: GoToAgentHit, hasKids: Bool, match: [Int])
        case record(RecordKid, parent: GoToAgentHit, match: [Int])
    }

    var kind: Kind
    var id: String
    var separator: PhoneRowSeparator = .none
}

/// What Go to shows for a query: spaces by machine, then agents.
@MainActor
struct GoToResults {
    /// Spaces of each machine (`nil`: this computer), in Herdr's order of machines.
    var spaces: [(machine: String?, hits: [GoToSpaceHit])] = []
    var agents: [GoToAgentHit] = []

    /// `tree`: what of a row's tree shows, its matches (node ids) whatever the folds (`shownTree`).
    init(_ ws: Workspace, query: String, tree: (SidebarRow, Set<String>) -> [TreeNode]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let searching = !q.isEmpty

        // Spaces: no query, those that need you first; else the best first. Each machine's apart.
        var groups: [(machine: String?, hits: [GoToSpaceHit])] = []
        for space in ws.spaces {
            guard let m = Fuzzy.match(q, in: space.displayName) else { continue }
            let hit = GoToSpaceHit(space: space, tally: ws.sidebarRows(for: space).tally,
                                   counts: ws.agentCounts(in: space.id), match: m.indices, score: m.score)
            if let i = groups.firstIndex(where: { $0.machine == space.machine }) {
                groups[i].hits.append(hit)
            } else {
                groups.append((space.machine, [hit]))
            }
        }
        for i in groups.indices {
            groups[i].hits = Self.ranked(groups[i].hits) { hit in
                searching ? hit.score : (hit.space.status == .blocked ? 1 : 0)
            }
        }
        // This computer's first.
        spaces = groups.filter { $0.machine == nil } + groups.filter { $0.machine != nil }

        // Agents in the list's order ("All"); searching, the best first.
        var agents: [GoToAgentHit] = []
        for item in ws.phoneList(space: nil).agents {
            guard let t = item.row.terminal else { continue }
            let own = Fuzzy.match(q, in: Format.agentTitle(t, tab: ws.tab(item.row.tabID)))
            var kidMatches: [String: [Int]] = [:]
            var bestKid: (target: GoToTarget, score: Int)?
            if searching {
                for node in item.row.tree {
                    let title: String
                    let target: GoToTarget
                    switch node {
                    case .kid(let kid):
                        guard kid.isAgent else { continue }
                        title = Format.kidTitle(kid.terminal)
                        target = .kid(kid, from: item.row.paneID, item.space)
                    case .record(let record):
                        title = record.record.title
                        target = .record(record, in: item.row, item.space)
                    }
                    guard let m = Fuzzy.match(q, in: title) else { continue }
                    kidMatches[node.id] = m.indices
                    if m.score > (bestKid?.score ?? .min) { bestKid = (target, m.score) }
                }
            }
            guard own != nil || bestKid != nil else { continue }
            let ownScore = own?.score ?? .min
            let target: GoToTarget = if let bestKid, bestKid.score > ownScore {
                bestKid.target
            } else {
                .pane(item.row.paneID, item.space)
            }
            agents.append(GoToAgentHit(item: item, titleMatch: own?.indices ?? [], kidMatches: kidMatches,
                                       score: max(ownScore, bestKid?.score ?? .min),
                                       shown: tree(item.row, Set(kidMatches.keys)), target: target))
        }
        self.agents = searching ? Self.ranked(agents, by: \.score) : agents
    }

    /// Highest key first; equals keep their order.
    private static func ranked<T>(_ items: [T], by key: (T) -> Int) -> [T] {
        items.enumerated()
            .sorted { a, b in
                let ka = key(a.element), kb = key(b.element)
                return ka != kb ? ka > kb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Where Return goes: the first row (the lowest, right over the field).
    var first: GoToTarget? {
        if let hit = spaces.first?.hits.first { return .space(hit.space) }
        return agents.first?.target
    }

    /// Top to bottom, as drawn: bottom up, for a thumb. Under the "Agents" header the
    /// agents, the first lowest, each block upside down (its sub-agents over it, the
    /// tree's lines turned, `TreeLines.upward`); under the "Spaces" header the spaces,
    /// this computer's lowest and each added machine's over them (with machines there,
    /// each group under a divider with its machine's name, a header staying over what
    /// it names), the first lowest. Separators: inset between rows (none inside an
    /// agent's block), full width under the agents; none under a group or the bottom row.
    var lines: [GoToLine] {
        var out: [GoToLine] = []
        if !agents.isEmpty {
            out.append(GoToLine(kind: .header("Agents"), id: "header:agents"))
            for (i, hit) in agents.enumerated().reversed() {
                for (k, node) in hit.shown.enumerated().reversed() {
                    let match = hit.kidMatches[node.id] ?? []
                    switch node {
                    case .kid(let kid):
                        out.append(GoToLine(kind: .kid(kid, parent: hit, hasKids: hit.shown.hasKids(at: k), match: match), id: node.id))
                    case .record(let record):
                        out.append(GoToLine(kind: .record(record, parent: hit, match: match), id: node.id))
                    }
                }
                let separator: PhoneRowSeparator = i > 0 ? .inset(PhoneRowMetrics.inset) : (spaces.isEmpty ? .none : .full)
                out.append(GoToLine(kind: .agent(hit), id: hit.item.id, separator: separator))
            }
        }
        if !spaces.isEmpty {
            out.append(GoToLine(kind: .header("Spaces"), id: "header:spaces"))
            let textLeading = PhoneRowMetrics.inset + GoToSpaceRow.avatar + 12
            let labelled = spaces.count > 1
            for group in spaces.reversed() {
                if labelled {
                    out.append(GoToLine(kind: .machine(group.machine), id: "machine:\(group.machine ?? "")"))
                }
                for (i, hit) in group.hits.enumerated().reversed() {
                    out.append(GoToLine(kind: .space(hit), id: "space:\(hit.space.id)",
                                        separator: i > 0 ? .inset(textLeading) : .none))
                }
            }
        }
        return out
    }
}

// MARK: - Pieces

/// A space's row: its avatar, its name, under it what it holds as the agent
/// rows' chips (✦ agents, bot sub-agents, >_ terminals; none of what it hasn't);
/// on the right its agents' statuses but idle, as round badges with their counts
/// (the list header's). 60 pt.
struct GoToSpaceRow: View {
    var hit: GoToSpaceHit
    @Environment(\.theme) private var theme

    static let avatar: CGFloat = 30

    var body: some View {
        let detail = Self.detail(hit.tally)
        HStack(spacing: 12) {
            SpaceAvatar(space: hit.space, size: Self.avatar)
            VStack(alignment: .leading, spacing: 4) {
                MatchText.text(hit.space.displayName, matched: hit.match, color: theme.accent)
                    .font(.ui(16, .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                chips(hit.tally)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GoToStatusBadges(counts: hit.counts)
                .fixedSize()
        }
        .padding(.horizontal, PhoneRowMetrics.inset)
        .frame(height: PhoneRowMetrics.paneHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Space \(hit.space.displayName)")
        .accessibilityValue([detail, Format.summary(hit.counts.filter { $0.key != .idle })]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @ViewBuilder
    private func chips(_ tally: SpaceTally) -> some View {
        if tally.agents + tally.subAgents + tally.terminals == 0 {
            Text("Empty")
                .font(.ui(14))
                .foregroundStyle(theme.dim)
                .frame(height: 22)
        } else {
            HStack(spacing: 6) {
                chip("sparkle", tally.agents)
                chip("bot", tally.subAgents)
                chip("terminal", tally.terminals)
            }
        }
    }

    @ViewBuilder
    private func chip(_ icon: String, _ count: Int) -> some View {
        if count > 0 {
            PhoneKidBadge(icon: icon, count: count, open: false, alert: false, label: "", action: nil)
                .fixedSize()
        }
    }

    /// "2 agents · 3 sub-agents · 1 terminal" (none of what it hasn't), for VoiceOver.
    static func detail(_ tally: SpaceTally) -> String {
        func count(_ n: Int, _ word: String) -> String? {
            n > 0 ? "\(n) \(word)\(n == 1 ? "" : "s")" : nil
        }
        let parts = [count(tally.agents, "agent"), count(tally.subAgents, "sub-agent"), count(tally.terminals, "terminal")]
            .compactMap { $0 }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

/// A space's agents by status as the list header has them (needs you, done,
/// working; idle not): a round badge in the status's color with the count.
struct GoToStatusBadges: View {
    var counts: [AgentStatus: Int]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach([AgentStatus.blocked, .done, .working], id: \.self) { status in
                if let n = counts[status], n > 0 {
                    Text("\(n)")
                        .font(.ui(14, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(theme.color(for: status), in: Capsule())
                }
            }
        }
    }
}

/// The line over a machine's spaces: its icon and name (this computer's: "This
/// computer"), then a hairline.
struct GoToMachineDivider: View {
    /// nil: this computer.
    var name: String?
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shown = name ?? "This computer"
        HStack(spacing: 7) {
            Icon(name == nil ? "monitor" : "server", size: 13, color: theme.dim)
            Text(shown)
                .font(.ui(13))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .layoutPriority(1)
            Rectangle()
                .fill(theme.border)
                .frame(height: 1 / max(1, displayScale))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, PhoneRowMetrics.inset)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On \(shown)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Text with a search's matched letters in a color of their own.
enum MatchText {
    /// `text` with the characters at `matched` (offsets in its `Character`s) in `color`.
    static func text(_ text: String, matched: [Int], color: Color) -> Text {
        guard !matched.isEmpty else { return Text(text) }
        var out = AttributedString(text)
        let lit = Set(matched)
        var offset = 0
        var at = out.startIndex
        while at < out.endIndex {
            let next = out.characters.index(after: at)
            if lit.contains(offset) { out[at..<next].foregroundColor = color }
            offset += 1
            at = next
        }
        return Text(out)
    }
}

extension View {
    /// A bar at the bottom over the content, which goes on under it; on iOS 26
    /// with the scroll edge's soft fade under it.
    @ViewBuilder
    fileprivate func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
    }
}
