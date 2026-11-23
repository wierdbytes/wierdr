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
    /// The demo's agents answering messages and keys (nil when live).
    let demo: DemoAgents?

    // MARK: Navigation chrome
    var columnVisibility: NavigationSplitViewVisibility = .all
    var compactColumn: NavigationSplitViewColumn = .sidebar
    /// The sidebar slid over the panel while it's hidden (`SidebarOverlay`).
    var sidebarOverlay = false
    /// The agents panel (`AgentsPanel`), pushed over the sidebar's spaces in the sidebar
    /// itself (`SidebarNavController`): the status ring's tap, ⌘P; a swipe right puts it back.
    var showAgents = false
    /// The panel comes or goes at once, not pushed: the sidebar was covered when it was
    /// asked for (⌘P from a pane screen, or with the iPad's sidebar hidden).
    var agentsAtOnce = false
    /// ⌘P asked the panel's search field to take the keyboard (a tap on the ring leaves it
    /// be); the field that does takes the ask (a hidden sidebar's can't).
    var agentsSearchPending = false
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
        enum Target { case space(String), tab(String), pane(String), terminal(String) }
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
    /// Agents whose sub-agents are folded away (their bot chip folds them); the rest show theirs.
    var foldedAgents: Set<String> = []
    /// Agents and sub-agents whose terminals show (their `>_` chip opened them); the rest
    /// keep theirs folded. One left with no terminals leaves it (`foldEndedTerminals`).
    var openTerminals: Set<String> = []

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
        demo = isDemo ? DemoAgents(workspace: workspace) : nil
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

    /// The rows the sidebar shows, top to bottom as it draws them (for ⌘]/⌘[): the cards
    /// bottom up (an added machine's over this computer's, the first space lowest), a
    /// card's terminals over its agents, the newest and pinned agents lowest
    /// (`SpacesList`, `PhoneListLine`).
    var visibleRows: [SidebarRow] {
        let machines = showsMachines ? workspace.machines.map(\.name) : [nil]
        return machines.reversed().flatMap { machine -> [SidebarRow] in
            if showsMachines && foldedMachines.contains(machine ?? "") { return [] }
            let spaces = showsMachines ? workspace.spaces(on: machine) : workspace.spaces
            return spaces.reversed().flatMap { space -> [SidebarRow] in
                if closedSpaces.contains(space.id) { return [] }
                let page = workspace.phoneList(space: space.id)
                return (page.others.reversed() + page.agents.reversed()).map(\.row)
            }
        }
    }

    /// All rows in sidebar order, ignoring folds (what the counts count).
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

    /// The agents panel in the sidebar: the status ring's tap, or ⌘P (`search`: its field
    /// takes the keyboard). From a pane screen (iPhone layout) back to the sidebar; with the
    /// iPad's sidebar hidden, its overlay comes out.
    func openAgents(search: Bool = false) {
        let covered = singlePane ? compactColumn == .detail : columnVisibility == .detailOnly && !sidebarOverlay
        agentsAtOnce = covered
        showAgents = true
        agentsSearchPending = search
        if singlePane {
            if compactColumn == .detail { showSidebar() }
        } else if columnVisibility == .detailOnly, !sidebarOverlay {
            withAnimation(.easeOut(duration: 0.22)) { sidebarOverlay = true }
        }
    }

    /// The agents panel goes back to the right (Esc, VoiceOver's escape; a swipe sets it itself).
    func closeAgents() {
        agentsAtOnce = false
        agentsSearchPending = false
        showAgents = false
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

    /// A record's row was tapped (under the row of `row`): the terminal reporting it
    /// opens as a tap on its own row would (the row's agent: its pane; a sub-agent: as
    /// `open(_:from:)`). Records have no terminal of their own.
    func open(_ record: RecordKid, in row: SidebarRow) {
        if let kid = row.subtree.first(where: { $0.terminal.address == record.owner }) {
            open(kid, from: row.paneID)
        } else {
            focus(pane: row.paneID)
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

    /// A sub-agent's Close (a swipe, its menu): kept, its pane closes (`closePane`);
    /// else it ends, with the sub-agents it started. Asks first, as for a pane.
    func close(_ kid: SubAgent) {
        if let pane = kid.paneID { return closePane(pane) }
        let t = kid.terminal
        confirmClose = kid.isAgent
            ? CloseRequest(target: .terminal(t.address), title: "Close \(t.program.name)?",
                           message: "The sub-agent will be stopped.")
            : CloseRequest(target: .terminal(t.address), title: "Close \(Format.processName(t))?",
                           message: "The terminal will be stopped.")
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

    /// ⌘⇧W: close the focused pane (asks first when it runs an agent or a live terminal).
    func closePane(_ paneID: String? = nil) {
        guard let paneID = paneID ?? focusedPane?.id else { return }
        let pane = workspace.location(ofPane: paneID)?.tab.panes.first { $0.id == paneID }
        if let t = workspace.terminal(pane?.terminal), t.isAgent {
            confirmClose = CloseRequest(target: .pane(paneID), title: "Close \(t.program.name)?",
                                        message: "The agent in this pane will be stopped.")
        } else if let t = workspace.terminal(pane?.terminal), t.isLive {
            confirmClose = CloseRequest(target: .pane(paneID), title: "Close \(Format.processName(t))?",
                                        message: "The terminal in this pane will be closed.")
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
        case .terminal(let address): run("Close") { [workspace] in try await workspace.endTerminal(address) }
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

    /// Pin, unread and idle work in the demo too (its workspace changes them locally).
    func setPinned(_ address: String, _ pinned: Bool) {
        workspace.setPinned(address, pinned)
    }

    func markUnread(_ address: String) {
        workspace.markUnread(address)
    }

    func markRead(_ address: String) {
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
    /// Every sub-agent counts, as it reads under its parent (`kidStatus`).
    func attention(excluding address: String?) -> (status: AgentStatus, count: Int)? {
        let counts = allRows.countedAgents.filter { $0.terminal.address != address && $0.status != .idle }.byStatus
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
                report(what, error)
            }
        }
    }

    /// A command that failed: a toast.
    private func report(_ what: String, _ error: Error) {
        if isDemo, case WorkspaceError.notConnected = error {
            toast("\(what): not available in the demo")
        } else {
            toast("\(what) failed: \(error.localizedDescription)")
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
