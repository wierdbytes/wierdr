import SwiftUI
import WierdrModel

/// The iPhone's first screen: every agent by what it needs from you
/// (`AgentsInbox`), or the spaces as on the desktop's sidebar (`SpacesList`).
struct PhoneHome: View {
    enum Mode: String { case agents, spaces }

    @AppStorage("phone.homeMode") private var mode: Mode = .agents
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            PhoneHomeHeader(mode: $mode)
            Group {
                switch mode {
                case .agents: AgentsInbox()
                case .spaces: SpacesList()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                ToastStack().padding(.horizontal, 12).padding(.bottom, 10)
            }
            PhoneHomeFooter()
        }
        .background(theme.chrome.ignoresSafeArea())
        .overlay(alignment: .top) { ConnectionBanner(top: 50) }
    }
}

/// "Agents  Spaces" (the list's two modes), search, settings. 50 pt.
private struct PhoneHomeHeader: View {
    @Binding var mode: PhoneHome.Mode
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 18) {
                modeButton(.agents, "Agents")
                modeButton(.spaces, "Spaces")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ChromeIconButton(icon: "search", iconSize: 19, frame: 40, radius: 10, label: "Go to") {
                controller.showSwitcher = true
            }
            ChromeIconButton(icon: "settings", iconSize: 19, frame: 40, radius: 10, label: "Settings") {
                controller.showSettings = true
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 50)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func modeButton(_ m: PhoneHome.Mode, _ title: String) -> some View {
        let selected = mode == m
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { mode = m }
        } label: {
            Text(title)
                .font(.ui(21, .semibold))
                .foregroundStyle(selected ? theme.foreground : theme.dim)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Status counts (tap: the next agent with that status) and the new menu.
private struct PhoneHomeFooter: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let counts = controller.workspace.statusCounts
        HStack(spacing: 16) {
            ForEach([AgentStatus.blocked, .done, .working, .idle], id: \.self) { status in
                let n = counts[status] ?? 0
                if n > 0 || status == .working || status == .idle {
                    Button { controller.focusNext(status: status) } label: {
                        HStack(spacing: 6) {
                            StatusMark(status: status, tint: status == .working && n == 0 ? theme.dim : nil)
                            Text("\(n)")
                                .font(.ui(14, .medium))
                                .foregroundStyle(n == 0 ? theme.dim : (status == .blocked ? theme.blocked : theme.muted))
                        }
                        .frame(minWidth: 36, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(n == 0)
                    .accessibilityLabel("\(n) \(Format.statusWord(status))")
                    .accessibilityHint("Opens the next one")
                }
            }
            Spacer(minLength: 0)
            PhoneNewSpaceMenu()
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .background(theme.chrome.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Hairline() }
    }
}

/// The `+` of the list: a new space (shell or agent), in the folder of the
/// last pane you looked at (as the desktop's New Space), on its computer.
private struct PhoneNewSpaceMenu: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let machine = controller.activeSpace?.machine
        let folder = controller.workspace.terminal(controller.focusedPane?.terminal)?.cwd
        Menu {
            Section(folder.map { "New space in \(Format.tilde($0, home: controller.workspace.home))" } ?? "New space") {
                LaunchMenuItems(machine: machine) { launch in controller.newSpace(launch: launch) }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.accentForeground)
                .frame(width: 40, height: 40)
                .background(theme.accent, in: Circle())
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("New Space")
        .onAppear { controller.workspace.refreshLaunchers(machine: machine) }
    }
}

/// Menu items to start a terminal or an installed agent (`New Tab` / `New Space`).
struct LaunchMenuItems: View {
    var machine: String?
    var action: (Launch) -> Void
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        let launchers = controller.workspace.launchers[machine ?? ""] ?? []
        Button { action(.shell) } label: {
            Label { Text("Terminal") } icon: { MenuIcon.image("program.shell") }
        }
        if launchers.isEmpty {
            Text("Checking installed agents…")
        }
        ForEach(launchers.filter { $0.installed == true }) { launcher in
            Button { action(.agent(launcher, task: nil)) } label: {
                Label { Text(launcher.program.name) } icon: { MenuIcon.image(launcher.program.iconAsset) }
            }
        }
    }
}

// MARK: - Agents inbox

/// Every agent (all spaces and computers), grouped by what it needs:
/// needs you, done, working, idle. Inside a group: pinned first, then the
/// most recent status change.
struct AgentsInbox: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    private struct Item: Identifiable {
        var row: SidebarRow
        var space: Space
        var id: String { row.paneID }
    }

    var body: some View {
        let groups = self.groups
        ScrollViewReader { proxy in
            List {
                ForEach(groups, id: \.status) { group in
                    sectionHeader(group.status, count: group.items.count)
                        .sidebarRow(id: "status:\(group.status.rawValue)", background: Color.clear)
                    ForEach(group.items) { item in
                        SidebarRowView(row: item.row, space: item.space, bracket: .none, showsSpace: true)
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.border, lineWidth: 1).allowsHitTesting(false))
                            .padding(.vertical, 3)
                            .sidebarRow(id: item.row.paneID, background: Color.clear)
                    }
                }
                if groups.isEmpty {
                    empty
                        .sidebarRow(id: "empty", background: Color.clear)
                }
                Color.clear.frame(height: 8)
                    .sidebarRow(id: "end", background: Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .onChange(of: controller.focusedPane?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(id) }
            }
        }
    }

    private var groups: [(status: AgentStatus, items: [Item])] {
        let ws = controller.workspace
        var byStatus: [AgentStatus: [Item]] = [:]
        for space in ws.spaces {
            for row in ws.sidebarRows(for: space) where row.kind == .agent {
                guard let status = row.terminal?.status else { continue }
                byStatus[status, default: []].append(Item(row: row, space: space))
            }
        }
        return [AgentStatus.blocked, .done, .working, .idle].compactMap { status in
            guard let items = byStatus[status], !items.isEmpty else { return nil }
            return (status, items.sorted { a, b in
                let ta = a.row.terminal, tb = b.row.terminal
                if ta?.pinned != tb?.pinned { return ta?.pinned == true }
                let da = ta?.statusChangedAt ?? .distantPast, db = tb?.statusChangedAt ?? .distantPast
                if da != db { return da > db }
                return a.row.paneID < b.row.paneID
            })
        }
    }

    private func sectionHeader(_ status: AgentStatus, count: Int) -> some View {
        HStack(spacing: 8) {
            StatusMark(status: status)
            Text(title(status))
                .font(.ui(12, .semibold))
                .foregroundStyle(status == .blocked ? theme.blocked : theme.muted)
            Text("\(count)")
                .font(.ui(12))
                .foregroundStyle(theme.dim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func title(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: return "NEEDS YOU"
        case .done: return "DONE"
        case .working: return "WORKING"
        case .idle: return "IDLE"
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text("No agents running")
                .font(.ui(15, .semibold))
                .foregroundStyle(theme.foreground)
            Text("Start one with + below, or open a space in Spaces.")
                .font(.ui(13))
                .foregroundStyle(theme.dim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}
