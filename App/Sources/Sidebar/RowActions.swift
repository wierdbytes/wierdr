import SwiftUI
import WierdrModel

/// What a row of an agent, a sub-agent or a pane offers, wherever it's drawn (the spaces
/// list's cards, `SpaceCardLine`, and the agents panel, `AgentsPanel`): its swipes and its
/// long-press menu.
@MainActor
struct RowActions {
    let controller: WorkspaceController
    let theme: Theme

    // MARK: Swipes

    /// Swipe right: Unread (idle) or Idle (done) at the edge, then Pin/Unpin.
    func leading(_ t: TerminalInfo) -> [PhoneSwipeAction] {
        var out: [PhoneSwipeAction] = []
        switch t.status {
        case .idle where t.canMarkUnread:
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
    func close(_ paneID: String) -> PhoneSwipeAction {
        PhoneSwipeAction(id: "close", title: "Close", symbol: "xmark", color: PhoneSwipeColors.destructive(theme), fillsRow: true) {
            controller.closePane(paneID)
        }
    }

    /// A sub-agent's swipe left: Close (kept, its pane; else it stops; asks first).
    func close(_ kid: SubAgent) -> PhoneSwipeAction {
        PhoneSwipeAction(id: "close", title: "Close", symbol: "xmark", color: PhoneSwipeColors.destructive(theme), fillsRow: true) {
            controller.close(kid)
        }
    }

    // MARK: Menus

    /// An agent's or a terminal's long-press menu.
    func paneMenu(_ row: SidebarRow) -> PhoneMenu {
        var agent: [PhoneMenuItem] = []
        if let t = row.terminal, t.isAgent {
            agent.append(PhoneMenuItem(title: t.pinned ? "Unpin" : "Pin", icon: .asset(t.pinned ? "ui.pin-off" : "ui.pin")) {
                controller.setPinned(t.address, !t.pinned)
            })
            switch t.status {
            case .idle where t.canMarkUnread:
                agent.append(PhoneMenuItem(title: "Mark Unread", icon: .system("circle.fill")) { controller.markUnread(t.address) })
            case .done:
                agent.append(PhoneMenuItem(title: "Mark Idle", icon: .system("circle")) { controller.markRead(t.address) })
            default:
                break
            }
        }
        let pane = [
            PhoneMenuItem(title: "Split Right", icon: .asset("ui.split-right")) {
                controller.focus(pane: row.paneID)
                controller.split(.right, pane: row.paneID)
            },
            PhoneMenuItem(title: "Close Pane", icon: .asset("ui.x"), destructive: true) { controller.closePane(row.paneID) },
        ]
        return [agent, pane]
    }

    /// A sub-agent's (under the row of `rowPane`): show it or keep it as a tab; a kept one,
    /// go to its tab; Close.
    func kidMenu(_ kid: SubAgent, rowPane: String) -> PhoneMenu {
        let open: [PhoneMenuItem]
        if let pane = kid.paneID {
            open = [PhoneMenuItem(title: "Go to Its Tab", icon: .asset("ui.terminal")) { controller.focus(pane: pane) }]
        } else {
            open = [
                PhoneMenuItem(title: "Show", icon: .asset("ui.terminal")) { controller.open(kid, from: rowPane) },
                PhoneMenuItem(title: "Keep as Tab", icon: .asset("ui.plus")) { controller.keep(kid.terminal.address) },
            ]
        }
        return [open, [PhoneMenuItem(title: "Close", icon: .asset("ui.x"), destructive: true) { controller.close(kid) }]]
    }
}
