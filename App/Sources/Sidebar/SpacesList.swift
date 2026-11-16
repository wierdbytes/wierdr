import SwiftUI
import WierdrModel

/// The sidebar's list (iPhone and iPad): the space cards (`SpaceCard`), drawn bottom up
/// for a thumb: this computer's spaces lowest, the first space at the bottom, each added
/// machine's group over them; a group's header (`MachineHeader`, with fold and +) under
/// it, as a card's header is under its rows (the newest and pinned lowest). A vertical `ScrollView` over a lazy
/// stack, a card an item of it, resting at its bottom: cards short of its height sit there,
/// and a card that grows or comes keeps the ones under it in place
/// (`defaultScrollAnchor(.bottom)` for the initial offset and size changes).
///
/// Cards fold (their chevron; the iPhone's header tap), and are dragged by their header to
/// reorder them among their machine's (`SpaceDrag`, held then moved, as the menu comes).
/// Pulled up past its bottom, it brings out Go to's field under the last card; let go
/// past 72 pt, Go to opens (`PullToSearch`).
struct SpacesList: View {
    /// The status bar's room over the list (the cards scroll under it).
    var topInset: CGFloat
    /// The header's room over the list's bottom, with the home indicator's (content ends
    /// over it, scrolls under it).
    var bottomInset: CGFloat

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.isCompactLayout) private var compact
    @State private var drag = SpaceDrag()
    @State private var swipes = PhoneRowSwipes()
    @State private var pull = PullToSearch(threshold: PullToSearchStyle.phone.threshold, edge: .bottom)
    @State private var position = ScrollPosition(edge: .bottom)
    /// The list's height under its insets.
    @State private var viewport: CGFloat = 0

    /// Between cards, and from the list's sides.
    static let gap: CGFloat = 8
    static let side: CGFloat = 8

    var body: some View {
        let blocks = SpacesListBlock.blocks(controller: controller, drag: drag)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(blocks) { block in
                        self.block(block)
                    }
                }
                .padding(.top, Self.gap)
                // The list's whole height, the cards at its bottom: a tap over them closes an
                // open row too (the rows' own taps go first).
                .frame(minHeight: viewport, alignment: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(PhoneSwipeMotion.bodyAnimation) { swipes.closeAll() } }
                .background(SpaceListInteractions(drag: drag))
                .overlay {
                    if controller.workspace.spaces.isEmpty, controller.workspace.phase == .live { empty }
                }
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .contentMargins(.top, topInset, for: .scrollContent)
            .contentMargins(.top, topInset, for: .scrollIndicators)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            // Its own height less the margins (not the scroll geometry's: its container's size goes without them).
            .onGeometryChange(for: CGFloat.self) { $0.size.height - topInset - bottomInset } action: { h in
                viewport = max(0, h)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { [viewport, topInset] g in
                PullToSearch.overscrollBottom(g, viewport: viewport, top: topInset)
            }) { _, d in
                pull.scrolled(d)
            }
            .overlay(alignment: .bottom) {
                PullToSearchField(pull: pull, style: .phone, inset: bottomInset)
            }
            .environment(swipes)
            .environment(drag)
            .onScrollPhaseChange { old, phase in
                // Scrolling closes an open row (Telegram: as the list's drag begins).
                if phase == .interacting, swipes.openID != nil { swipes.closeAll() }
                if pull.phaseChanged(from: old, to: phase) { controller.showSwitcher = true }
            }
            .onAppear {
                drag.controller = controller
                drag.theme = theme
                drag.compact = compact
            }
            .onChange(of: theme) { drag.theme = theme }
            .onChange(of: compact) { drag.compact = compact }
            .onChange(of: controller.workspace.spaces.map(\.id)) { drag.settle() }
            .onChange(of: controller.workspace.spaces.isEmpty, initial: true) { _, empty in
                // The first spaces came after the list was laid out (the initial anchor
                // had nothing to rest on): to its bottom, once they're laid out.
                guard !empty else { return }
                DispatchQueue.main.async { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: controller.focusedPane?.id) { _, id in
                // The iPad: the card of the pane in front comes into view (the iPhone's list has none).
                guard !controller.singlePane, let id, let space = controller.workspace.location(ofPane: id)?.space else { return }
                withAnimation(.easeOut(duration: 0.28)) { proxy.scrollTo(SpacesListBlock.cardID(space.id)) }
            }
            .onChange(of: controller.revealSpace, initial: true) { _, id in
                // Go to chose a space: its card, unfolded, comes into view.
                guard let id else { return }
                controller.revealSpace = nil
                if let space = controller.workspace.space(id) {
                    controller.foldedMachines.remove(space.machine ?? "")
                }
                withAnimation(.easeInOut(duration: 0.25)) { _ = controller.closedSpaces.remove(id) }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(SpacesListBlock.cardID(id)) }
                }
            }
            .onDisappear { swipes.closeAll() }
        }
    }

    @ViewBuilder
    private func block(_ block: SpacesListBlock) -> some View {
        switch block.kind {
        case .machine(let machine, let folded):
            MachineHeader(machine: machine, folded: folded)
                .padding(.horizontal, Self.side)
                .padding(.top, -2)
                .padding(.bottom, 10)
        case .note(let text, let icon, let machine):
            NoteRow(text: text, icon: icon) {
                if let machine { controller.newSpace(machine: .some(machine)) }
            }
            .padding(.horizontal, Self.side)
            .padding(.bottom, Self.gap)
        case .card(let space):
            SpaceCard(space: space)
                .padding(.horizontal, Self.side)
                .padding(.bottom, Self.gap)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No spaces")
                .font(.ui(17, .semibold))
                .foregroundStyle(theme.foreground)
            Text("Start one with + below.")
                .font(.ui(15))
                .foregroundStyle(theme.muted)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// An item of the list, top to bottom as drawn: with added machines, each machine's
/// group (theirs over this computer's, which is lowest): unless folded, its notes and its
/// cards, the first space lowest, then the machine's header under them; without, this
/// computer's cards alone. A machine's cards are in the drag's order while one is dragged
/// (`SpaceDrag.arranged`).
struct SpacesListBlock: Identifiable {
    enum Kind {
        case machine(Machine, folded: Bool)
        /// "Loading…", "New space there" (`machine`: its +).
        case note(String, icon: String?, machine: String?)
        case card(Space)
    }

    var kind: Kind
    var id: String

    static func cardID(_ space: String) -> String { "space:\(space)" }

    @MainActor static func blocks(controller: WorkspaceController, drag: SpaceDrag) -> [SpacesListBlock] {
        let ws = controller.workspace
        func cards(_ spaces: [Space], machine: String?) -> [SpacesListBlock] {
            drag.arranged(spaces, machine: machine).reversed().map { SpacesListBlock(kind: .card($0), id: cardID($0.id)) }
        }
        guard controller.showsMachines else { return cards(ws.spaces, machine: nil) }
        var out: [SpacesListBlock] = []
        for machine in ws.machines.reversed() {
            let folded = controller.foldedMachines.contains(machine.id)
            if !folded {
                let spaces = ws.spaces(on: machine.name)
                out += cards(spaces, machine: machine.name)
                if case .loading = machine.state {
                    out.append(SpacesListBlock(kind: .note("Loading…", icon: nil, machine: nil), id: "loading:\(machine.id)"))
                } else if spaces.isEmpty && !machine.isLocal {
                    out.append(SpacesListBlock(kind: .note("New space there", icon: "plus", machine: machine.name),
                                               id: "empty:\(machine.id)"))
                }
            }
            out.append(SpacesListBlock(kind: .machine(machine, folded: folded), id: "machine:\(machine.id)"))
        }
        return out
    }
}

// MARK: - Machine header (§4.2)

/// A machine's header under its group of cards: its icon and name, its agents' summary
/// while folded, + (a new space there), its connection's dot, the fold chevron.
struct MachineHeader: View {
    var machine: Machine
    var folded: Bool
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Icon(machine.isLocal ? "monitor" : "server", size: 14, color: theme.dim)
            Text(machine.displayName)
                .font(.ui(13))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if folded {
                StatusBadges(counts: controller.workspace.agentCounts(on: machine.name))
            }
            if case .unavailable(let why) = machine.state {
                Text(why.replacingOccurrences(of: "_", with: " "))
                    .font(.ui(12)).foregroundStyle(theme.dim).lineLimit(1)
            }
            Button { controller.newSpace(machine: .some(machine.name)) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.muted)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .hoverEffect(.highlight)
            .accessibilityLabel("New space on \(machine.displayName)")
            Circle()
                .fill(machine.isConnected ? theme.ansi(2) : theme.dim)
                .frame(width: 7, height: 7)
                .accessibilityLabel(machine.isConnected ? "Connected" : "Not connected")
            // Open, it points up, at the cards over the header.
            Icon("chevron-right", size: 13, color: theme.dim)
                .rotationEffect(.degrees(folded ? 0 : -90))
                .frame(width: 20)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) {
                if folded { controller.foldedMachines.remove(machine.id) } else { controller.foldedMachines.insert(machine.id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(machine.displayName)
        .accessibilityHint(folded ? "Shows its spaces" : "Hides its spaces")
        .accessibilityAddTraits(.isButton)
    }
}

/// A note in place of a machine's cards ("Loading…", "New space there").
struct NoteRow: View {
    var text: String
    var icon: String?
    var action: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Icon(icon, size: 13, color: theme.dim) }
            Text(text).font(.ui(14)).foregroundStyle(theme.dim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}
