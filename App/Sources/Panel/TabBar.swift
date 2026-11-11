import SwiftUI
import WierdrModel

/// The tab bar (ui-spec §5): 42 pt, pills, `+` new menu.
struct TabBar: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var isCompact

    var body: some View {
        let ws = controller.workspace
        let space = controller.activeSpace
        let active = controller.activeTab
        HStack(spacing: 3) {
            if isCompact {
                ChromeIconButton(icon: "chevron-left", iconSize: 15, label: "Spaces") { controller.showSidebar() }
            } else if controller.columnVisibility == .detailOnly {
                ChromeIconButton(icon: "sidebar", iconSize: 15, label: "Show Sidebar") { controller.toggleSidebar() }
                    .padding(.trailing, 4)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(space?.tabs ?? []) { tab in
                            TabPill(tab: tab, isActive: tab.id == active?.id,
                                    zoomed: controller.screen.zoomedPane(of: tab) != nil, workspace: ws)
                                .id(tab.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onChange(of: active?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(id) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NewMenu()
        }
        .padding(.horizontal, 10)
        .frame(height: 41)
        .clearsWindowControls()
        .frame(maxWidth: .infinity)
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Hairline() }
        .frame(height: 42, alignment: .top)
        .background(theme.chrome)
    }
}

/// One tab pill.
struct TabPill: View {
    var tab: Tab
    var isActive: Bool
    var zoomed: Bool
    var workspace: Workspace

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var hovering = false

    /// The program of the tab's first agent pane, else its first pane.
    private var program: Program? {
        let terms = tab.panes.compactMap { workspace.terminal($0.terminal) }
        return (terms.first(where: \.isAgent) ?? terms.first)?.program
    }

    var body: some View {
        HStack(spacing: 7) {
            if let program {
                ProgramIcon(program: program, size: 14, color: theme.muted)
            } else {
                Icon("terminal", size: 14, color: theme.muted)
            }
            Text(tab.displayName + (zoomed ? " Z" : ""))
                .font(.ui(12.8, isActive ? .medium : .regular))
                .foregroundStyle(isActive ? theme.foreground : theme.muted)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            statusMark
            if isActive {
                Button { controller.closeTab(tab.id) } label: {
                    Icon("close", size: 12, color: theme.dim)
                        .frame(width: 16, height: 16)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .padding(-5)
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .background(isActive ? theme.raised : (hovering ? theme.hover : theme.chrome), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isActive ? theme.border : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { controller.select(tab: tab) }
        .onHover { hovering = $0 }
        .hoverEffect(.lift)
        // Drag a pill onto another to move it there (tab.move).
        .draggable(TabDrag(id: tab.id))
        .dropDestination(for: TabDrag.self) { items, _ in
            guard let dragged = items.first, dragged.id != tab.id else { return false }
            controller.moveTab(dragged.id, to: tab.index)
            return true
        }
        .contextMenu {
            Button { controller.beginRename(tab: tab.id) } label: { Label("Rename…", image: "ui.square-pen") }
            Button { controller.newTab(in: workspace.space(tab.spaceID)) } label: { Label("New Tab", image: "ui.plus") }
            Divider()
            Button(role: .destructive) { controller.closeTab(tab.id) } label: { Label("Close Tab", image: "ui.x") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab \(tab.displayName)\(tab.status.map { ", " + Format.statusWord($0) } ?? "")")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var statusMark: some View {
        switch tab.status {
        case .working: Spinner(size: 12, color: theme.working)
        case .blocked: Circle().fill(theme.blocked).frame(width: 6, height: 6)
        case .done: Circle().fill(theme.done).frame(width: 6, height: 6)
        default: EmptyView()
        }
    }
}

/// The `+` button: the new menu (§6) as a native menu.
struct NewMenu: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let machine = controller.activeSpace?.machine ?? ""
        let launchers = controller.workspace.launchers[machine] ?? []
        let installed = launchers.filter { $0.installed == true }
        let missing = launchers.filter { $0.installed == false }.prefix(2)
        Menu {
            Button { controller.newTab() } label: {
                Label { Text("Terminal") } icon: { MenuIcon.image("program.shell") }
            }
            .keyboardShortcut("t", modifiers: .command)
            Section("Start an agent") {
                if launchers.isEmpty {
                    Text("Checking installed agents…")
                }
                ForEach(installed) { launcher in
                    Button { controller.newTab(launch: .agent(launcher, task: nil)) } label: {
                        Label { Text(launcher.program.name) } icon: { MenuIcon.image(launcher.program.iconAsset) }
                    }
                }
                ForEach(Array(missing)) { launcher in
                    Button {} label: {
                        Label {
                            Text(launcher.program.name)
                            Text("Not installed")
                        } icon: { MenuIcon.image(launcher.program.iconAsset) }
                    }
                    .disabled(true)
                }
            }
            Divider()
            Button { controller.newSpace() } label: {
                Label { Text("New Space") } icon: { MenuIcon.image("ui.plus") }
            }
            .keyboardShortcut("n", modifiers: .command)
        } label: {
            Text("+")
                .font(.ui(17))
                .foregroundStyle(hovering ? theme.foreground : theme.dim)
                .frame(width: 26, height: 26)
                .background(hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverEffect(.highlight)
        .accessibilityLabel("New")
        .onAppear { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
    }
}

/// A dragged tab pill (in-app only).
struct TabDrag: Codable, Transferable {
    var id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
