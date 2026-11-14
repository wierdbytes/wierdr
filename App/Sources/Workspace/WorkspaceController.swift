import SwiftUI
import WierdrModel

/// UI state and actions of one open session: the panel's commands (shared by
/// buttons, menus and keyboard shortcuts), pending selections, dialogs, toasts
/// and the sidebar's fold state.
@MainActor
@Observable
final class WorkspaceController {
    let workspace: Workspace
    let screen: ScreenState
    let isDemo: Bool

    // MARK: Navigation chrome
    var columnVisibility: NavigationSplitViewVisibility = .all
    var compactColumn: NavigationSplitViewColumn = .sidebar
    /// The sidebar slid over the panel while it's hidden (`SidebarOverlay`).
    var sidebarOverlay = false
    var showSwitcher = false
    var showSettings = false

    // MARK: Layout (set by `WorkspaceView`)
    /// The iPhone layout: one pane on screen at a time (the focused one).
    var singlePane = false
    /// A new space/tab/pane opens in front of the person (iPhone: the pane screen).
    var revealsNewPanes = false
    /// The terminal whose message field (`ComposerBar`) has the keyboard.
    var composing: String?
    /// Unsent message text per terminal address (the message field).
    var drafts: [String: String] = [:]

    // MARK: Dialogs
    struct RenameRequest: Identifiable {
        enum Target { case space(String), tab(String) }
        var id = UUID()
        var target: Target
        var title: String
        var text: String
    }
    var rename: RenameRequest?

    struct CloseRequest: Identifiable {
        enum Target { case space(String), tab(String), pane(String) }
        var id = UUID()
        var target: Target
        var title: String
        var message: String
    }
    var confirmClose: CloseRequest?

    // MARK: Toasts
    struct Toast: Identifiable, Equatable {
        var id = UUID()
        var message: String
    }
    private(set) var toasts: [Toast] = []

    // MARK: Sidebar state (persisted)
    var foldedMachines: Set<String> { didSet { save(foldedMachines, "sidebar.foldedMachines") } }
    var closedSpaces: Set<String> { didSet { save(closedSpaces, "sidebar.closedSpaces") } }
    /// Agents whose sub-agents are folded away (their badge folds them); the rest show theirs.
    var foldedAgents: Set<String> = []

    // MARK: Sub-agent shown for now
    /// A sub-agent without a pane, shown for now (as Herdr's `terminal.show`):
    /// on the iPad over the window with Keep and Close (`SubAgentPeek`), on the
    /// iPhone on the pane screen in its parent's place. Gone when another pane
    /// is focused, it ends, or someone keeps it.
    var peek: String?
    /// The sidebar row it was opened from (the iPhone shows it in that row's place).
    private(set) var peekFrom: String?

    // MARK: Keys (iPad)
    /// The key panel over the panel's panes (`KeyLayerHost`): out or not, its side.
    var keys = KeyPanelState()
    /// The panel's panes in the window (global), where the key panel goes.
    var keyArea: CGRect = .zero

    // MARK: Pending selection (a new tab/space/pane shows up with the next doc event)
    enum Pending: Equatable { case space(String), tab(String), pane(String) }
    private var pending: Pending?

    init(workspace: Workspace, screen: ScreenState, isDemo: Bool) {
        self.workspace = workspace
        self.screen = screen
        self.isDemo = isDemo
        // The demo always starts unfolded and doesn't touch the saved state.
        foldedMachines = isDemo ? [] : Self.load("sidebar.foldedMachines")
        closedSpaces = isDemo ? [] : Self.load("sidebar.closedSpaces")
    }

    // MARK: - Resolved selection

    var activeSpace: Space? { screen.activeSpace(in: workspace) }
    var activeTab: Tab? { screen.activeTab(in: workspace) }
    var focusedPane: Pane? { screen.focusedPane(in: workspace) }

    /// Machine headers are shown only when there is at least one added machine.
    var showsMachines: Bool { workspace.machines.contains { !$0.isLocal } }

    /// The rows the sidebar shows, in its order (for ⌘]/⌘[).
    var visibleRows: [SidebarRow] {
        workspace.spaces.flatMap { space -> [SidebarRow] in
            if showsMachines && foldedMachines.contains(space.machine ?? "") { return [] }
            if closedSpaces.contains(space.id) { return [] }
            return workspace.sidebarRows(for: space)
        }
    }

    /// All rows in sidebar order, ignoring folds (for "next agent with status").
    var allRows: [SidebarRow] { workspace.spaces.flatMap { workspace.sidebarRows(for: $0) } }

    // MARK: - Focus & selection

    func select(space: Space) {
        screen.select(space: space.id)
    }

    func select(tab: Tab) {
        screen.select(tab: tab)
    }

    /// Focus a pane (selects its space and tab); on iPhone shows the panel.
    func focus(pane paneID: String, reveal: Bool = true) {
        closePeek()
        screen.focus(pane: paneID, in: workspace)
        if reveal {
            compactColumn = .detail
            closeSidebarOverlay()
        }
    }

    func closeSidebarOverlay() {
        guard sidebarOverlay else { return }
        withAnimation(.easeOut(duration: 0.25)) { sidebarOverlay = false }
    }

    func showPanel() { compactColumn = .detail }
    func showSidebar() {
        compactColumn = .sidebar
        if columnVisibility == .detailOnly { columnVisibility = .all }
    }

    func toggleSidebar() {
        // The overlay's own Hide Sidebar button (and ⌘B over it) closes it.
        if sidebarOverlay { return closeSidebarOverlay() }
        // iPhone: the pane screen is pushed over the list, or popped (`PhoneWorkspaceView`).
        if singlePane { compactColumn = compactColumn == .sidebar ? .detail : .sidebar; return }
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// ⌘] / ⌘[: next/previous visible sidebar row (a kept sub-agent's pane after
    /// its parent's), wrapping.
    func stepRow(_ offset: Int) {
        let panes = visibleRows.flatMap(\.paneIDs)
        guard !panes.isEmpty else { return }
        let current = focusedPane.flatMap { p in panes.firstIndex(of: p.id) }
        let n = panes.count
        let next = current.map { (($0 + offset) % n + n) % n } ?? (offset > 0 ? 0 : n - 1)
        focus(pane: panes[next], reveal: false)
    }

    /// Agents with a pane in sidebar order: each row's, then its kept sub-agents'.
    private var agentPanes: [(pane: String, terminal: TerminalInfo)] {
        allRows.flatMap { row -> [(pane: String, terminal: TerminalInfo)] in
            guard row.kind == .agent, let t = row.terminal else { return [] }
            return [(row.paneID, t)] + row.subtree.compactMap { kid in
                kid.paneID.flatMap { p in kid.isAgent ? (p, kid.terminal) : nil }
            }
        }
    }

    /// Status bar: focus the next agent with `status` after the focused one (sidebar order, wrapping).
    func focusNext(status: AgentStatus) {
        let rows = agentPanes
        guard !rows.isEmpty else { return }
        let start = focusedPane.flatMap { p in rows.firstIndex { $0.pane == p.id } } ?? -1
        for k in 1...rows.count {
            let row = rows[(start + k + rows.count) % rows.count]
            if row.terminal.status == status {
                if let space = workspace.location(ofPane: row.pane)?.space {
                    if showsMachines { foldedMachines.remove(space.machine ?? "") }
                    closedSpaces.remove(space.id)
                }
                focus(pane: row.pane)
                return
            }
        }
    }

    // MARK: - Sub-agents

    /// A sub-agent's row was tapped (under the row of `rowPane`): kept, its pane;
    /// else it shows for now (`peek`): over the window on the iPad, in the row's
    /// place on the iPhone.
    func open(_ kid: SubAgent, from rowPane: String) {
        if let pane = kid.paneID { return focus(pane: pane) }
        if singlePane {
            focus(pane: rowPane)
        } else {
            closeSidebarOverlay()
            // The keyboard was the pane's under the window: it goes (a double tap brings one to the sub-agent).
            closeCompose()
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        withAnimation(.snappy(duration: 0.25)) {
            peek = kid.terminal.address
            peekFrom = rowPane
            // Keys out for the pane would now go to the sub-agent: a swipe brings them back.
            keys.open = false
        }
    }

    func closePeek() {
        guard peek != nil else { return }
        if composing == peek { closeCompose() }
        withAnimation(.snappy(duration: 0.2)) {
            peek = nil
            peekFrom = nil
            // Its keys were the sub-agent's: they don't stay out for the pane under it.
            keys.open = false
        }
    }

    /// The shown sub-agent went away (ended), or someone else gave it a pane.
    func checkPeek() {
        guard let address = peek else { return }
        let t = workspace.terminal(address)
        if t == nil || t?.isLive == false || workspace.pane(showing: address) != nil { closePeek() }
    }

    /// Where Keep puts a sub-agent: a tab right after its parent's (the nearest
    /// ancestor with a pane), else at the end of the space it's looked at from.
    func keepTarget(for address: String) -> (spaceID: String, after: String?, parent: String?)? {
        if let t = workspace.keepTarget(for: address) { return (t.spaceID, t.after, t.parent) }
        let machine = workspace.terminal(address)?.machine
        if let space = activeSpace, space.machine == machine { return (space.id, space.tabs.last?.id, nil) }
        guard let space = workspace.spaces(on: machine).first else { return nil }
        return (space.id, space.tabs.last?.id, nil)
    }

    /// Keep: a sub-agent becomes a tab (next to its parent's) and is focused there;
    /// it still shows under its parent in the list.
    func keep(_ address: String) {
        guard let target = keepTarget(for: address) else { return toast("Keep: no space to put it in") }
        closePeek()
        run("Keep") { [workspace] in
            let tab = try await workspace.keepAsTab(address, in: target.spaceID, after: target.after)
            self.selectWhenReady(.tab(tab))
        }
    }

    enum Direction { case left, right, up, down }

    /// ⌘⌥arrows: focus the geometric neighbor of the focused pane in the active tab.
    func moveFocus(_ direction: Direction) {
        guard let tab = activeTab, screen.zoomedPane(of: tab) == nil,
              let current = screen.focusedPane(of: tab) else { return }
        let rects = PaneGeometry.rects(of: tab.root)
        guard let from = rects[current.id] else { return }
        var best: (id: String, score: Double)?
        for (id, r) in rects where id != current.id {
            let gap: Double, overlap: Double
            switch direction {
            case .left:
                gap = from.minX - r.maxX; overlap = min(from.maxY, r.maxY) - max(from.minY, r.minY)
            case .right:
                gap = r.minX - from.maxX; overlap = min(from.maxY, r.maxY) - max(from.minY, r.minY)
            case .up:
                gap = from.minY - r.maxY; overlap = min(from.maxX, r.maxX) - max(from.minX, r.minX)
            case .down:
                gap = r.minY - from.maxY; overlap = min(from.maxX, r.maxX) - max(from.minX, r.minX)
            }
            guard gap > -0.0001, overlap > 0.0001 else { continue }
            let score = gap * 10 - overlap
            if best == nil || score < best!.score { best = (id, score) }
        }
        if let best { focus(pane: best.id, reveal: false) }
    }

    // MARK: - Commands

    /// ⌘T / new menu: a new tab in the active space, after the active tab.
    func newTab(launch: Launch = .shell, in space: Space? = nil) {
        guard let space = space ?? activeSpace else { return newSpace(launch: launch) }
        let after = space.id == activeSpace?.id ? activeTab?.id : space.tabs.last?.id
        run("New tab") { [workspace] in
            let id = try await workspace.newTab(in: space.id, after: after, launch: launch)
            self.selectWhenReady(.tab(id))
        }
    }

    /// ⌘N: a new space on the active space's machine (or `machine`).
    func newSpace(machine: String?? = nil, launch: Launch = .shell) {
        let target: String? = machine ?? activeSpace?.machine
        // Like the desktop: start where the focused pane is, when it is on that machine.
        let folder: String? = activeSpace?.machine == target ? workspace.terminal(focusedPane?.terminal)?.cwd : nil
        run("New space") { [workspace] in
            let id = try await workspace.newSpace(machine: target, folder: folder, launch: launch)
            self.selectWhenReady(.space(id))
        }
    }

    func split(_ direction: SplitDirection, pane: String? = nil) {
        guard let paneID = pane ?? focusedPane?.id else { return }
        run("Split") { [workspace] in
            let id = try await workspace.split(pane: paneID, direction: direction)
            self.selectWhenReady(.pane(id))
        }
    }

    func toggleZoom(pane: String? = nil) {
        guard let paneID = pane ?? focusedPane?.id else { return }
        screen.toggleZoom(pane: paneID, in: workspace)
    }

    /// ⌘W: close the active tab (asks first when agents run in it).
    func closeTab(_ tabID: String? = nil) {
        guard let tab = workspace.tab(tabID ?? activeTab?.id) else { return }
        let agents = tab.panes.compactMap { workspace.terminal($0.terminal) }.filter(\.isAgent)
        if agents.isEmpty {
            run("Close tab") { [workspace] in try await workspace.closeTab(tab.id) }
        } else {
            confirmClose = CloseRequest(
                target: .tab(tab.id), title: "Close tab \u{201C}\(tab.displayName)\u{201D}?",
                message: agents.count == 1 ? "An agent is running in it." : "\(agents.count) agents are running in it.")
        }
    }

    /// ⌘⇧W: close the focused pane (asks first when it runs an agent).
    func closePane(_ paneID: String? = nil) {
        guard let paneID = paneID ?? focusedPane?.id else { return }
        let pane = workspace.location(ofPane: paneID)?.tab.panes.first { $0.id == paneID }
        if let t = workspace.terminal(pane?.terminal), t.isAgent {
            confirmClose = CloseRequest(target: .pane(paneID), title: "Close \(t.program.name)?",
                                        message: "The agent in this pane will be stopped.")
        } else {
            run("Close pane") { [workspace] in try await workspace.closePane(paneID) }
        }
    }

    func closeSpace(_ spaceID: String) {
        guard let space = workspace.space(spaceID) else { return }
        let n = space.tabs.count
        confirmClose = CloseRequest(target: .space(spaceID), title: "Close space \u{201C}\(space.displayName)\u{201D}?",
                                    message: "Its \(n == 1 ? "tab" : "\(n) tabs") and terminals will be closed.")
    }

    func confirm(_ request: CloseRequest) {
        switch request.target {
        case .space(let id): run("Close space") { [workspace] in try await workspace.closeSpace(id) }
        case .tab(let id): run("Close tab") { [workspace] in try await workspace.closeTab(id) }
        case .pane(let id): run("Close pane") { [workspace] in try await workspace.closePane(id) }
        }
    }

    func beginRename(space id: String) {
        guard let space = workspace.space(id) else { return }
        rename = RenameRequest(target: .space(id), title: "Rename Space", text: space.name)
    }

    func beginRename(tab id: String? = nil) {
        guard let tab = workspace.tab(id ?? activeTab?.id) else { return }
        rename = RenameRequest(target: .tab(tab.id), title: "Rename Tab", text: tab.name)
    }

    func commit(_ request: RenameRequest) {
        let name = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.target {
        case .space(let id): run("Rename") { [workspace] in try await workspace.renameSpace(id, to: name) }
        case .tab(let id): run("Rename") { [workspace] in try await workspace.renameTab(id, to: name) }
        }
    }

    /// A space dropped in the sidebar: just before `before`, or last of its machine's (`nil`).
    func moveSpace(_ spaceID: String, before: String?, failed: @escaping @MainActor () -> Void = {}) {
        run("Move space") { [workspace] in
            do {
                try await workspace.moveSpace(spaceID, before: before)
            } catch {
                failed()
                throw error
            }
        }
    }

    func moveTab(_ tabID: String, to index: Int) {
        run("Move tab") { [workspace] in try await workspace.moveTab(tabID, to: index) }
    }

    func setPinned(_ address: String, _ pinned: Bool) {
        guard !isDemo else { return toast("Not available in the demo") }
        workspace.setPinned(address, pinned)
    }

    func markUnread(_ address: String) {
        guard !isDemo else { return toast("Not available in the demo") }
        workspace.markUnread(address)
    }

    func markRead(_ address: String) {
        guard !isDemo else { return toast("Not available in the demo") }
        workspace.markRead(address)
    }

    /// The agents on screen right now (none when `looking` is false): raise
    /// their shared `herdr.seen`. Also called when nothing is on screen, so an
    /// agent that left it is shared as seen again when it comes back.
    func markVisibleSeen(looking: Bool) {
        workspace.markSeen(looking ? visibleAgents : [])
    }

    /// Agents drawn in the panel: the active tab's (or its zoomed pane's), and a
    /// sub-agent shown for now.
    private var visibleAgents: [String] {
        // The iPhone shows it in its parent's place.
        let panes = singlePane && peek != nil ? [] : onScreenPanes.compactMap(\.terminal)
        return (panes + (peek.map { [$0] } ?? [])).filter { workspace.terminal($0)?.isAgent == true }
    }

    /// Panes drawn in the panel: the active tab's, its zoomed pane, or (iPhone) the focused one.
    var onScreenPanes: [Pane] {
        guard let tab = activeTab else { return [] }
        if singlePane { return screen.focusedPane(of: tab).map { [$0] } ?? [] }
        return screen.zoomedPane(of: tab).map { [$0] } ?? tab.panes
    }

    /// The most urgent status among the agents other than the one at `address` (the one on
    /// screen; needs you, done, working; never idle) and how many have it; `nil`: all idle.
    func attention(excluding address: String?) -> (status: AgentStatus, count: Int)? {
        var counts: [AgentStatus: Int] = [:]
        for row in agentPanes where row.terminal.address != address {
            if let s = row.terminal.status, s != .idle { counts[s, default: 0] += 1 }
        }
        return counts.keys.max().map { ($0, counts[$0] ?? 0) }
    }

    // MARK: - Pending selection

    private func selectWhenReady(_ p: Pending) {
        pending = p
        applyPending()
    }

    /// Called whenever the workspace's spaces change.
    func applyPending() {
        guard let p = pending else { return }
        switch p {
        case .space(let id):
            guard let space = workspace.space(id) else { return }
            if let pane = space.tabs.first?.panes.first { focus(pane: pane.id, reveal: revealsNewPanes) } else { select(space: space) }
        case .tab(let id):
            guard let tab = workspace.tab(id) else { return }
            if let pane = tab.panes.first { focus(pane: pane.id, reveal: revealsNewPanes) } else { select(tab: tab) }
        case .pane(let id):
            guard workspace.location(ofPane: id) != nil else { return }
            focus(pane: id, reveal: revealsNewPanes)
        }
        pending = nil
    }

    // MARK: - Running commands & toasts

    private func run(_ what: String, _ op: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await op()
            } catch {
                if isDemo, case WorkspaceError.notConnected = error {
                    toast("\(what): not available in the demo")
                } else {
                    toast("\(what) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func toast(_ message: String) {
        let t = Toast(message: message)
        withAnimation(.snappy) { toasts.append(t) }
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.2)) { self.toasts.removeAll { $0.id == t.id } }
        }
    }

    func dismiss(_ toast: Toast) {
        withAnimation(.easeOut(duration: 0.2)) { toasts.removeAll { $0.id == toast.id } }
    }

    // MARK: - Persistence

    private static func load(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private func save(_ set: Set<String>, _ key: String) {
        guard !isDemo else { return }
        UserDefaults.standard.set(Array(set).sorted(), forKey: key)
    }
}

/// Pane rectangles of a split tree in a unit square (for keyboard focus moves).
enum PaneGeometry {
    static func rects(of node: PaneNode, in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [String: CGRect] {
        switch node.kind {
        case .terminal, .mod:
            return [node.id: rect]
        case .row(let children), .column(let children):
            let isRow: Bool
            if case .row = node.kind { isRow = true } else { isRow = false }
            let total = children.reduce(0) { $0 + max($1.weight, 0.0001) }
            var out: [String: CGRect] = [:]
            var offset = 0.0
            for child in children {
                let f = max(child.weight, 0.0001) / total
                let r = isRow
                    ? CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: f * rect.width, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: f * rect.height)
                out.merge(rects(of: child, in: r)) { a, _ in a }
                offset += f
            }
            return out
        }
    }
}
