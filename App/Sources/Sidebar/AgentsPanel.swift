import SwiftUI
import UIKit
import WierdrModel

/// The agents panel: every agent of every space and computer in the sidebar's rows, by
/// status (`Workspace.agentsByStatus`: needs you, done, working, idle; pinned first in
/// each, then the newest), drawn bottom up for a thumb as the sidebar's list is (the most
/// urgent lowest, by the search field), each agent's tree over it as the list has it.
/// Typing filters them fuzzily (`Fuzzy`) by their titles and their sub-agents' and
/// background tasks', the best lowest, the matched letters lit; Return opens the lowest.
/// A tap opens an agent's pane (a sub-agent, as a tap on its row in the list does), and
/// the panel stays: on the iPhone the swipe back from the pane screen comes back to it,
/// on the iPad the row stays lit beside the pane. Held, a row has the list's menu, and its
/// swipes are the list's (`RowActions`), from its edges only (`edgeSwipesOnly`): a swipe
/// right in between puts the panel back.
///
/// It's pushed over the spaces in the sidebar itself, from the right, and a swipe right
/// anywhere on it puts it back, as a pane screen's (`SidebarNavController`): the status
/// ring's tap, ⌘P. The field doesn't take the keyboard as the panel comes (a tap on the
/// ring is to look), ⌘P's does; the button at its right puts the keyboard away, and so
/// does scrolling. Esc in the field closes the panel.
struct AgentsPanel: View {
    /// From the field's bottom to its safe area's (`AgentsPanelRoot` sets the sidebar's,
    /// whose safe area's bottom comes here instead).
    var barBottom: CGFloat = 8

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var fieldFocused = false
    @State private var swipes = PhoneRowSwipes()
    @State private var position = ScrollPosition(edge: .bottom)
    /// The list's height under its insets.
    @State private var viewport: CGFloat = 0

    var body: some View {
        let results = AgentsResults(controller.workspace, query: query, tree: { controller.shownTree(of: $0, forced: $1) })
        let lines = results.lines
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    row(line, next: i + 1 < lines.count ? lines[i + 1].id : nil)
                }
            }
            .padding(.bottom, 4)
            // Rows short of the list's height sit at its bottom, by the field.
            .frame(minHeight: viewport, alignment: .bottom)
            // A tap off the rows closes an open row.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closeRows() }
            }
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
            guard phase == .interacting else { return }
            if fieldFocused { fieldFocused = false }
            // Scrolling closes an open row (Telegram: as the list's drag begins).
            if swipes.openID != nil { swipes.closeAll() }
        }
        .background(theme.chrome)
        .overlay {
            if lines.isEmpty { empty }
        }
        .bottomBar { bar(first: results.first) }
        .environment(swipes)
        .onChange(of: query) { _, _ in position.scrollTo(edge: .bottom) }
        // ⌘P: the field takes the keyboard (its own `onFocus` takes the ask).
        .onChange(of: controller.agentsSearchPending, initial: true) { _, pending in
            if pending { fieldFocused = true }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(spacing: 8) {
                Text("No agents")
                    .font(.ui(17, .semibold))
                    .foregroundStyle(theme.foreground)
                Text("Agents you start show up here.")
                    .font(.ui(15))
                    .foregroundStyle(theme.muted)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ line: AgentsLine, next: String?) -> some View {
        switch line.kind {
        case .agent(let hit):
            if let t = hit.item.row.terminal {
                listRow(line, next: next, selected: isSelected(hit.item.row), to: .pane(hit.item.row.paneID),
                        leading: actions.leading(t), trailing: [actions.close(hit.item.row.paneID)],
                        menu: { actions.paneMenu(hit.item.row) }) {
                    PhoneAgentRowContent(terminal: t, tab: controller.workspace.tab(hit.item.row.tabID),
                                         space: hit.item.space, showsSpace: true, tree: hit.item.row.tree,
                                         hasKids: !hit.shown.isEmpty, titleMatch: hit.titleMatch)
                }
                .tutorialAnchor(.panelRow(t.address))
            }
        case .kid(let kid, let parent, let hasKids, let match):
            listRow(line, next: next, selected: !controller.singlePane && controller.isRinged(kid),
                    to: .kid(kid, from: parent.item.row.paneID), trailing: [actions.close(kid)],
                    menu: { actions.kidMenu(kid, rowPane: parent.item.row.paneID) }) {
                PhoneKidRowContent(kid: kid, hasKids: hasKids,
                                   terminals: TreeFolds.terminals(of: kid.terminal.address, in: parent.item.row.tree),
                                   titleMatch: match)
            }
            .tutorialAnchor(.panelRow(kid.terminal.address))
        case .record(let record, let parent, let match):
            // No terminal of its own: no swipes, no menu (as in the list).
            listRow(line, next: next, selected: false, to: .record(record, in: parent.item.row)) {
                PhoneRecordRowContent(kid: record, titleMatch: match)
            }
        }
    }

    /// The pane in front on the iPad, as the list lights it (the iPhone's shows none).
    private func isSelected(_ row: SidebarRow) -> Bool {
        !controller.singlePane && controller.ringedPane == row.paneID
    }

    /// The list's row (its press highlight, separators, swipes from its edges, menu).
    private func listRow<Content: View>(_ line: AgentsLine, next: String?, selected: Bool, to target: AgentsTarget,
                                        leading: [PhoneSwipeAction] = [], trailing: [PhoneSwipeAction] = [],
                                        menu: @escaping () -> PhoneMenu = { [] },
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        PhoneListRow(id: line.id, pinned: false, separator: line.separator, nextID: next, selected: selected,
                     leading: leading, trailing: trailing, edgeSwipesOnly: true, tap: { go(target) }, menu: menu) {
            content()
        }
    }

    /// The rows' swipes and menus, the list's.
    private var actions: RowActions { RowActions(controller: controller, theme: theme) }

    private func closeRows() {
        withAnimation(PhoneSwipeMotion.bodyAnimation) { swipes.closeAll() }
    }

    // MARK: Field

    /// The field in its glass capsule and, while it has the keyboard, a glass circle at
    /// its right that puts the keyboard away (as the message field's attach button, on
    /// the other side).
    private func bar(first: AgentsTarget?) -> some View {
        ComposerGlassGroup {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Icon("search", size: 18, color: theme.muted)
                    AgentsSearchField(text: $query, focused: $fieldFocused, prompt: "Search agents",
                                      onSubmit: { if let first { go(first) } },
                                      onFocus: { if controller.agentsSearchPending { controller.agentsSearchPending = false } },
                                      onEscape: { controller.closeAgents() })
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .frame(height: 44)
                .contentShape(Capsule())
                // A tap on the capsule's margins brings the keyboard too.
                .onTapGesture { fieldFocused = true }
                .composerGlass(Capsule(), theme: theme, interactive: false)
                if fieldFocused {
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
            .animation(.snappy(duration: 0.25), value: fieldFocused)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, barBottom)
    }

    // MARK: Going

    /// The row's agent in front; the panel stays (the keyboard goes).
    private func go(_ target: AgentsTarget) {
        swipes.closeAll()
        AgentsSearchUITextField.resignActive()
        fieldFocused = false
        switch target {
        case .pane(let pane):
            controller.focus(pane: pane)
        case .kid(let kid, let rowPane):
            controller.open(kid, from: rowPane)
        case .record(let record, let row):
            controller.open(record, in: row)
        }
    }
}

/// The panel as the sidebar hosts it (`SidebarNavController`): its list fading under the
/// status bar as the spaces' does. The safe area's bottom (the home indicator's) goes to
/// the field's bar (`AgentsPanel.barBottom`), not to the list as its safe area, which its
/// scroll view wouldn't count as its inset (its last rows would rest under the field):
/// the field where the sidebar's header row is (`SidebarHeader.bottomGap`).
struct AgentsPanelRoot: View {
    let context: PhoneHostContext
    /// The rows' menus (`SidebarNavController`'s press draws them).
    let menus: SpaceDrag

    var body: some View {
        AgentsPanel(barBottom: SidebarHeader.bottomGap(safeBottom: context.insets.bottom))
            .environment(menus)
            .environment(\.listMenus, true)
            .overlay(alignment: .top) {
                PhoneEdgeFade(edge: .top, height: PhoneEdgeFade.statusBar(context.insets.top))
                    .ignoresSafeArea(.container, edges: .top)
            }
            .background(context.theme.chrome.ignoresSafeArea())
            .tutorialAnchor(.agentsPanel)
    }
}

// MARK: - The field

/// The panel's search field: UIKit's, so that on the iPad it carries the empty 1-pt input
/// accessory `KeyboardCover` finds the keyboard's top by (the sidebar keeps over the
/// keyboard that way, as the message field does: SwiftUI's keyboard safe area is off
/// there); SwiftUI's has none. Its focus is `focused` both ways; asked to take the
/// keyboard where it can't (a hidden sidebar's), it lets `focused` go.
struct AgentsSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var prompt: String
    var onSubmit: () -> Void
    /// It took the keyboard.
    var onFocus: () -> Void
    var onEscape: () -> Void

    @Environment(\.theme) private var theme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AgentsSearchUITextField {
        let field = AgentsSearchUITextField()
        field.font = .systemFont(ofSize: 17)
        field.adjustsFontForContentSizeCategory = false
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        if !Device.isPhone { field.inputAccessoryView = ComposerTextView.EmptyAccessory() }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: AgentsSearchUITextField, context: Context) {
        context.coordinator.parent = self
        field.onEscape = onEscape
        if field.text != text { field.text = text }
        let ink = UIColor(theme.foreground)
        if field.textColor != ink { field.textColor = ink }
        let accent = UIColor(theme.accent)
        if field.tintColor != accent { field.tintColor = accent }
        let hint = UIColor(theme.foreground.opacity(theme.isDark ? 0.48 : 0.40))
        if field.attributedPlaceholder?.string != prompt || field.placeholderInk != hint {
            field.placeholderInk = hint
            field.attributedPlaceholder = NSAttributedString(string: prompt, attributes: [.foregroundColor: hint])
        }
        if focused, !field.isFirstResponder {
            // Once it's laid out in its window (a panel just mounted isn't yet).
            DispatchQueue.main.async { [weak field] in
                guard let field, !field.isFirstResponder else { return }
                if !(field.isOnScreen && field.becomeFirstResponder()) { context.coordinator.parent?.focused = false }
            }
        } else if !focused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AgentsSearchUITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(22, uiView.intrinsicContentSize.height))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AgentsSearchField?

        @objc func changed(_ field: UITextField) {
            parent?.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if parent?.focused == false { parent?.focused = true }
            parent?.onFocus()
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if parent?.focused == true { parent?.focused = false }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent?.onSubmit()
            return false
        }
    }
}

/// The search field's text field: Esc from a hardware keyboard closes the panel, and the
/// iPad's 1-pt accessory is found through it (`KeyboardCover`).
final class AgentsSearchUITextField: UITextField {
    var onEscape: (() -> Void)?
    /// The placeholder's color as last set.
    var placeholderInk: UIColor?

    /// The field that took the keyboard last.
    private static weak var focusedView: AgentsSearchUITextField?

    /// The accessory and window of the field that has the keyboard (iPad).
    static var activeAccessory: (bar: UIView, window: UIWindow)? {
        guard let view = focusedView, view.isFirstResponder, let window = view.window,
              let bar = view.inputAccessoryView, bar.window != nil else { return nil }
        return (bar, window)
    }

    /// The field with the keyboard gives it up (a row chosen, the panel swiped away).
    static func resignActive() {
        guard let view = focusedView, view.isFirstResponder else { return }
        view.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { Self.focusedView = self }
        return took
    }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }

    @objc private func escapePressed() {
        onEscape?()
    }

    /// In a window, shown up its chain and mostly within the window's bounds (not a hidden
    /// sidebar column's, nor a panel off to the side).
    var isOnScreen: Bool {
        guard let window else { return false }
        var view: UIView? = self
        while let v = view {
            if v.isHidden || v.alpha < 0.01 { return false }
            view = v.superview
        }
        let frame = convert(bounds, to: window)
        return window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

// MARK: - Results

/// Where a row of the panel leads.
enum AgentsTarget {
    /// An agent's pane.
    case pane(String)
    /// A sub-agent, as a tap on its row in the list opens it.
    case kid(SubAgent, from: String)
    /// A record: the terminal reporting it, as a tap on its row in the list opens it.
    case record(RecordKid, in: SidebarRow)
}

/// An agent that matched, itself or by one of its sub-agents (all of them, unsearched).
struct AgentsHit {
    var item: InboxItem
    var titleMatch: [Int]
    /// Its tree's matched letters (sub-agents' and records' titles), by `TreeNode.id`.
    var kidMatches: [String: [Int]]
    /// The best of its own score and its sub-agents'.
    var score: Int
    /// What of its tree shows over it: as in the list, and the rows that matched.
    var shown: [TreeNode]
    /// Where Return goes: the agent, or its sub-agent that matched best.
    var target: AgentsTarget
}

/// One line of the panel, with the separator under it (as `PhoneListLine`'s).
struct AgentsLine: Identifiable {
    enum Kind {
        case agent(AgentsHit)
        /// `hasKids`: rows of its own children show over it.
        case kid(SubAgent, parent: AgentsHit, hasKids: Bool, match: [Int])
        case record(RecordKid, parent: AgentsHit, match: [Int])
    }

    var kind: Kind
    var id: String
    var separator: PhoneRowSeparator = .none
}

/// What the panel shows for a query: the agents by status, or the best matches first.
@MainActor
struct AgentsResults {
    var agents: [AgentsHit] = []

    /// `tree`: what of a row's tree shows, its matches (node ids) whatever the folds (`shownTree`).
    init(_ ws: Workspace, query: String, tree: (SidebarRow, Set<String>) -> [TreeNode]) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let searching = !q.isEmpty
        var agents: [AgentsHit] = []
        for item in ws.agentsByStatus {
            guard let t = item.row.terminal else { continue }
            let own = Fuzzy.match(q, in: Format.agentTitle(t, tab: ws.tab(item.row.tabID)))
            var kidMatches: [String: [Int]] = [:]
            var bestKid: (target: AgentsTarget, score: Int)?
            if searching {
                for node in item.row.tree {
                    let title: String
                    let target: AgentsTarget
                    switch node {
                    case .kid(let kid):
                        guard kid.isAgent else { continue }
                        title = Format.kidTitle(kid.terminal)
                        target = .kid(kid, from: item.row.paneID)
                    case .record(let record):
                        title = record.record.title
                        target = .record(record, in: item.row)
                    }
                    guard let m = Fuzzy.match(q, in: title) else { continue }
                    kidMatches[node.id] = m.indices
                    if m.score > (bestKid?.score ?? .min) { bestKid = (target, m.score) }
                }
            }
            guard own != nil || bestKid != nil else { continue }
            let ownScore = own?.score ?? .min
            let target: AgentsTarget = if let bestKid, bestKid.score > ownScore {
                bestKid.target
            } else {
                .pane(item.row.paneID)
            }
            agents.append(AgentsHit(item: item, titleMatch: own?.indices ?? [], kidMatches: kidMatches,
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
    var first: AgentsTarget? { agents.first?.target }

    /// Top to bottom, as drawn: bottom up, for a thumb. The first agent lowest, each block
    /// upside down (its sub-agents over it, the tree's lines turned, `TreeLines.upward`).
    /// Separators: inset between blocks (none inside one), none under the bottom row.
    var lines: [AgentsLine] {
        var out: [AgentsLine] = []
        for (i, hit) in agents.enumerated().reversed() {
            for (k, node) in hit.shown.enumerated().reversed() {
                let match = hit.kidMatches[node.id] ?? []
                switch node {
                case .kid(let kid):
                    out.append(AgentsLine(kind: .kid(kid, parent: hit, hasKids: hit.shown.hasKids(at: k), match: match), id: node.id))
                case .record(let record):
                    out.append(AgentsLine(kind: .record(record, parent: hit, match: match), id: node.id))
                }
            }
            out.append(AgentsLine(kind: .agent(hit), id: hit.item.id,
                                  separator: i > 0 ? .inset(PhoneRowMetrics.inset) : .none))
        }
        return out
    }
}

// MARK: - Pieces

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
