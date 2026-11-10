import Foundation
import Observation

/// What this screen shows: the selected space, each space's selected tab,
/// each tab's focused and zoomed pane. Herdr keeps this per screen (it is not
/// in the shared document), so Wierdr keeps its own, saved per host.
@MainActor
@Observable
public final class ScreenState {
    public struct Snapshot: Codable, Equatable, Sendable {
        public var space: String?
        public var tabBySpace: [String: String] = [:]
        public var focusByTab: [String: String] = [:]
        public var zoomByTab: [String: String] = [:]
        public init() {}
    }

    public private(set) var snapshot: Snapshot
    /// Called after every change (persist it).
    @ObservationIgnored public var onChange: ((Snapshot) -> Void)?

    public init(snapshot: Snapshot = Snapshot()) {
        self.snapshot = snapshot
    }

    // MARK: Resolved against a workspace (falls back when ids vanished)

    public func activeSpace(in ws: Workspace) -> Space? {
        ws.space(snapshot.space) ?? ws.spaces.first
    }

    public func activeTab(in ws: Workspace) -> Tab? {
        guard let space = activeSpace(in: ws) else { return nil }
        return activeTab(of: space)
    }

    public func activeTab(of space: Space) -> Tab? {
        if let id = snapshot.tabBySpace[space.id], let tab = space.tabs.first(where: { $0.id == id }) { return tab }
        return space.tabs.first
    }

    public func focusedPane(of tab: Tab) -> Pane? {
        let panes = tab.panes
        if let id = snapshot.focusByTab[tab.id], let pane = panes.first(where: { $0.id == id }) { return pane }
        return panes.first(where: { $0.terminal != nil }) ?? panes.first
    }

    public func zoomedPane(of tab: Tab) -> Pane? {
        guard let id = snapshot.zoomByTab[tab.id] else { return nil }
        return tab.panes.first { $0.id == id }
    }

    /// The pane that has the keyboard on this screen.
    public func focusedPane(in ws: Workspace) -> Pane? {
        activeTab(in: ws).flatMap { focusedPane(of: $0) }
    }

    // MARK: Changes

    public func select(space id: String) {
        guard snapshot.space != id else { return }
        snapshot.space = id
        changed()
    }

    public func select(tab: Tab) {
        snapshot.space = tab.spaceID
        snapshot.tabBySpace[tab.spaceID] = tab.id
        changed()
    }

    /// Select the pane's space and tab and give it the keyboard.
    public func focus(pane paneID: String, in ws: Workspace) {
        guard let (space, tab) = ws.location(ofPane: paneID) else { return }
        snapshot.space = space.id
        snapshot.tabBySpace[space.id] = tab.id
        snapshot.focusByTab[tab.id] = paneID
        if let zoomed = snapshot.zoomByTab[tab.id], zoomed != paneID { snapshot.zoomByTab[tab.id] = nil }
        changed()
    }

    public func toggleZoom(pane paneID: String, in ws: Workspace) {
        guard let (_, tab) = ws.location(ofPane: paneID) else { return }
        if snapshot.zoomByTab[tab.id] == paneID {
            snapshot.zoomByTab[tab.id] = nil
        } else {
            snapshot.zoomByTab[tab.id] = paneID
            snapshot.focusByTab[tab.id] = paneID
        }
        changed()
    }

    // MARK: Navigation helpers (keyboard shortcuts)

    public func selectTab(offset: Int, in ws: Workspace) {
        guard let space = activeSpace(in: ws), !space.tabs.isEmpty,
              let current = activeTab(of: space), let i = space.tabs.firstIndex(of: current) else { return }
        let n = space.tabs.count
        select(tab: space.tabs[((i + offset) % n + n) % n])
    }

    public func selectTab(number: Int, in ws: Workspace) {
        guard let space = activeSpace(in: ws), number >= 1, number <= space.tabs.count else { return }
        select(tab: space.tabs[number - 1])
    }

    public func selectSpace(offset: Int, in ws: Workspace) {
        let spaces = ws.spaces
        guard !spaces.isEmpty else { return }
        let i = activeSpace(in: ws).flatMap { spaces.firstIndex(of: $0) } ?? 0
        let n = spaces.count
        select(space: spaces[((i + offset) % n + n) % n].id)
    }

    public func selectSpace(number: Int, in ws: Workspace) {
        guard number >= 1, number <= ws.spaces.count else { return }
        select(space: ws.spaces[number - 1].id)
    }

    private func changed() { onChange?(snapshot) }
}
