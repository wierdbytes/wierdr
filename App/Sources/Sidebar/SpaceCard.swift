import SwiftUI
import WierdrModel

/// A space's card in the sidebar, drawn bottom up as the whole list is: at its bottom its
/// header (`SpaceHeader`: avatar, name, git, the agents' summary while it's folded, the
/// chevron), nearest the thumb; over it, unless folded, its rows in the iPhone's chat-row
/// style (`PhoneListRow`), in `PhoneListLine.lines` on the space's `Workspace.phoneList`:
/// its pinned agents lowest, right over the header (the newest pin at the bottom), over
/// them the rest by their latest status change, the oldest on top; an agent's sub-agents
/// over it (`TreeLines.upward`); the space's terminals and desktop panels over its agents.
///
/// One view in the list (its lazy stack's item), so a fold or a pin animates inside it
/// and a drag lifts it whole (`SpaceDrag`): dragged, it is its own slot, a dashed outline
/// as tall as itself.
struct SpaceCard: View {
    var space: Space

    @Environment(WorkspaceController.self) private var controller
    @Environment(SpaceDrag.self) private var drag: SpaceDrag?
    @Environment(\.theme) private var theme

    static let radius: CGFloat = 12

    var body: some View {
        let page = controller.workspace.phoneList(space: space.id)
        let closed = controller.closedSpaces.contains(space.id)
        let bodyShown = !closed && !page.isEmpty
        let slot = drag?.dragged == space.id
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        SpaceCardContent(space: space, page: page, closed: closed, bodyShown: bodyShown)
            .environment(\.rowGround, theme.surface)
            .background(theme.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.border, lineWidth: 1).allowsHitTesting(false))
            .opacity(slot ? 0 : 1)
            .background {
                if slot {
                    shape.fill(theme.accent.opacity(0.05))
                        .overlay(shape.strokeBorder(theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
            .background {
                if let drag { SpaceMarker(space: space.id, role: .card, markers: drag.markers) }
            }
    }
}

/// What a card shows, without its surface: its header and rows. Also the lifted card's
/// picture (`SpaceDragPreview`).
struct SpaceCardContent: View {
    var space: Space
    var page: PhoneListPage
    var closed: Bool
    var bodyShown: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            if bodyShown {
                let lines = PhoneListLine.lines(page, showsKids: controller.showsKids(of:), terminalsHeader: false)
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    SpaceCardLine(line: line, next: i + 1 < lines.count ? lines[i + 1].id : nil)
                        // A row being pinned slides down over the rows it passes.
                        .zIndex(line.pinned ? 1 : 0)
                        .transition(.opacity)
                }
            }
            SpaceHeader(space: space, hasRows: !page.isEmpty, closed: closed, bodyShown: bodyShown)
        }
        .animation(PhoneListMotion.move, value: pinKey)
    }

    /// Changes when pins come, go or reorder (they move with the list's spring).
    private var pinKey: [String] {
        page.agents.filter { $0.row.terminal?.pinned == true }.map(\.id)
    }
}

/// One line of a card: an agent, a sub-agent over it, or a terminal (`PhoneListLine`),
/// in Telegram's row (`PhoneListRow`: swipes, press, menu). On the iPad the row of the
/// pane in front (or the sub-agent shown) is selected.
struct SpaceCardLine: View {
    var line: PhoneListLine
    var next: String?

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        switch line.kind {
        case .agent(let item):
            agentRow(item)
        case .kid(let kid, let parent, let adjacent):
            PhoneListRow(id: line.id, pinned: line.pinned, separator: line.separator, nextID: next,
                         selected: !controller.singlePane && controller.isRinged(kid),
                         trailing: [kidCloseAction(kid)],
                         edgeSwipesOnly: false, tap: { controller.open(kid, from: parent.row.paneID) }) {
                kidMenu(kid, parent: parent)
            } content: {
                PhoneKidRowContent(kid: kid, adjacent: adjacent)
            }
        case .header(let title):
            Text(title)
                .font(.ui(12))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, PhoneRowMetrics.inset)
                .padding(.top, 14)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .pane(let item):
            PhoneListRow(id: line.id, pinned: false, separator: line.separator, nextID: next,
                         selected: isSelected(item.row),
                         trailing: [closeAction(item.row.paneID)],
                         edgeSwipesOnly: false, tap: { controller.focus(pane: item.row.paneID) }) {
                paneMenu(item.row)
            } content: {
                PhonePaneRowContent(row: item.row)
            }
        }
    }

    /// The pane in front on the iPad (the iPhone's list has nothing selected: being on
    /// it means no pane shows).
    private func isSelected(_ row: SidebarRow) -> Bool {
        !controller.singlePane && controller.ringedPane == row.paneID
    }

    @ViewBuilder
    private func agentRow(_ item: PhoneListLine.Item) -> some View {
        if let t = item.row.terminal {
            PhoneListRow(id: line.id, pinned: line.pinned, separator: line.separator, nextID: next,
                         selected: isSelected(item.row),
                         leading: leadingActions(t), trailing: [closeAction(item.row.paneID)],
                         edgeSwipesOnly: false, tap: { controller.focus(pane: item.row.paneID) }) {
                paneMenu(item.row)
            } content: {
                PhoneAgentRowContent(terminal: t, tab: controller.workspace.tab(item.row.tabID), space: item.space,
                                     showsSpace: false, subtree: item.row.subtree,
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

    /// Swipe left: Close (asks first).
    private func closeAction(_ paneID: String) -> PhoneSwipeAction {
        PhoneSwipeAction(id: "close", title: "Close", symbol: "xmark", color: PhoneSwipeColors.destructive(theme), fillsRow: true) {
            controller.closePane(paneID)
        }
    }

    /// A sub-agent's swipe left: Close (kept, its pane; else it stops; asks first).
    private func kidCloseAction(_ kid: SubAgent) -> PhoneSwipeAction {
        PhoneSwipeAction(id: "close", title: "Close", symbol: "xmark", color: PhoneSwipeColors.destructive(theme), fillsRow: true) {
            controller.close(kid)
        }
    }

    // MARK: Menus

    /// An agent's or a terminal's long-press menu.
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

    /// A sub-agent's: show it or keep it as a tab; a kept one, go to its tab; Close.
    @ViewBuilder
    private func kidMenu(_ kid: SubAgent, parent: PhoneListLine.Item) -> some View {
        if let pane = kid.paneID {
            Button { controller.focus(pane: pane) } label: { Label("Go to Its Tab", image: "ui.terminal") }
        } else {
            Button { controller.open(kid, from: parent.row.paneID) } label: { Label("Show", image: "ui.terminal") }
            Button { controller.keep(kid.terminal.address) } label: { Label("Keep as Tab", image: "ui.plus") }
        }
        Divider()
        Button(role: .destructive) { controller.close(kid) } label: { Label("Close", image: "ui.x") }
    }
}

/// The swipe buttons' fills: Telegram's (day/night) for unread, pin, inactive and destructive.
enum PhoneSwipeColors {
    static func unread(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#666666" : "#0088ff") }
    static func pin(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#08a723" : "#00c900") }
    static func inactive(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#666666" : "#bcbcc3") }
    static func destructive(_ theme: Theme) -> Color { Color(hex: theme.isDark ? "#c70c0c" : "#ff3824") }
}

/// A line of a card, with the chrome its place gives it: pinned (its agent's block
/// is), and the separator under it.
///
/// Drawn bottom up, for a thumb: `Workspace.phoneList`'s order from the bottom (the
/// newest pin at the very bottom, then the other pins, then the rest by their latest
/// status change, the oldest on top), an agent's block upside down (its sub-agents over
/// it, the tree's lines turned, `TreeLines.upward`). A space's terminals and mod panes
/// are over its agents (under their "TERMINALS" header when there is one: a header
/// stays over what it names), the oldest on top too. Separators: none inside an agent's
/// block, inset between blocks, full width over the pinned block and under the
/// terminals; none under the bottom row.
struct PhoneListLine: Identifiable {
    typealias Item = InboxItem

    enum Kind {
        case agent(Item)
        /// `adjacent`: right over its agent.
        case kid(SubAgent, parent: Item, adjacent: Bool)
        case header(String)
        case pane(Item)
    }

    var kind: Kind
    var id: String
    var pinned = false
    var separator: PhoneRowSeparator = .none

    /// Top to bottom, as drawn.
    static func lines(_ page: PhoneListPage, showsKids: (SidebarRow) -> Bool, terminalsHeader: Bool = true) -> [PhoneListLine] {
        var out: [PhoneListLine] = []
        if !page.others.isEmpty {
            if terminalsHeader {
                out.append(PhoneListLine(kind: .header("TERMINALS"), id: "header:terminals"))
            }
            for (i, item) in page.others.enumerated().reversed() {
                // The bottom one: full width over the agents.
                let separator: PhoneRowSeparator = i > 0 ? .inset(PhoneRowMetrics.paneTextLeading)
                    : (page.agents.isEmpty ? .none : .full)
                out.append(PhoneListLine(kind: .pane(item), id: item.id, separator: separator))
            }
        }
        for (i, item) in page.agents.enumerated().reversed() {
            let pinned = item.row.terminal?.pinned == true
            var block: [PhoneListLine] = []
            if showsKids(item.row) {
                let kids = item.row.subtree
                block += kids.enumerated().reversed().map { k, kid in
                    PhoneListLine(kind: .kid(kid, parent: item, adjacent: k == 0),
                                  id: "kid:\(kid.terminal.address)", pinned: pinned)
                }
            }
            // Under the block: the one drawn under it (the one before it in the list's order).
            let below = i > 0 ? page.agents[i - 1] : nil
            let separator: PhoneRowSeparator
            if below == nil {
                separator = .none
            } else if !pinned, below?.row.terminal?.pinned == true {
                separator = .full
            } else {
                separator = .inset(PhoneRowMetrics.inset)
            }
            block.append(PhoneListLine(kind: .agent(item), id: item.id, pinned: pinned, separator: separator))
            out += block
        }
        return out
    }
}
