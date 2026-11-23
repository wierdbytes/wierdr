import SwiftUI
import WierdrModel

extension WorkspaceController {
    /// What of an agent's tree shows under its row (`TreeFolds.shown`): its sub-agents
    /// unless its bot chip folded them, each agent's terminals once its `>_` chip opened
    /// them; `forced` (the agents panel's matches) whatever the folds.
    func shownTree(of row: SidebarRow, forced: Set<String> = []) -> [TreeNode] {
        guard row.kind == .agent, !row.tree.isEmpty else { return [] }
        let agentsOpen = !foldedAgents.contains(row.terminal?.address ?? "")
        return TreeFolds.shown(row.tree, agentsOpen: agentsOpen,
                               terminalsOpen: { self.openTerminals.contains($0) }, forced: forced)
    }

    /// An agent row's sub-agents show (its bot chip isn't folded).
    func showsKids(of address: String) -> Bool { !foldedAgents.contains(address) }

    /// Folds an agent row's sub-agents in or out (its bot chip).
    func toggleKids(of address: String) {
        withAnimation(SpaceCard.fold) {
            if foldedAgents.contains(address) { foldedAgents.remove(address) } else { foldedAgents.insert(address) }
        }
    }

    /// Shows or hides the terminals an agent or sub-agent started (its `>_` chip).
    func toggleTerminals(of address: String) {
        withAnimation(SpaceCard.fold) {
            if openTerminals.contains(address) { openTerminals.remove(address) } else { openTerminals.insert(address) }
        }
    }

    /// Agents left without terminals fold theirs again: the next ones they start come folded.
    func foldEndedTerminals(owners: Set<String>) {
        let gone = openTerminals.subtracting(owners)
        if !gone.isEmpty { openTerminals.subtract(gone) }
    }
}

// MARK: - Sub-agents (wierd-agents' tree)

/// The tree's geometry in a row of the list (the rows touch, so its lines join): each
/// level's marks (a sub-agent's status dot, a terminal's icon) are centred on one axis,
/// `step` right of their parent's; the root's is its context ring's (`PhoneAgentRowContent`).
/// A parent's line runs down its axis. A mark sits in the middle of its column, between its
/// elbow's end and its text, as far from either (`span`); the text of both lines starts
/// past it (a sub-agent's context ring under its title's first letter, as an agent's).
enum Tree {
    /// The root's mark: its context ring.
    static let indicator: CGFloat = PhoneContextRing.size + PhoneContextRing.line
    /// From a mark's axis to its elbow's end on the left and to its text on the right: the
    /// status dot (7 pt) 8 pt from either, a terminal's icon (15 pt) 4 pt.
    static let span: CGFloat = 11.5
    /// A mark's column: its elbow's end to its text.
    static let mark: CGFloat = 2 * span
    static let step: CGFloat = 20
    /// A row's text from its marks' column's leading edge.
    static let textLeading: CGFloat = mark
    /// Between a line coming down to a mark and the mark.
    static let markGap: CGFloat = 4
    static let stroke: CGFloat = 1.5
    static let elbowRadius: CGFloat = 6
    /// How far the root's line reaches into its row (over its title).
    static let rootStub: CGFloat = 4

    /// The axis of depth `depth`'s marks (0: the root's ring), from the row's leading edge.
    static func axis(_ depth: Int) -> CGFloat {
        PhoneRowMetrics.inset + indicator / 2 + CGFloat(depth) * step
    }

    /// Where a row's mark column starts.
    static func leading(_ depth: Int) -> CGFloat { axis(depth) - mark / 2 }
}

/// The tree's lines in a child's row, over the whole row and drawn bottom up (the list is:
/// a child is over its parent): its own elbow comes up its parent's axis from the row's
/// bottom and turns right into its mark at `mid` (`┌`; with a sibling over it the line goes
/// on up, `├`); an ancestor's line with siblings still to come runs through (`│`). With
/// children over it (`stub`), its own axis' line comes down from its top to its mark.
struct TreeLines: View {
    var lines: [SubAgent.Line]
    var height: CGFloat
    /// Its first line's middle, from the row's top: where its elbow turns into its mark.
    var mid: CGFloat
    /// Its children's line comes down to this y (its mark's top, less the gap); nil: none.
    var stub: CGFloat? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        path
            .stroke(theme.input, style: StrokeStyle(lineWidth: Tree.stroke, lineCap: .butt))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var path: Path {
        var p = Path()
        let depth = lines.count
        for (j, line) in lines.enumerated() {
            let x = Tree.axis(j)
            switch line {
            case .blank:
                break
            case .pipe:
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: height))
            case .tee, .elbow:
                let end = Tree.axis(j + 1) - Tree.span
                p.move(to: CGPoint(x: x, y: height))
                p.addArc(tangent1End: CGPoint(x: x, y: mid), tangent2End: CGPoint(x: end, y: mid), radius: Tree.elbowRadius)
                p.addLine(to: CGPoint(x: end, y: mid))
                if line == .tee {
                    p.move(to: CGPoint(x: x, y: mid + Tree.elbowRadius))
                    p.addLine(to: CGPoint(x: x, y: 0))
                }
            }
        }
        if let stub, stub > 0 {
            let x = Tree.axis(depth)
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: stub))
        }
        return p
    }
}

extension WorkspaceController {
    /// A child row is lit while it's shown: looked at, or its pane (kept) focused.
    func isShown(_ kid: SubAgent) -> Bool {
        peek == kid.terminal.address || (kid.paneID != nil && focusedPane?.id == kid.paneID)
    }

    /// The row with the focus ring: the focused pane's, but on the iPhone, while a
    /// sub-agent shows in its place, none (the sub-agent's row has it).
    var ringedPane: String? {
        singlePane && peek != nil ? nil : focusedPane?.id
    }

    /// A child row wears the focus ring while it's what the screen shows: its kept
    /// pane is focused, or (iPhone) it shows in its parent's place. The iPad's
    /// window over the panel leaves the ring on the focused pane's row.
    func isRinged(_ kid: SubAgent) -> Bool {
        if singlePane, let peek { return peek == kid.terminal.address }
        return kid.paneID != nil && kid.paneID == focusedPane?.id
    }
}
