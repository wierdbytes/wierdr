import Foundation

/// One page of the iPhone's list (its "All" tab or a space's tab), as Telegram
/// orders a chat list: pinned agents on top, the newest pin first (a pin keeps
/// its place), then every other agent by its latest status change, newest first;
/// no status groups. A space's page then has its terminals and mod panes.
public struct PhoneListPage: Hashable, Sendable {
    /// Agent rows (an agent's sub-agents ride along in `row.subtree`).
    public var agents: [InboxItem]
    /// A space's plain terminals and mod panes, in its sidebar order (none on "All").
    public var others: [InboxItem]

    public init(agents: [InboxItem], others: [InboxItem]) {
        self.agents = agents; self.others = others
    }

    public var isEmpty: Bool { agents.isEmpty && others.isEmpty }
}

extension Workspace {
    /// Every agent of every space (`nil`), or one space's agents then its other panes.
    public func phoneList(space spaceID: String?) -> PhoneListPage {
        let spaces = spaceID.map { id in self.spaces.filter { $0.id == id } } ?? self.spaces
        var agents: [InboxItem] = []
        var others: [InboxItem] = []
        for space in spaces {
            for row in sidebarRows(for: space) {
                if row.kind == .agent {
                    agents.append(InboxItem(row: row, space: space))
                } else if spaceID != nil {
                    others.append(InboxItem(row: row, space: space))
                }
            }
        }
        return PhoneListPage(agents: agents.sorted { PhoneListOrder.before($0.row, $1.row) }, others: others)
    }
}

enum PhoneListOrder {
    /// The latest status change of an agent and its sub-agents.
    static func lastChange(_ row: SidebarRow) -> Date? {
        ([row.terminal] + row.subtree.filter(\.isAgent).map(\.terminal))
            .compactMap { $0?.statusChangedAt }.max()
    }

    /// Pinned first: by pin time (newest first), pins without a time after them
    /// by address; then the rest by `lastChange` (newest first), then address.
    static func before(_ a: SidebarRow, _ b: SidebarRow) -> Bool {
        let ta = a.terminal, tb = b.terminal
        let pa = ta?.pinned == true, pb = tb?.pinned == true
        if pa != pb { return pa }
        if pa {
            switch (ta?.pinnedAt, tb?.pinnedAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
        } else {
            let da = lastChange(a) ?? .distantPast, db = lastChange(b) ?? .distantPast
            if da != db { return da > db }
        }
        let aa = ta?.address ?? a.paneID, ab = tb?.address ?? b.paneID
        if aa != ab { return aa < ab }
        return a.paneID < b.paneID
    }
}
