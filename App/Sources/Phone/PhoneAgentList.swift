import SwiftUI
import WierdrModel

/// What a page of the iPhone's list shows.
enum PhoneListScope: Hashable {
    case all               // every agent
    case space(String)     // a space's agents, then its terminals (Space.id)

    var spaceID: String? {
        switch self {
        case .all: return nil
        case .space(let id): return id
        }
    }
}

/// One page of the iPhone's list: a vertical ScrollView (+ LazyVStack) of rows
/// in Telegram's chat-list style (`PhoneListRow`): full width, separators, no cards.
/// The order is Telegram's (`Workspace.phoneList`): pinned agents on top (the
/// newest pin first), then the rest by their latest status change; a space's page
/// then has its terminals and mod panes under a "TERMINALS" header. An agent's
/// sub-agents are rows under it, one block with it (its badges fold them).
///
/// Nothing is selected here (being on the list means no pane shows): a tap opens
/// the row's pane (`controller.focus(pane:)`), a sub-agent's row its sub-agent.
/// Pinning or unpinning moves rows with Telegram's list spring; status changes
/// reorder without animation.
struct PhoneAgentList: View {
    var scope: PhoneListScope
    /// Room the floating header takes over the top of the page (content starts under it, scrolls under it).
    var topInset: CGFloat
    /// The pager pages between several tabs: a row's swipe actions start only in the edge zones
    /// (x < e or x > width - e, e = clamp(width / 6, 22, 80)), the middle belongs to the pager. False: anywhere.
    var edgeSwipesOnly: Bool
    /// Changes when the current tab is tapped again: scroll to the top, animated.
    var scrollToTop: Int

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var swipes = PhoneRowSwipes()
    @State private var position = ScrollPosition(edge: .top)
    /// The page's height under its insets.
    @State private var viewport: CGFloat = 0

    var body: some View {
        let page = controller.workspace.phoneList(space: scope.spaceID)
        let lines = PhoneListLine.lines(page, showsKids: controller.showsKids(of:))
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    row(line, next: i + 1 < lines.count ? lines[i + 1].id : nil)
                        .background(alignment: .top) {
                            // Pulled down past the top, a pinned first row's gray goes on above it.
                            if i == 0 {
                                theme.hover.opacity(line.pinned ? 1 : 0)
                                    .frame(height: 1200)
                                    .offset(y: -1200)
                                    .animation(PhoneListMotion.restyle, value: line.pinned)
                            }
                        }
                        // A row being pinned slides up over the rows it passes.
                        .zIndex(line.pinned ? 1 : 0)
                }
            }
            .animation(PhoneListMotion.move, value: pinKey(page))
            // The page's whole height: a tap under the rows closes an open row too (the rows' own taps go first).
            .frame(minHeight: viewport, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(PhoneSwipeMotion.bodyAnimation) { swipes.closeAll() } }
            .overlay {
                if page.isEmpty { empty }
            }
        }
        .scrollPosition($position)
        .contentMargins(.top, topInset, for: .scrollContent)
        .contentMargins(.top, topInset, for: .scrollIndicators)
        .onScrollGeometryChange(for: CGFloat.self) { g in
            g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom
        } action: { _, h in
            viewport = max(0, h)
        }
        .background(theme.chrome)
        .environment(swipes)
        .onScrollPhaseChange { _, phase in
            // Scrolling closes an open row (Telegram: as the list's drag begins).
            if phase == .interacting, swipes.openID != nil { swipes.closeAll() }
        }
        .onChange(of: scrollToTop) { _, _ in
            withAnimation(.smooth(duration: 0.4)) { position.scrollTo(edge: .top) }
        }
        .onDisappear { swipes.closeAll() }
    }

    /// Changes when pins come, go or reorder (they move with the list's spring).
    private func pinKey(_ page: PhoneListPage) -> [String] {
        page.agents.filter { $0.row.terminal?.pinned == true }.map(\.id)
    }

    @ViewBuilder
    private func row(_ line: PhoneListLine, next: String?) -> some View {
        switch line.kind {
        case .agent(let item):
            agentRow(item, line: line, next: next)
        case .kid(let kid, let parent, let first):
            PhoneListRow(id: line.id, pinned: line.pinned, separator: line.separator, nextID: next,
                         edgeSwipesOnly: edgeSwipesOnly, tap: { controller.open(kid, from: parent.row.paneID) }) {
                kidMenu(kid, parent: parent)
            } content: {
                PhoneKidRowContent(kid: kid, first: first)
            }
        case .header(let title):
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, PhoneRowMetrics.inset)
                .padding(.top, 24)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .pane(let item):
            PhoneListRow(id: line.id, pinned: false, separator: line.separator, nextID: next,
                         trailing: [closeAction(item.row.paneID)],
                         edgeSwipesOnly: edgeSwipesOnly, tap: { controller.focus(pane: item.row.paneID) }) {
                paneMenu(item.row)
            } content: {
                PhonePaneRowContent(row: item.row)
            }
        }
    }

    @ViewBuilder
    private func agentRow(_ item: PhoneListLine.Item, line: PhoneListLine, next: String?) -> some View {
        if let t = item.row.terminal {
            PhoneListRow(id: line.id, pinned: line.pinned, separator: line.separator, nextID: next,
                         leading: leadingActions(t), trailing: [closeAction(item.row.paneID)],
                         edgeSwipesOnly: edgeSwipesOnly, tap: { controller.focus(pane: item.row.paneID) }) {
                paneMenu(item.row)
            } content: {
                PhoneAgentRowContent(terminal: t, tab: controller.workspace.tab(item.row.tabID), space: item.space,
                                     showsSpace: scope == .all, subtree: item.row.subtree,
                                     open: controller.showsKids(of: item.row))
            }
        }
    }

    // MARK: Actions

    /// Swipe right: Unread (idle) or Idle (done) at the edge, then Pin/Unpin.
    private func leadingActions(_ t: TerminalInfo) -> [PhoneSwipeAction] {
        var out: [PhoneSwipeAction] = []
        switch t.status {
        case .idle:
            out.append(PhoneSwipeAction(id: "unread", title: "Unread", symbol: "message.badge.filled.fill",
                                        color: PhoneSwipeColors.unread(theme)) {
                controller.markUnread(t.address)
            })
        case .done:
            out.append(PhoneSwipeAction(id: "idle", title: "Idle", symbol: "checkmark.message.fill",
                                        color: PhoneSwipeColors.inactive(theme)) {
                controller.markRead(t.address)
            })
        default:
            break
        }
        out.append(PhoneSwipeAction(id: t.pinned ? "unpin" : "pin", title: t.pinned ? "Unpin" : "Pin",
                                    symbol: t.pinned ? "pin.slash.fill" : "pin.fill",
                                    color: PhoneSwipeColors.pin(theme)) {
            controller.setPinned(t.address, !t.pinned)
        })
        return out
    }

    /// Swipe left: Close (an agent's asks first).
    private func closeAction(_ paneID: String) -> PhoneSwipeAction {
        PhoneSwipeAction(id: "close", title: "Close", symbol: "xmark", color: PhoneSwipeColors.destructive(theme)) {
            controller.closePane(paneID)
        }
    }

    // MARK: Menus

    /// An agent's or a terminal's long-press menu (`SidebarRowView`'s).
    @ViewBuilder
    private func paneMenu(_ row: SidebarRow) -> some View {
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

    /// A sub-agent's: show it or keep it as a tab; a kept one, go to its tab.
    @ViewBuilder
    private func kidMenu(_ kid: SubAgent, parent: PhoneListLine.Item) -> some View {
        if let pane = kid.paneID {
            Button { controller.focus(pane: pane) } label: { Label("Go to Its Tab", image: "ui.terminal") }
        } else {
            Button { controller.open(kid, from: parent.row.paneID) } label: { Label("Show", image: "ui.terminal") }
            Button { controller.keep(kid.terminal.address) } label: { Label("Keep as Tab", image: "ui.plus") }
        }
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 8) {
            Text(scope == .all ? "No agents running" : "No agents or terminals in this space")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .multilineTextAlignment(.center)
            if scope == .all {
                Text("Start one with + below.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.muted)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The swipe buttons' fills: Telegram's (day/night) for unread, pin, inactive and destructive.
enum PhoneSwipeColors {
    static func unread(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#666666" : "#0088ff") }
    static func pin(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#08a723" : "#00c900") }
    static func inactive(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#666666" : "#bcbcc3") }
    static func destructive(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#c70c0c" : "#ff3824") }
}

/// A line of the list, with the chrome its place gives it: pinned (its agent's
/// block is), and the separator under it (none inside an agent's block; full
/// width under the pinned block, before the terminals' header and at the end).
struct PhoneListLine: Identifiable {
    typealias Item = InboxItem

    enum Kind {
        case agent(Item)
        case kid(SubAgent, parent: Item, first: Bool)
        case header(String)
        case pane(Item)
    }

    var kind: Kind
    var id: String
    var pinned = false
    var separator: PhoneRowSeparator = .none

    static func lines(_ page: PhoneListPage, showsKids: (SidebarRow) -> Bool) -> [PhoneListLine] {
        var out: [PhoneListLine] = []
        for (i, item) in page.agents.enumerated() {
            let pinned = item.row.terminal?.pinned == true
            var block = [PhoneListLine(kind: .agent(item), id: item.id, pinned: pinned)]
            if showsKids(item.row) {
                block += item.row.subtree.enumerated().map { k, kid in
                    PhoneListLine(kind: .kid(kid, parent: item, first: k == 0), id: "kid:\(kid.terminal.address)", pinned: pinned)
                }
            }
            let next = i + 1 < page.agents.count ? page.agents[i + 1] : nil
            let lastPinned = pinned && next?.row.terminal?.pinned != true
            let endOfAgents = next == nil
            block[block.count - 1].separator = lastPinned || endOfAgents ? .full : .inset(PhoneRowMetrics.inset)
            out += block
        }
        if !page.others.isEmpty {
            out.append(PhoneListLine(kind: .header("TERMINALS"), id: "header:terminals"))
            for (i, item) in page.others.enumerated() {
                let last = i == page.others.count - 1
                out.append(PhoneListLine(kind: .pane(item), id: item.id,
                                         separator: last ? .full : .inset(PhoneRowMetrics.paneTextLeading)))
            }
        }
        return out
    }
}
