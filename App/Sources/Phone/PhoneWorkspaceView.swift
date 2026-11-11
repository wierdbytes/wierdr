import SwiftUI
import UIKit
import WierdrModel

/// The iPhone layout: the list of agents/spaces (`PhoneHome`) and, pushed over
/// it, one pane at a time (`PhonePaneScreen`). Tapping a row pushes its pane;
/// the back button or a swipe from the left edge (with the finger) goes back.
///
/// Which one shows is `controller.compactColumn` (`.sidebar` = the list,
/// `.detail` = the pane), the same state the collapsed split view used, so
/// focusing a pane from anywhere (rows, quick switcher, status jumps) opens it.
struct PhoneWorkspaceView: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// How far a back swipe has moved the pane screen to the right.
    @State private var backDrag: CGFloat?
    @State private var width: CGFloat = 430

    var body: some View {
        let showing = controller.compactColumn == .detail
        let progress = showing ? 1 - (backDrag ?? 0) / max(width, 1) : 0
        ZStack {
            PhoneHome()
                .offset(x: -width * 0.28 * progress)
                .overlay {
                    Color.black.opacity(0.18 * progress)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(!showing)
                .accessibilityHidden(showing)
            if showing {
                PhonePaneScreen()
                    .offset(x: backDrag ?? 0)
                    .shadow(color: .black.opacity(backDrag == nil ? 0 : 0.25), radius: 14)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.3), value: showing)
        .background {
            BackSwipeGesture(
                enabled: showing,
                onDrag: { backDrag = max(0, $0) },
                onEnd: { projected in finishBackSwipe(projected: projected) }
            )
            .frame(width: 0, height: 0)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: showing, initial: true) { _, showing in
            if showing { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
        }
        .onChange(of: controller.workspace.spaces) { _, _ in
            // The pane on screen was closed (here, on the desktop, or its program
            // exited): back to the list rather than showing some other pane.
            guard showing, let id = requestedPane, controller.workspace.location(ofPane: id) == nil else { return }
            controller.showSidebar()
        }
    }

    /// The pane this screen asked for (not the fallback `focusedPane` resolves to).
    private var requestedPane: String? {
        let s = controller.screen.snapshot
        return s.space.flatMap { s.tabBySpace[$0] }.flatMap { s.focusByTab[$0] }
    }

    private func finishBackSwipe(projected: CGFloat) {
        if projected > width * 0.4 {
            withAnimation(.easeOut(duration: 0.2)) {
                backDrag = width
            } completion: {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    controller.showSidebar()
                    backDrag = nil
                }
            }
        } else {
            withAnimation(.snappy(duration: 0.25)) { backDrag = nil }
        }
    }
}

/// A swipe from the left edge, on the window's root view so it sees touches
/// over the terminal too; it goes before the terminal's own pans.
///
/// A pan that only takes touches starting in the leftmost 24 pt (rather than
/// `UIScreenEdgePanGestureRecognizer`): same feel, and synthesized touches
/// (UI automation) drive it too.
private struct BackSwipeGesture: UIViewRepresentable {
    var enabled: Bool
    var onDrag: (CGFloat) -> Void
    /// Where the screen would come to rest at the finger's speed.
    var onEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.pan.isEnabled != enabled { context.coordinator.pan.isEnabled = enabled }
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window?.rootViewController?.view)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        static let edgeWidth: CGFloat = 24
        var parent: BackSwipeGesture?
        let pan = UIPanGestureRecognizer()
        /// The current touch began at the edge (only then do others wait for us).
        private var atEdge = false

        override init() {
            super.init()
            pan.maximumNumberOfTouches = 1
            pan.addTarget(self, action: #selector(moved(_:)))
            pan.delegate = self
        }

        func attach(to view: UIView?) {
            guard let view, pan.view !== view else { return }
            detach()
            view.addGestureRecognizer(pan)
        }

        func detach() {
            pan.view?.removeGestureRecognizer(pan)
        }

        @objc private func moved(_ g: UIPanGestureRecognizer) {
            guard let parent, let view = g.view else { return }
            let x = g.translation(in: view).x
            switch g.state {
            case .began, .changed: parent.onDrag(x)
            case .ended: parent.onEnd(x + g.velocity(in: view).x * 0.25)
            case .cancelled, .failed: parent.onEnd(0)
            default: break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = g.view else { return false }
            let p = touch.location(in: view)
            atEdge = p.x <= view.safeAreaInsets.left + Self.edgeWidth
            return atEdge
        }

        // Only a rightward, mostly horizontal move.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let view = g.view else { return false }
            let v = pan.velocity(in: view)
            return v.x > 0 && v.x > abs(v.y)
        }

        // From the edge it goes first, as the system's back swipe does.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            atEdge
        }
    }
}
