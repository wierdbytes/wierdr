import SwiftUI
import WierdrModel

/// The spaces list (§4): machine headers, space cards and their rows.
///
/// A native `List` (swipe actions, context menus, scroll-to, keyboard focus)
/// whose rows draw the pieces of each card: the card itself is the rows'
/// `listRowBackground` (`CardSlice`), so swiping a row slides its content over
/// a card that stays put. Cards are dragged by their header to reorder them
/// among their machine's (`SpaceDrag`).
struct SpacesList: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact
    @State private var drag = SpaceDrag()

    var body: some View {
        let ws = controller.workspace
        let showsMachines = controller.showsMachines
        ScrollViewReader { proxy in
            List {
                if showsMachines {
                    ForEach(ws.machines) { machine in
                        let folded = controller.foldedMachines.contains(machine.id)
                        MachineHeader(machine: machine, folded: folded)
                            .sidebarRow(id: "machine:\(machine.id)", background: Color.clear)
                        if !folded {
                            let spaces = ws.spaces(on: machine.name)
                            if case .loading = machine.state {
                                NoteRow(text: "Loading…", icon: nil)
                                    .sidebarRow(id: "loading:\(machine.id)", background: Color.clear)
                            } else if spaces.isEmpty && !machine.isLocal {
                                NoteRow(text: "New space there", icon: "plus") {
                                    controller.newSpace(machine: .some(machine.name))
                                }
                                .sidebarRow(id: "empty:\(machine.id)", background: Color.clear)
                            }
                            ForEach(drag.arranged(spaces, machine: machine.name)) { space in
                                SpaceCardRows(space: space)
                            }
                        }
                    }
                } else {
                    // No added machines: all of them are this computer's.
                    ForEach(drag.arranged(ws.spaces, machine: nil)) { space in
                        SpaceCardRows(space: space)
                    }
                }
                Color.clear.frame(height: 8)
                    .sidebarRow(id: "end", background: Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .contentMargins(.top, 4, for: .scrollContent)
            .environment(drag)
            .background(SpaceDropTarget(drag: drag))
            .onAppear {
                drag.controller = controller
                drag.theme = theme
                drag.compact = compact
            }
            .onChange(of: theme) { drag.theme = theme }
            .onChange(of: compact) { drag.compact = compact }
            .onChange(of: ws.spaces.map(\.id)) { drag.settle() }
            .onChange(of: controller.focusedPane?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(controller.listID(ofPane: id)) }
            }
            .onChange(of: controller.activeSpace?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo("space:\(id)") }
            }
        }
    }
}

extension View {
    /// A sidebar list row: no insets except the list's 8-pt side padding, no separator.
    func sidebarRow<B: View>(id: String, background: B) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(background)
            .id(id)
    }
}

// MARK: - Card

/// The rows of one space card: its header and (unless hidden) its rows.
struct SpaceCardRows: View {
    var space: Space
    @Environment(WorkspaceController.self) private var controller
    @Environment(SpaceDrag.self) private var drag: SpaceDrag?

    var body: some View {
        let ws = controller.workspace
        let rows = ws.sidebarRows(for: space)
        let closed = controller.closedSpaces.contains(space.id)
        let bodyShown = !closed && !rows.isEmpty
        // Dragged: its rows stay (they keep the card's height), empty, as the slot
        // where it would land.
        let slot = drag?.dragged == space.id
        SpaceHeader(space: space, rows: rows, closed: closed, bodyShown: bodyShown)
            .opacity(slot ? 0 : 1)
            .background(SpaceRowMarker(space: space.id, header: true, markers: drag?.markers))
            .sidebarRow(id: "space:\(space.id)", background: CardSlice(top: true, bottom: !bodyShown, slot: slot))
        if bodyShown {
            // An agent's sub-agents are rows of their own under it: folding them
            // (its badge) inserts and removes rows, which the list animates.
            let items = controller.cardItems(rows)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let last = i == items.count - 1
                let bracket = Bracket.position(items, i)
                Group {
                    switch item {
                    case .row(let row):
                        SidebarRowView(row: row, space: space, bracket: bracket)
                    case .kid(let kid, let parent):
                        SubAgentRowView(kid: kid, parent: parent, bracket: bracket)
                    }
                }
                .padding(.horizontal, 5) // 1-pt border + 4-pt card padding
                .padding(.top, 4)
                .padding(.bottom, last ? 4 : 0)
                .padding(.bottom, last ? 7 : 0) // 1-pt border + 6-pt gap after the card
                .opacity(slot ? 0 : 1)
                .background(SpaceRowMarker(space: space.id, markers: drag?.markers))
                .sidebarRow(id: item.id, background: CardSlice(top: false, bottom: last, slot: slot))
            }
        }
    }
}

/// A horizontal piece of a space card, drawn as a list row background:
/// `surface` fill with the card's 1-pt border; rounded at the card's ends.
/// The 6-pt gap after a card is left transparent. `slot`: the card is being
/// dragged, and this is where it would land: a dashed `accent`@35% outline on
/// `accent`@5%.
struct CardSlice: View {
    var top: Bool
    var bottom: Bool
    var slot = false
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - (bottom ? 6 : 0)
            let r: CGFloat = 10
            let shape = UnevenRoundedRectangle(topLeadingRadius: top ? r : 0, bottomLeadingRadius: bottom ? r : 0,
                                               bottomTrailingRadius: bottom ? r : 0, topTrailingRadius: top ? r : 0)
            ZStack(alignment: .top) {
                shape.fill(slot ? theme.accent.opacity(0.05) : theme.surface)
                    .frame(height: h)
                // Stroke a taller rounded rect and clip it, so open ends have no line.
                RoundedRectangle(cornerRadius: r)
                    .strokeBorder(slot ? theme.accent.opacity(0.35) : theme.border,
                                  style: StrokeStyle(lineWidth: 1, dash: slot ? [4, 3] : []))
                    .frame(height: h + (top ? 0 : 2 * r) + (bottom ? 0 : 2 * r))
                    .offset(y: top ? 0 : -2 * r)
                    .frame(height: h, alignment: .top)
                    .clipped()
            }
            .frame(height: geo.size.height, alignment: .top)
        }
        .padding(.horizontal, 8)
    }
}

/// Where a row sits in its split tab's bracket (§4.11: a 2-pt `accent`@50% `[`).
enum Bracket {
    case none, first, middle, last, only

    static func position(_ rows: [SidebarRow], _ i: Int) -> Bracket {
        position(rows.map { .row($0) }, i)
    }

    /// A sub-agent's row is in its agent's tab: the bracket goes on past it.
    static func position(_ items: [CardItem], _ i: Int) -> Bracket {
        let row = items[i].row
        guard row.tabIsSplit else { return .none }
        let startsGroup = i == 0 || items[i - 1].row.tabID != row.tabID
        let endsGroup = i == items.count - 1 || items[i + 1].row.tabID != row.tabID
        switch (startsGroup, endsGroup) {
        case (true, true): return .only
        case (true, false): return .first
        case (false, true): return .last
        default: return .middle
        }
    }
}

/// The bracket piece for one row. The row's 4-pt top gap is above its frame,
/// so middle/last pieces reach up 4 pt to join the previous one.
struct BracketShape: Shape {
    var position: Bracket
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x = rect.minX + 1, arm: CGFloat = 10, r: CGFloat = 8
        let top = rect.minY, bottom = rect.maxY
        switch position {
        case .none:
            break
        case .first, .only:
            p.move(to: CGPoint(x: x + arm, y: top + 1))
            p.addLine(to: CGPoint(x: x + r, y: top + 1))
            p.addQuadCurve(to: CGPoint(x: x, y: top + r), control: CGPoint(x: x, y: top + 1))
            if position == .only {
                p.addLine(to: CGPoint(x: x, y: bottom - r))
                p.addQuadCurve(to: CGPoint(x: x + r, y: bottom - 1), control: CGPoint(x: x, y: bottom - 1))
                p.addLine(to: CGPoint(x: x + arm, y: bottom - 1))
            } else {
                p.addLine(to: CGPoint(x: x, y: bottom))
            }
        case .middle:
            p.move(to: CGPoint(x: x, y: top - 4))
            p.addLine(to: CGPoint(x: x, y: bottom))
        case .last:
            p.move(to: CGPoint(x: x, y: top - 4))
            p.addLine(to: CGPoint(x: x, y: bottom - r))
            p.addQuadCurve(to: CGPoint(x: x + r, y: bottom - 1), control: CGPoint(x: x, y: bottom - 1))
            p.addLine(to: CGPoint(x: x + arm, y: bottom - 1))
        }
        return p
    }
}

// MARK: - Machine header (§4.2)

struct MachineHeader: View {
    var machine: Machine
    var folded: Bool
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var hovering = false
    @State private var plusHover = false

    var body: some View {
        let ws = controller.workspace
        HStack(spacing: 7) {
            Icon(machine.isLocal ? "monitor" : "server", size: 13, color: theme.dim)
            Text(machine.displayName)
                .font(.ui(11))
                .foregroundStyle(theme.dim)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if folded {
                StatusSummary(counts: counts(ws))
            }
            if case .unavailable(let why) = machine.state {
                Text(why.replacingOccurrences(of: "_", with: " "))
                    .font(.ui(11)).foregroundStyle(theme.dim).lineLimit(1)
            }
            Button { controller.newSpace(machine: .some(machine.name)) } label: {
                Text("+")
                    .font(.ui(13))
                    .foregroundStyle(plusHover ? theme.foreground : theme.dim)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .background(plusHover ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { plusHover = $0 }
            .hoverEffect(.highlight)
            .accessibilityLabel("New space on \(machine.displayName)")
            Circle()
                .fill(machine.isConnected ? theme.ansi(2) : theme.dim)
                .frame(width: 6, height: 6)
                .accessibilityLabel(machine.isConnected ? "Connected" : "Not connected")
            Icon(folded ? "chevron-right" : "chevron-down", size: 11, color: theme.dim)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(hovering ? theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if folded { controller.foldedMachines.remove(machine.id) } else { controller.foldedMachines.insert(machine.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(machine.displayName)
        .accessibilityHint(folded ? "Shows its spaces" : "Hides its spaces")
        .accessibilityAddTraits(.isButton)
    }

    /// Its spaces' agents, sub-agents too (as each card counts them).
    private func counts(_ ws: Workspace) -> [AgentStatus: Int] {
        ws.agentCounts(on: machine.name)
    }
}

/// A 28-pt note row ("Loading…", "New space there").
struct NoteRow: View {
    var text: String
    var icon: String?
    var action: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Icon(icon, size: 12, color: theme.dim) }
            Text(text).font(.ui(12)).foregroundStyle(theme.dim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(hovering && action != nil ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
    }
}
