import SwiftUI
import WierdrModel

extension WorkspaceController {
    /// An agent's tree (sub-agents, terminals, records) shows under it (unless its badge folded it).
    func showsKids(of row: SidebarRow) -> Bool {
        row.kind == .agent && !row.tree.isEmpty && !foldedAgents.contains(row.terminal?.address ?? "")
    }
}

// MARK: - Sub-agents (wierd-agents' tree)

/// The tree's columns in front of a sub-agent's row.
private enum Tree {
    static let columnWidth: CGFloat = 9
    static let columnGap: CGFloat = 4
    static let stroke: CGFloat = 1.5
    /// How far a line reaches up into the room above its row, joining its sibling's.
    static let up: CGFloat = 4
    static let elbowRadius: CGFloat = 6
}

/// The tree's columns in front of a child: `├`/`└` an elbow into its first
/// line's middle (`mid`); `├` and `│` go on down to the row's end; every line
/// reaches up into the room above, so siblings join into one line.
///
/// `upward`: the tree upside down, for a list drawn bottom up (the iPhone's, Go to),
/// where a child is over its parent: the elbow comes up from below into `mid` (`┌`),
/// `├` and `│` go on up to the row's top, and every line reaches down into the room
/// below instead. `mid` is still from the row's top.
struct TreeLines: View {
    var lines: [SubAgent.Line]
    var height: CGFloat
    var mid: CGFloat
    var upward = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Tree.columnGap) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                column(line)
                    .stroke(theme.input, style: StrokeStyle(lineWidth: Tree.stroke, lineCap: .butt))
                    .frame(width: Tree.columnWidth, height: height)
            }
        }
        .padding(.trailing, Tree.columnGap)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func column(_ line: SubAgent.Line) -> Path {
        upward ? upwardColumn(line) : downwardColumn(line)
    }

    private func downwardColumn(_ line: SubAgent.Line) -> Path {
        var p = Path()
        let x = Tree.stroke / 2
        let top = -Tree.up
        switch line {
        case .blank:
            break
        case .pipe:
            p.move(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x, y: height))
        case .tee, .elbow:
            let y = mid - Tree.stroke / 2
            p.move(to: CGPoint(x: x, y: top))
            p.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: Tree.columnWidth, y: y), radius: Tree.elbowRadius)
            p.addLine(to: CGPoint(x: Tree.columnWidth, y: y))
            if line == .tee {
                p.move(to: CGPoint(x: x, y: mid - Tree.elbowRadius))
                p.addLine(to: CGPoint(x: x, y: height))
            }
        }
        return p
    }

    private func upwardColumn(_ line: SubAgent.Line) -> Path {
        var p = Path()
        let x = Tree.stroke / 2
        let bottom = height + Tree.up
        switch line {
        case .blank:
            break
        case .pipe:
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: bottom))
        case .tee, .elbow:
            let y = mid - Tree.stroke / 2
            p.move(to: CGPoint(x: x, y: bottom))
            p.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: Tree.columnWidth, y: y), radius: Tree.elbowRadius)
            p.addLine(to: CGPoint(x: Tree.columnWidth, y: y))
            if line == .tee {
                p.move(to: CGPoint(x: x, y: mid + Tree.elbowRadius))
                p.addLine(to: CGPoint(x: x, y: 0))
            }
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
