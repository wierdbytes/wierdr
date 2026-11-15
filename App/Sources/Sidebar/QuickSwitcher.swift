import SwiftUI
import WierdrModel

/// Go to (⌘P, the search button), in the iPhone list's look: spaces (this
/// computer's, then each added machine's under a divider with its name), then
/// agents with their sub-agents under them, as the list has them. Typing filters
/// them fuzzily (`Fuzzy`): spaces by name, agents and sub-agents by title, the
/// best first, the matched letters lit. Return goes to the first. A space opens
/// its tab of the iPhone list (the iPad's sidebar: selects it); an agent, its pane.
///
/// The field is at the bottom, over the list, in glass as the message field; it
/// rises with the keyboard. It has the keyboard from the start; scrolling puts
/// the keyboard away (it slides down, the field with it). The sheet closes as
/// sheets do (a swipe down, a tap beside it on the iPad) and with Esc; while
/// the keyboard is up, a swipe down puts the keyboard away instead
/// (`KeyboardFirstDismissal`).
struct QuickSwitcher: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @State private var swipes = PhoneRowSwipes()
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        let results = GoToResults(controller.workspace, query: query, showsKids: controller.showsKids(of:))
        let lines = results.lines
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    row(line, next: i + 1 < lines.count ? lines[i + 1].id : nil)
                }
            }
            .padding(.top, 4)
        }
        .scrollPosition($position)
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
        // With the keyboard up a swipe down puts it away; with it down, closes the sheet.
        .background(KeyboardFirstDismissal { fieldFocused = false })
        .environment(swipes)
        .onChange(of: query) { _, _ in position.scrollTo(edge: .top) }
        .onAppear { fieldFocused = true }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ line: GoToLine, next: String?) -> some View {
        switch line.kind {
        case .header(let title):
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, PhoneRowMetrics.inset)
                .padding(.top, line.id == GoToLine.firstHeaderID ? 12 : 24)
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
                                         space: hit.item.space, showsSpace: true, subtree: hit.item.row.subtree,
                                         open: hit.showsKids, titleMatch: hit.titleMatch)
                }
            }
        case .kid(let kid, let parent, let first, let match):
            listRow(line, next: next, to: .kid(kid, from: parent.item.row.paneID, parent.item.space)) {
                PhoneKidRowContent(kid: kid, first: first, titleMatch: match)
            }
        }
    }

    /// The list's row chrome (its press highlight and separators), no swipes or menu.
    private func listRow<Content: View>(_ line: GoToLine, next: String?, to target: GoToTarget,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        PhoneListRow(id: line.id, pinned: false, separator: line.separator, nextID: next,
                     edgeSwipesOnly: false, tap: { go(target) }) {
            EmptyView()
        } content: {
            content()
        }
    }

    // MARK: Field

    private func bar(first: GoToTarget?) -> some View {
        ComposerGlassGroup {
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
        }
        .background {
            // Esc closes (no button for it on screen).
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Going

    private func go(_ target: GoToTarget) {
        let space: Space
        switch target {
        case .space(let s):
            space = s
            if controller.singlePane {
                // The iPhone layout: the list, on the space's tab (a pane screen over it goes).
                controller.showSidebar()
                controller.listTabRequest = s.id
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
        }
        if controller.showsMachines { controller.foldedMachines.remove(space.machine ?? "") }
        dismiss()
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
    /// Its sub-agents' matched letters, by address.
    var kidMatches: [String: [Int]]
    /// The best of its own score and its sub-agents'.
    var score: Int
    /// Its sub-agents show under it: as in the list, or because one of them matched.
    var showsKids: Bool
    /// Where Return goes: the agent, or its sub-agent that matched best.
    var target: GoToTarget
}

/// One line of Go to, with the separator under it (as `PhoneListLine`'s).
struct GoToLine: Identifiable {
    enum Kind {
        case header(String)
        case machine(String)
        case space(GoToSpaceHit)
        case agent(GoToAgentHit)
        case kid(SubAgent, parent: GoToAgentHit, first: Bool, match: [Int])
    }

    static let firstHeaderID = "header:spaces"

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

    init(_ ws: Workspace, query: String, showsKids: (SidebarRow) -> Bool) {
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
            var bestKid: (kid: SubAgent, score: Int)?
            if searching {
                for kid in item.row.subtree where kid.isAgent {
                    guard let m = Fuzzy.match(q, in: Format.kidTitle(kid.terminal)) else { continue }
                    kidMatches[kid.terminal.address] = m.indices
                    if m.score > (bestKid?.score ?? .min) { bestKid = (kid, m.score) }
                }
            }
            guard own != nil || bestKid != nil else { continue }
            let ownScore = own?.score ?? .min
            let target: GoToTarget = if let bestKid, bestKid.score > ownScore {
                .kid(bestKid.kid, from: item.row.paneID, item.space)
            } else {
                .pane(item.row.paneID, item.space)
            }
            agents.append(GoToAgentHit(item: item, titleMatch: own?.indices ?? [], kidMatches: kidMatches,
                                       score: max(ownScore, bestKid?.score ?? .min),
                                       showsKids: showsKids(item.row) || !kidMatches.isEmpty, target: target))
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

    /// Where Return goes: the first row.
    var first: GoToTarget? {
        if let hit = spaces.first?.hits.first { return .space(hit.space) }
        return agents.first?.target
    }

    var lines: [GoToLine] {
        var out: [GoToLine] = []
        if !spaces.isEmpty {
            out.append(GoToLine(kind: .header("Spaces"), id: GoToLine.firstHeaderID))
            let textLeading = PhoneRowMetrics.inset + GoToSpaceRow.avatar + 12
            for (g, group) in spaces.enumerated() {
                if let machine = group.machine {
                    out.append(GoToLine(kind: .machine(machine), id: "machine:\(machine)"))
                }
                for (i, hit) in group.hits.enumerated() {
                    let lastOfGroup = i == group.hits.count - 1
                    let last = lastOfGroup && g == spaces.count - 1
                    // None before a machine's divider (it has its own line).
                    let separator: PhoneRowSeparator = last ? .full : (lastOfGroup ? .none : .inset(textLeading))
                    out.append(GoToLine(kind: .space(hit), id: "space:\(hit.space.id)", separator: separator))
                }
            }
        }
        if !agents.isEmpty {
            out.append(GoToLine(kind: .header("Agents"), id: out.isEmpty ? GoToLine.firstHeaderID : "header:agents"))
            for (i, hit) in agents.enumerated() {
                var block = [GoToLine(kind: .agent(hit), id: hit.item.id)]
                if hit.showsKids {
                    block += hit.item.row.subtree.enumerated().map { k, kid in
                        GoToLine(kind: .kid(kid, parent: hit, first: k == 0, match: hit.kidMatches[kid.terminal.address] ?? []),
                                 id: "kid:\(kid.terminal.address)")
                    }
                }
                block[block.count - 1].separator = i == agents.count - 1 ? .full : .inset(PhoneRowMetrics.inset)
                out += block
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
                    .font(.system(size: 16, weight: .semibold))
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
                .font(.system(size: 15))
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
                        .font(.system(size: 14, weight: .semibold))
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

/// The line before an added machine's spaces: its icon and name, then a hairline.
struct GoToMachineDivider: View {
    var name: String
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 7) {
            Icon("server", size: 13, color: theme.dim)
            Text(name)
                .font(.system(size: 13))
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
        .accessibilityLabel("On \(name)")
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
