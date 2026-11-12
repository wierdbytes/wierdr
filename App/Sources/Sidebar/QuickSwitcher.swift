import SwiftUI
import WierdrModel

/// Herdr's picker (⌘P): type to filter spaces, tabs and agents; spaces that need
/// you first; Return goes to the first match.
struct QuickSwitcher: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Item: Identifiable {
        enum Kind { case space, tab, agent }
        var id: String
        var kind: Kind
        var title: String
        var subtitle: String
        var status: AgentStatus?
        var space: Space
        var paneID: String?
        var program: Program?
        var tab: Tab?
    }

    private var items: [Item] {
        let ws = controller.workspace
        let spaces = ws.spaces.sorted { a, b in
            let ra = a.status == .blocked ? 1 : 0, rb = b.status == .blocked ? 1 : 0
            return ra > rb
        }
        var spaceItems: [Item] = [], tabItems: [Item] = [], agentItems: [Item] = []
        for space in spaces {
            let machine = space.machine.map { " · \($0)" } ?? ""
            spaceItems.append(Item(id: "s:" + space.id, kind: .space, title: space.displayName,
                                   subtitle: "\(space.tabs.count) tab\(space.tabs.count == 1 ? "" : "s")\(machine)",
                                   status: space.status, space: space))
            for tab in space.tabs {
                tabItems.append(Item(id: "t:" + tab.id, kind: .tab, title: "\(space.displayName) / \(tab.displayName)",
                                     subtitle: tab.panes.compactMap { ws.terminal($0.terminal)?.program.name }.joined(separator: ", "),
                                     status: tab.status, space: space, tab: tab))
            }
            for row in ws.sidebarRows(for: space) where row.kind == .agent {
                guard let t = row.terminal else { continue }
                agentItems.append(Item(id: "a:" + row.paneID, kind: .agent, title: Format.agentTitle(t, tab: ws.tab(row.tabID)),
                                       subtitle: "\(space.displayName) · \(t.meta?.model ?? t.program.name)",
                                       status: t.status, space: space, paneID: row.paneID, program: t.program))
                // Its kept sub-agents (they show under it in the list, not as rows).
                for kid in row.subtree where kid.isAgent {
                    guard let pane = kid.paneID else { continue }
                    let k = kid.terminal
                    agentItems.append(Item(id: "a:" + pane, kind: .agent, title: Format.kidTitle(k),
                                           subtitle: "\(space.displayName) · from \(Format.agentTitle(t, tab: ws.tab(row.tabID)))",
                                           status: k.status, space: space, paneID: pane, program: k.program))
                }
            }
        }
        let all = spaceItems + tabItems + agentItems
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    var body: some View {
        let items = self.items
        NavigationStack {
            List {
                section("Spaces", items.filter { $0.kind == .space })
                section("Tabs", items.filter { $0.kind == .tab })
                section("Agents", items.filter { $0.kind == .agent })
            }
            .overlay {
                if items.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Spaces, tabs, agents")
            .onSubmit(of: .search) { if let first = items.first { go(first) } }
            .navigationTitle("Go to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Item]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button { go(item) } label: { row(item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 12) {
            switch item.kind {
            case .space: SpaceAvatar(space: item.space, size: 22)
            case .tab: Image(systemName: "rectangle.on.rectangle").frame(width: 22).foregroundStyle(.secondary)
            case .agent:
                if let program = item.program {
                    ProgramIcon(program: program, size: 18, color: .secondary).frame(width: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let status = item.status, status != .idle {
                StatusMark(status: status, style: .full)
            }
        }
        .contentShape(Rectangle())
    }

    private func go(_ item: Item) {
        switch item.kind {
        case .space:
            controller.select(space: item.space)
        case .tab:
            if let tab = item.tab { controller.select(tab: tab) }
        case .agent:
            if let pane = item.paneID { controller.focus(pane: pane) }
        }
        controller.showPanel()
        if controller.showsMachines { controller.foldedMachines.remove(item.space.machine ?? "") }
        dismiss()
    }
}
