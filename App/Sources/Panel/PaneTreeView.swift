import SwiftUI
import WierdrModel

/// A tab's split tree: rows and columns of pane cards sized by `PaneNode.weight`,
/// 8 pt apart (ui-spec §8).
struct PaneTreeView: View {
    var tab: Tab
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        if let zoomed = controller.screen.zoomedPane(of: tab) {
            PaneCard(pane: zoomed, tab: tab, zoomed: true)
        } else {
            NodeView(node: tab.root, tab: tab)
        }
    }
}

private struct NodeView: View {
    var node: PaneNode
    var tab: Tab

    var body: some View {
        switch node.kind {
        case .terminal, .mod:
            if let pane = node.panes.first { PaneCard(pane: pane, tab: tab, zoomed: false) }
        case .row(let children):
            WeightedStack(axis: .horizontal, spacing: 8) {
                ForEach(children) { child in
                    NodeView(node: child, tab: tab).layoutValue(key: Weight.self, value: child.weight)
                }
            }
        case .column(let children):
            WeightedStack(axis: .vertical, spacing: 8) {
                ForEach(children) { child in
                    NodeView(node: child, tab: tab).layoutValue(key: Weight.self, value: child.weight)
                }
            }
        }
    }
}

private struct Weight: LayoutValueKey {
    static let defaultValue: Double = 1
}

/// Lays children out along an axis, splitting the space (minus gaps) by weight.
struct WeightedStack: Layout {
    var axis: Axis
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 300))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let weights = subviews.map { max($0[Weight.self], 0.0001) }
        let total = weights.reduce(0, +)
        let length = axis == .horizontal ? bounds.width : bounds.height
        let available = max(0, length - spacing * CGFloat(subviews.count - 1))
        var offset: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            // Round to whole points so neighbouring borders stay crisp.
            let end = i == subviews.count - 1 ? available : (available * CGFloat(weights[...i].reduce(0, +) / total)).rounded()
            let size = end - offset
            if axis == .horizontal {
                sub.place(at: CGPoint(x: bounds.minX + offset + spacing * CGFloat(i), y: bounds.minY),
                          proposal: ProposedViewSize(width: size, height: bounds.height))
            } else {
                sub.place(at: CGPoint(x: bounds.minX, y: bounds.minY + offset + spacing * CGFloat(i)),
                          proposal: ProposedViewSize(width: bounds.width, height: size))
            }
            offset = end
        }
    }
}

/// A pane card (§8): rounded, bordered (accent when focused), header + terminal.
struct PaneCard: View {
    var pane: Pane
    var tab: Tab
    var zoomed: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.terminalViewProvider) private var provider
    @AppStorage(TerminalFonts.sizeKey) private var fontSize = Double(TerminalFonts.defaultSize)

    var body: some View {
        let ws = controller.workspace
        let focused = controller.screen.focusedPane(of: tab)?.id == pane.id
            && controller.activeTab?.id == tab.id
        let terminal = ws.terminal(pane.terminal)
        VStack(spacing: 0) {
            PaneHeader(pane: pane, tab: tab, terminal: terminal, focused: focused, zoomed: zoomed)
            // The card decides the size; the terminal view fills it (never the other way round).
            Color.clear
                .overlay { content(terminal: terminal, focused: focused) }
                .clipped()
                .tutorialAnchor(focused ? .terminal : nil)
        }
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? theme.accent : theme.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .simultaneousGesture(TapGesture().onEnded {
            if !focused { controller.focus(pane: pane.id, reveal: false) }
        })
    }

    @ViewBuilder
    private func content(terminal: TerminalInfo?, focused: Bool) -> some View {
        if let address = pane.terminal {
            provider.makeView(TerminalViewContext(
                address: address, terminal: terminal, focused: focused, palette: theme.terminal,
                fontSize: fontSize, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
                requestFocus: { controller.focus(pane: pane.id, reveal: false) }))
            .id(address)
        } else {
            VStack(spacing: 8) {
                Icon("file-text", size: 22, color: theme.dim)
                Text("\(pane.mod ?? "This panel") is only shown in Herdr on the desktop")
                    .font(.ui(12)).foregroundStyle(theme.dim)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The pane header (§8): icon, name, cwd; split/zoom/close buttons on the focused pane.
struct PaneHeader: View {
    var pane: Pane
    var tab: Tab
    var terminal: TerminalInfo?
    var focused: Bool
    var zoomed: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let home = controller.workspace.home
        HStack(spacing: 8) {
            if let terminal {
                ProgramIcon(program: terminal.program, size: 14, color: theme.dim)
            } else {
                Icon("file-text", size: 14, color: theme.dim)
            }
            Text(terminal.map { Format.paneName($0) } ?? (pane.mod ?? "panel"))
                .font(.ui(12, .medium))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(Format.tilde(terminal?.cwd, home: home))
                .font(.ui(12))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            if focused || hovering {
                buttons
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .frame(maxWidth: .infinity)
        .background(theme.background)
        .overlay(alignment: .bottom) { Hairline() }
        .frame(height: 30, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.focus(pane: pane.id, reveal: false) }
        .contextMenu { menuItems }
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            headerButton("split-right", "Split Right") { controller.split(.right, pane: pane.id) }
            headerButton("split-down", "Split Down") { controller.split(.down, pane: pane.id) }
            headerButton(zoomed ? "unzoom" : "zoom", zoomed ? "Unzoom" : "Zoom") { controller.toggleZoom(pane: pane.id) }
            headerButton("close", "Close Pane") { controller.closePane(pane.id) }
        }
        .padding(.trailing, -4)
    }

    private func headerButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        ChromeIconButton(icon: icon, iconSize: 14, frame: 22, radius: 4, color: theme.dim, label: label, action: action)
    }

    @ViewBuilder
    var menuItems: some View {
        Button { controller.split(.right, pane: pane.id) } label: { Label("Split Right", image: "ui.split-right") }
        Button { controller.split(.down, pane: pane.id) } label: { Label("Split Down", image: "ui.split-down") }
        Button { controller.toggleZoom(pane: pane.id) } label: {
            Label(zoomed ? "Unzoom" : "Zoom", image: zoomed ? "ui.unzoom" : "ui.zoom")
        }
        Divider()
        Button(role: .destructive) { controller.closePane(pane.id) } label: { Label("Close Pane", image: "ui.x") }
    }
}
