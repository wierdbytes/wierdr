import Foundation
import Observation

/// The live Herdr world of one connection: machines, spaces (with tabs and
/// pane trees), terminals and agents, plus the commands that change it.
///
/// The UI reads the published properties and calls the commands; everything
/// else (subscribing to core events, reading/writing the `herdr-app`
/// documents with compare-and-swap, status rules, naming) happens inside.
///
/// Per-screen state (selected space/tab, focused/zoomed pane) is NOT here:
/// see `ScreenState`.
@MainActor
@Observable
public final class Workspace {
    /// Connection state, for banners ("Reconnecting…").
    public enum Phase: Equatable, Sendable {
        case connecting
        case live
        case reconnecting(String)
        case failed(String)
    }

    public var phase: Phase = .connecting
    /// Connected computer first, then added machines by name.
    public internal(set) var machines: [Machine] = []
    /// All spaces in Herdr's order (connected computer first, then machines by name; doc order inside).
    public internal(set) var spaces: [Space] = [] { didSet { index = nil } }
    /// Every live terminal by qualified address (plus ended ones still shown in a pane).
    public internal(set) var terminals: [String: TerminalInfo] = [:] { didSet { index = nil } }
    /// Agents people can start, per machine id (`""` = connected computer).
    public internal(set) var launchers: [String: [AgentLauncher]] = [:]
    /// Home folder of the connected computer (for `~` shortening), when known.
    public internal(set) var home: String?
    /// Subscription limits pi reported on every connected machine, merged by account
    /// (`Limits.merge`: Claude first, then Codex, then others).
    public internal(set) var limits: [LimitAccount] = []

    public init() {}

    // MARK: Lookup

    public func space(_ id: String?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    public func tab(_ id: String?) -> Tab? {
        guard let id else { return nil }
        for space in spaces { if let t = space.tabs.first(where: { $0.id == id }) { return t } }
        return nil
    }

    public func terminal(_ address: String?) -> TerminalInfo? {
        guard let address else { return nil }
        return terminals[address]
    }

    /// The space and tab holding a pane.
    public func location(ofPane paneID: String) -> (space: Space, tab: Tab)? {
        for space in spaces {
            for tab in space.tabs where tab.panes.contains(where: { $0.id == paneID }) {
                return (space, tab)
            }
        }
        return nil
    }

    /// The pane showing a terminal, if any.
    public func pane(showing address: String) -> (space: Space, tab: Tab, pane: Pane)? {
        for space in spaces {
            for tab in space.tabs {
                if let pane = tab.panes.first(where: { $0.terminal == address }) { return (space, tab, pane) }
            }
        }
        return nil
    }

    /// Spaces of one machine (`nil` = connected computer), in order.
    public func spaces(on machine: String?) -> [Space] {
        spaces.filter { $0.machine == machine }
    }

    /// Rows under a space card, in Herdr's sidebar order.
    public func sidebarRows(for space: Space) -> [SidebarRow] {
        SidebarOrder.rows(for: space, index: subAgents)
    }

    // MARK: Sub-agents

    /// Who started whom, for this snapshot (rebuilt after spaces or terminals change).
    @ObservationIgnored private var index: SubAgentIndex?

    var subAgents: SubAgentIndex {
        // Read both every time: a view that only asks the (unobserved) cache still
        // follows changes to them. Copies are free (copy on write).
        let spaces = self.spaces, terminals = self.terminals
        if let index { return index }
        let built = SubAgentIndex(spaces: spaces, terminals: terminals)
        index = built
        return built
    }

    /// The live terminals `address` started, and theirs, depth first (kept ones too).
    public func subtree(of address: String) -> [SubAgent] {
        subAgents.subtree(of: address)
    }

    /// Whether a terminal shows under an agent in the sidebar rather than as a row of its own.
    public func isNested(_ address: String) -> Bool {
        subAgents.isNested(address)
    }

    /// A space's agents by status as its card counts them: its agents, and the
    /// sub-agents under them (never done).
    public func agentCounts(in spaceID: String) -> [AgentStatus: Int] {
        subAgents.countsBySpace[spaceID] ?? [:]
    }

    /// The same for all of a machine's spaces (a folded machine's header).
    public func agentCounts(on machine: String?) -> [AgentStatus: Int] {
        let all = subAgents.countsBySpace
        var out: [AgentStatus: Int] = [:]
        for space in spaces(on: machine) {
            for (s, n) in all[space.id] ?? [:] { out[s, default: 0] += n }
        }
        return out
    }

    /// Where a sub-agent goes when kept: a tab of its nearest ancestor's space
    /// (the nearest with a pane), right after that ancestor's tab and the tabs
    /// of its other kept children already there. Nil when no ancestor has a pane.
    public func keepTarget(for address: String) -> (spaceID: String, after: String, parent: String)? {
        let index = subAgents
        guard let home = index.home(of: address), let space = space(home.place.space),
              let at = space.tabs.firstIndex(where: { $0.id == home.place.tab }) else { return nil }
        let kin = Set(index.subtree(of: home.address).map(\.terminal.address)).subtracting([address])
        var after = at
        while after + 1 < space.tabs.count {
            let panes = space.tabs[after + 1].panes
            guard !panes.isEmpty, panes.allSatisfy({ $0.terminal.map(kin.contains) ?? false }) else { break }
            after += 1
        }
        return (space.id, space.tabs[after].id, home.address)
    }

    /// Agent counts by status over all agents shown in panes.
    public var statusCounts: [AgentStatus: Int] {
        var counts: [AgentStatus: Int] = [:]
        for space in spaces {
            for tab in space.tabs {
                for pane in tab.panes {
                    if let t = terminal(pane.terminal), let s = t.status { counts[s, default: 0] += 1 }
                }
            }
        }
        return counts
    }

    // MARK: Commands (implemented by the live backend; preview/no-op otherwise)

    /// Backend that performs commands against herdr-core. `nil` in previews.
    weak var backend: WorkspaceBackend?

    /// New space on a machine (`nil` = connected computer) with one tab running `launch`,
    /// before its machine's other spaces (so first in every client's list, desktop's too).
    /// Returns the new space id.
    @discardableResult
    public func newSpace(machine: String?, name: String = "", folder: String? = nil, launch: Launch = .shell) async throws -> String {
        guard let backend else { throw WorkspaceError.notConnected }
        return try await backend.newSpace(machine: machine, name: name, folder: folder, launch: launch, first: true)
    }

    /// New tab in a space, inserted after `afterTab` (else at the end). Returns the new tab id.
    @discardableResult
    public func newTab(in spaceID: String, after afterTab: String? = nil, name: String = "", launch: Launch = .shell) async throws -> String {
        guard let backend else { throw WorkspaceError.notConnected }
        return try await backend.newTab(in: spaceID, after: afterTab, name: name, launch: launch)
    }

    /// Split a pane; returns the new pane id.
    @discardableResult
    public func split(pane paneID: String, direction: SplitDirection, launch: Launch = .shell) async throws -> String {
        guard let backend else { throw WorkspaceError.notConnected }
        return try await backend.split(pane: paneID, direction: direction, launch: launch)
    }

    /// Close a pane (its tab if it is the last pane, its space if the last tab) and end its terminal.
    public func closePane(_ paneID: String) async throws {
        guard let backend else { throw WorkspaceError.notConnected }
        try await backend.closePane(paneID)
    }

    /// Close a tab (its space if it is the last tab) and end its terminals.
    public func closeTab(_ tabID: String) async throws {
        guard let backend else { throw WorkspaceError.notConnected }
        try await backend.closeTab(tabID)
    }

    /// Close a space and end its terminals.
    public func closeSpace(_ spaceID: String) async throws {
        guard let backend else { throw WorkspaceError.notConnected }
        try await backend.closeSpace(spaceID)
    }

    /// Rename (`""` = back to the automatic name).
    public func renameSpace(_ spaceID: String, to name: String) async throws {
        guard let backend else { throw WorkspaceError.notConnected }
        try await backend.renameSpace(spaceID, to: name)
    }

    public func renameTab(_ tabID: String, to name: String) async throws {
        guard let backend else { throw WorkspaceError.notConnected }
        try await backend.renameTab(tabID, to: name)
    }

    /// Move a space among its machine's spaces: just before `before`, or after
    /// the last of them when `before` is nil (`space.move`). In the demo, here only.
    public func moveSpace(_ spaceID: String, before: String?) async throws {
        if isLocal { return try moveHere(spaceID, before: before) }
        guard let backend else { throw WorkspaceError.notConnected }
        try await backend.moveSpace(spaceID, before: before)
    }

    /// Move a tab within its space.
    public func moveTab(_ tabID: String, to index: Int) async throws {
        guard let backend else { throw WorkspaceError.notConnected }
        try await backend.moveTab(tabID, to: index)
    }

    /// Keep a running terminal without a pane (a sub-agent): a new tab of a
    /// space (of its machine), after `afterTab` (else at the end), showing it;
    /// it lives on like any pane's terminal (`terminal.keep`). Returns the new tab id.
    @discardableResult
    public func keepAsTab(_ address: String, in spaceID: String, after afterTab: String? = nil) async throws -> String {
        guard let backend else { throw WorkspaceError.notConnected }
        return try await backend.keepAsTab(address, in: spaceID, after: afterTab)
    }

    /// The person is looking at these agents now, and only these (pass all of
    /// them each time; `[]` when nothing is on screen or the app is in the
    /// background): raise their shared `herdr.seen` to their current turn
    /// (clears "done" on every Herdr client).
    public func markSeen(_ addresses: [String]) {
        backend?.markSeen(addresses)
    }

    /// "Mark unread": `herdr.seen = turn - 1`.
    public func markUnread(_ address: String) {
        if isLocal { return changeHere(address) { if $0.status == .idle { $0.status = .done } } }
        backend?.markUnread(address)
    }

    /// "Mark idle" (done → idle without looking): `herdr.seen = turn`.
    public func markRead(_ address: String) {
        if isLocal { return changeHere(address) { if $0.status == .done { $0.status = .idle } } }
        backend?.markRead(address)
    }

    /// Pin/unpin an agent to the top of the lists (`herdr.pinned`, the time it was pinned).
    public func setPinned(_ address: String, _ pinned: Bool) {
        if isLocal {
            return changeHere(address) { $0.pinned = pinned; $0.pinnedAt = pinned ? Date() : nil }
        }
        backend?.setPinned(address, pinned)
    }

    /// No herdr-core behind it (the demo): pin, unread, idle and moving a space change it here only.
    var isLocal = false

    /// The demo's `space.move`: reorders `spaces`, the space among its machine's.
    private func moveHere(_ spaceID: String, before: String?) throws {
        guard let from = spaces.firstIndex(where: { $0.id == spaceID }) else { throw WorkspaceError.notFound("Space") }
        let space = spaces[from]
        if let before {
            guard let other = self.space(before) else { throw WorkspaceError.notFound("Space") }
            guard other.machine == space.machine else {
                throw WorkspaceError.core("A space moves only among its machine's spaces")
            }
        }
        guard before != spaceID else { return }
        var list = spaces
        list.remove(at: from)
        let to = before.flatMap { b in list.firstIndex { $0.id == b } }
            ?? list.lastIndex { $0.machine == space.machine }.map { $0 + 1 }
            ?? from
        list.insert(space, at: to)
        if list != spaces { spaces = list }
    }

    private func changeHere(_ address: String, _ change: (inout TerminalInfo) -> Void) {
        guard var t = terminals[address] else { return }
        change(&t)
        terminals[address] = t
    }

    /// Refresh the installed-agent list of a machine for the "+" menu.
    public func refreshLaunchers(machine: String?) {
        backend?.refreshLaunchers(machine: machine)
    }
}

/// What `Workspace` commands delegate to. The live implementation talks to
/// herdr-core; previews have none.
@MainActor
protocol WorkspaceBackend: AnyObject {
    func newSpace(machine: String?, name: String, folder: String?, launch: Launch, first: Bool) async throws -> String
    func newTab(in spaceID: String, after: String?, name: String, launch: Launch) async throws -> String
    func split(pane: String, direction: SplitDirection, launch: Launch) async throws -> String
    func closePane(_ paneID: String) async throws
    func closeTab(_ tabID: String) async throws
    func closeSpace(_ spaceID: String) async throws
    func renameSpace(_ spaceID: String, to name: String) async throws
    func renameTab(_ tabID: String, to name: String) async throws
    func moveSpace(_ spaceID: String, before: String?) async throws
    func moveTab(_ tabID: String, to index: Int) async throws
    func keepAsTab(_ address: String, in spaceID: String, after: String?) async throws -> String
    func markSeen(_ addresses: [String])
    func markUnread(_ address: String)
    func markRead(_ address: String)
    func setPinned(_ address: String, _ pinned: Bool)
    func refreshLaunchers(machine: String?)
}
