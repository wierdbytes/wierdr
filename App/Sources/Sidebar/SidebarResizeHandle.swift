import SwiftUI

/// The sidebar column of the split view, with its resize handle and width pin.
/// (The overlay over a hidden sidebar is `SidebarOverlay`, with its own width.)
struct SidebarColumn: View {
    var range: ClosedRange<Double>
    var resizable: Bool

    @AppStorage("sidebarWidth") private var dockedWidth = SidebarResizeHandle.defaultWidth

    var body: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(range.clamp(dockedWidth))
            .background {
                if resizable { SplitColumnWidth(width: range.clamp(dockedWidth)) }
            }
            .overlay(alignment: .trailing) {
                if resizable {
                    SidebarResizeHandle(width: $dockedWidth, range: range, edge: .trailing)
                }
            }
    }
}

/// The panel's leading edge while the sidebar is docked: more room to grab the
/// sidebar's edge, from the other side.
struct DockedSidebarEdge: View {
    var range: ClosedRange<Double>

    @Environment(WorkspaceController.self) private var controller
    @AppStorage("sidebarWidth") private var dockedWidth = SidebarResizeHandle.defaultWidth

    var body: some View {
        if controller.columnVisibility != .detailOnly {
            SidebarResizeHandle(width: $dockedWidth, range: range, edge: .leading, hitWidth: 10)
        }
    }
}

/// A strip along the sidebar's edge: drag to set its width, double-tap to go
/// back to the default. Shows an accent line on the edge while dragged or
/// under the pointer.
struct SidebarResizeHandle: View {
    static let defaultWidth = 300.0
    static let minWidth = 240.0

    @Binding var width: Double
    var range: ClosedRange<Double>
    /// Which side of the strip the sidebar's edge is on.
    var edge: HorizontalEdge
    var hitWidth: CGFloat = 16

    @Environment(\.theme) private var theme
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: edge == .trailing ? .trailing : .leading) {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 2)
                    .opacity(startWidth != nil ? 1 : hovering ? 0.6 : 0)
                    .animation(.easeOut(duration: 0.15), value: startWidth != nil)
                    .animation(.easeOut(duration: 0.15), value: hovering)
            }
            // Global space: the handle moves with the edge, so local translations would jitter.
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? range.clamp(width)
                        startWidth = start
                        width = range.clamp(start + value.translation.width)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.25)) { width = Self.defaultWidth }
            }
            .onHover { hovering = $0 }
            .ignoresSafeArea(edges: .vertical)
            .accessibilityElement()
            .accessibilityLabel("Sidebar Width")
            .accessibilityValue("\(Int(range.clamp(width))) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = range.clamp(range.clamp(width) + 20)
                case .decrement: width = range.clamp(range.clamp(width) - 20)
                @unknown default: break
                }
            }
    }
}

extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

/// Holds the enclosing split view's primary column at `width`.
///
/// On iPadOS 26 the split view keeps its own column width (from its separator
/// drag, saved with the scene) and uses it over `navigationSplitViewColumnWidth`,
/// so this pins UIKit's min and max to `width`. The split view's own gestures go
/// off: its separator drag can't move a pinned column and would take touches from
/// our handle, and its edge-swipe overlay slides at that saved width, not ours
/// (`SidebarOverlay` replaces it).
struct SplitColumnWidth: UIViewRepresentable {
    var width: CGFloat

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.width = width
        probe.apply()
    }

    final class Probe: UIView {
        var width: CGFloat = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError() }

        // The sidebar column lays out as it shows, hides and resizes.
        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard width > 0, let split = splitViewController else { return }
            if split.presentsWithGesture { split.presentsWithGesture = false }
            for view in [split.view!] + split.view.subviews {
                for g in view.gestureRecognizers ?? [] where g.isEnabled && g.name?.contains("ColumnResize") == true {
                    g.isEnabled = false
                }
            }
            if split.minimumPrimaryColumnWidth != width { split.minimumPrimaryColumnWidth = width }
            if split.maximumPrimaryColumnWidth != width { split.maximumPrimaryColumnWidth = width }
        }

        private var splitViewController: UISplitViewController? {
            var responder: UIResponder? = self
            while let r = responder {
                if let split = r as? UISplitViewController { return split }
                responder = r.next
            }
            return nil
        }
    }
}
