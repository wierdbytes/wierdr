import SwiftUI
import WierdrModel

/// A connected (or demo) session: sidebar + terminal panel in a split view.
struct WorkspaceView: View {
    @Bindable var controller: WorkspaceController
    var hostName: String?
    var onDisconnect: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    /// Read here, outside the split view (its sidebar column is always compact).
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var windowWidth: CGFloat = 0

    var body: some View {
        let phone = usesPhoneLayout
        Group {
            if phone {
                PhoneWorkspaceView()
            } else {
                splitView
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .environment(controller)
        .environment(\.homeFolder, controller.workspace.home)
        .environment(\.isCompactLayout, phone || sizeClass == .compact)
        .focusedSceneValue(\.workspaceController, controller)
        .sheet(isPresented: $controller.showSwitcher) {
            QuickSwitcher().environment(controller).environment(\.theme, theme)
        }
        .sheet(isPresented: $controller.showSettings) {
            SettingsView(hostName: hostName, isDemo: controller.isDemo, onDisconnect: onDisconnect)
        }
        .alert(controller.rename?.title ?? "Rename", isPresented: renameShown, presenting: controller.rename) { request in
            TextField("Name", text: renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let r = controller.rename { controller.commit(r) } }
        } message: { _ in
            Text("Leave empty to use the automatic name.")
        }
        .alert(controller.confirmClose?.title ?? "Close?", isPresented: closeShown, presenting: controller.confirmClose) { request in
            Button("Cancel", role: .cancel) {}
            Button("Close", role: .destructive) { controller.confirm(request) }
        } message: { request in
            Text(request.message)
        }
        .onChange(of: phone, initial: true) { _, phone in
            controller.singlePane = phone
            controller.revealsNewPanes = phone
        }
        .onChange(of: controller.workspace.spaces) { _, _ in controller.applyPending() }
        .onChange(of: seenKey) { _, _ in controller.markVisibleSeen(looking: looking) }
        .onAppear { controller.markVisibleSeen(looking: looking) }
    }

    /// iPhone (any orientation) and narrow iPad windows: the list and one pane
    /// at a time (`PhoneWorkspaceView`); else the sidebar and the panel side by side.
    private var usesPhoneLayout: Bool { Device.isPhone || sizeClass == .compact }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $controller.columnVisibility,
                            preferredCompactColumn: $controller.compactColumn) {
            SidebarColumn(range: sidebarRange, resizable: sizeClass != .compact)
                // Our brand bar has its own toggle; the system one would sit (invisibly) under its buttons.
                .toolbar(removing: .sidebarToggle)
                .toolbar(.hidden, for: .navigationBar)
        } detail: {
            TerminalPanel()
                .overlay(alignment: .leading) {
                    if sizeClass != .compact { DockedSidebarEdge(range: sidebarRange) }
                }
                .toolbar(removing: .sidebarToggle)
                .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            if sizeClass != .compact { SidebarOverlay(range: sidebarRange) }
        }
        .toolbar(removing: .sidebarToggle)
    }

    /// Sidebar widths: at most 640 pt and 60% of the window, so the panel keeps room.
    private var sidebarRange: ClosedRange<Double> {
        let lower = SidebarResizeHandle.minWidth
        let upper = windowWidth > 0 ? min(640, Double(windowWidth) * 0.6) : 640
        return lower...max(lower, upper)
    }

    /// The panel is in front of the person: the app is active and, when the
    /// split view is collapsed (or on iPhone), it shows the panel rather than the list.
    private var looking: Bool {
        scenePhase == .active && !((usesPhoneLayout || sizeClass == .compact) && controller.compactColumn == .sidebar)
    }

    /// Changes when the agents on screen, their turns or `looking` change.
    private var seenKey: String {
        guard looking else { return "" }
        return controller.onScreenPanes.compactMap { p in
            p.terminal.flatMap { controller.workspace.terminal($0) }.map { "\($0.address):\($0.turn):\($0.status?.rawValue ?? 0)" }
        }.joined(separator: ",")
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { controller.rename != nil }, set: { if !$0 { controller.rename = nil } })
    }

    private var renameText: Binding<String> {
        Binding(get: { controller.rename?.text ?? "" }, set: { controller.rename?.text = $0 })
    }

    private var closeShown: Binding<Bool> {
        Binding(get: { controller.confirmClose != nil }, set: { if !$0 { controller.confirmClose = nil } })
    }
}

// MARK: - Compact layout (iPhone, narrow windows)

private struct CompactLayoutKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The split view is collapsed into a stack (sidebar → panel).
    var isCompactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

// MARK: - Focused scene value (for menu commands)

private struct WorkspaceControllerKey: FocusedValueKey {
    typealias Value = WorkspaceController
}

extension FocusedValues {
    var workspaceController: WorkspaceController? {
        get { self[WorkspaceControllerKey.self] }
        set { self[WorkspaceControllerKey.self] = newValue }
    }
}
