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
    var showSwitcher = false
    var showSettings = false

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
    var expandedAgents: Set<String> = []

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

    /// The rows the sidebar shows, in its order (for ⌘]/⌘[ and the status bar).
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
        screen.focus(pane: paneID, in: workspace)
        if reveal { compactColumn = .detail }
    }

    func showPanel() { compactColumn = .detail }
    func showSidebar() {
        compactColumn = .sidebar
        if columnVisibility == .detailOnly { columnVisibility = .all }
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// ⌘] / ⌘[: next/previous visible sidebar row, wrapping.
    func stepRow(_ offset: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let current = focusedPane.flatMap { p in rows.firstIndex { $0.paneID == p.id } }
        let n = rows.count
        let next = current.map { (($0 + offset) % n + n) % n } ?? (offset > 0 ? 0 : n - 1)
        focus(pane: rows[next].paneID, reveal: false)
    }

    /// Status bar: focus the next agent with `status` after the focused one (sidebar order, wrapping).
    func focusNext(status: AgentStatus) {
        let rows = allRows
        guard !rows.isEmpty else { return }
        let start = focusedPane.flatMap { p in rows.firstIndex { $0.paneID == p.id } } ?? -1
        for k in 1...rows.count {
            let row = rows[(start + k + rows.count) % rows.count]
            if row.kind == .agent, row.terminal?.status == status {
                if let space = workspace.location(ofPane: row.paneID)?.space {
                    if showsMachines { foldedMachines.remove(space.machine ?? "") }
                    closedSpaces.remove(space.id)
                }
                focus(pane: row.paneID)
                return
            }
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
        run("New space") { [workspace] in
            let id = try await workspace.newSpace(machine: target, launch: launch)
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

    /// The agents on screen right now: raise their shared `herdr.seen`.
    func markVisibleSeen() {
        guard let tab = activeTab else { return }
        let panes = screen.zoomedPane(of: tab).map { [$0] } ?? tab.panes
        let addresses = panes.compactMap(\.terminal).filter { workspace.terminal($0)?.isAgent == true }
        if !addresses.isEmpty { workspace.markSeen(addresses) }
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
            if let pane = space.tabs.first?.panes.first { focus(pane: pane.id, reveal: false) } else { select(space: space) }
        case .tab(let id):
            guard let tab = workspace.tab(id) else { return }
            if let pane = tab.panes.first { focus(pane: pane.id, reveal: false) } else { select(tab: tab) }
        case .pane(let id):
            guard workspace.location(ofPane: id) != nil else { return }
            focus(pane: id, reveal: false)
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
