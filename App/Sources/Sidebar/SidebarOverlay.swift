import SwiftUI
import UIKit

/// The sidebar slid over the panel while the docked one is hidden: a swipe from
/// the left edge pulls it out with the finger, a swipe left (anywhere, rows
/// included) or a tap on the dimmed panel puts it back. Its width is
/// its own, set by its edge like the docked one.
///
/// Ours rather than the split view's: that one slides at the width the system
/// keeps for the column, not ours, and jumps to ours at the end.
struct SidebarOverlay: View {
    var range: ClosedRange<Double>

    @Environment(WorkspaceController.self) private var controller
    @AppStorage("sidebarOverlayWidth") private var storedWidth = SidebarResizeHandle.defaultWidth
    /// How much of the sidebar shows while a finger moves it, 0...width.
    @State private var dragged: CGFloat?

    var body: some View {
        let width = CGFloat(range.clamp(storedWidth))
        let shown = dragged ?? (controller.sidebarOverlay ? width : 0)
        let hidden = controller.columnVisibility == .detailOnly
        ZStack(alignment: .leading) {
            if shown > 0 {
                Color.black.opacity(0.3 * min(1, shown / width))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { controller.closeSidebarOverlay() }
                    .transition(.opacity)
                    .accessibilityLabel("Close Sidebar")
                    .accessibilityAddTraits(.isButton)
                SidebarView()
                    .frame(width: width)
                    .overlay(alignment: .trailing) { Hairline(axis: .vertical).ignoresSafeArea() }
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(width: $storedWidth, range: range, edge: .trailing)
                    }
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.25), radius: 16)
                    .offset(x: shown - width)
                    .transition(.move(edge: .leading))
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { controller.closeSidebarOverlay() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            SidebarOverlayGestures(
                canOpen: hidden && !controller.sidebarOverlay,
                isOpen: controller.sidebarOverlay,
                width: width,
                onDrag: { dragged = min(max($0, 0), width) },
                onEnd: { projected in
                    withAnimation(.easeOut(duration: 0.22)) {
                        controller.sidebarOverlay = projected > width / 2
                        dragged = nil
                    }
                }
            )
            .frame(width: 0, height: 0)
        }
        .onChange(of: hidden) { _, hidden in
            if !hidden {
                controller.sidebarOverlay = false
                dragged = nil
            }
        }
    }
}

/// The overlay's pans, on the window's root view so they see touches anywhere:
/// the swipe from the left edge that pulls the sidebar out and the swipe left
/// that puts it back. Both report how much of the sidebar shows.
private struct SidebarOverlayGestures: UIViewRepresentable {
    var canOpen: Bool
    var isOpen: Bool
    var width: CGFloat
    var onDrag: (CGFloat) -> Void
    /// Where the sidebar's edge would come to rest at the finger's speed.
    var onEnd: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.open.isEnabled != canOpen { c.open.isEnabled = canOpen }
        if c.close.isEnabled != isOpen { c.close.isEnabled = isOpen }
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
        var parent: SidebarOverlayGestures?
        let open = UIScreenEdgePanGestureRecognizer()
        let close = UIPanGestureRecognizer()

        override init() {
            super.init()
            open.edges = .left
            open.addTarget(self, action: #selector(opening(_:)))
            close.addTarget(self, action: #selector(closing(_:)))
            open.delegate = self
            close.delegate = self
        }

        func attach(to view: UIView?) {
            guard let view, open.view !== view else { return }
            detach()
            view.addGestureRecognizer(open)
            view.addGestureRecognizer(close)
        }

        func detach() {
            open.view?.removeGestureRecognizer(open)
            close.view?.removeGestureRecognizer(close)
        }

        @objc private func opening(_ pan: UIPanGestureRecognizer) {
            track(pan, from: 0)
        }

        @objc private func closing(_ pan: UIPanGestureRecognizer) {
            track(pan, from: parent?.width ?? 0)
        }

        private func track(_ pan: UIPanGestureRecognizer, from start: CGFloat) {
            guard let parent, let view = pan.view else { return }
            let x = start + pan.translation(in: view).x
            switch pan.state {
            case .began, .changed: parent.onDrag(x)
            case .ended: parent.onEnd(x + pan.velocity(in: view).x * 0.2)
            case .cancelled, .failed: parent.onEnd(start)
            default: break
            }
        }

        // Closing: only a mostly-leftward swipe, and not on the resize handle.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === close, let view = g.view else { return true }
            let v = close.velocity(in: view)
            return v.x < 0 && abs(v.x) > abs(v.y)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard g === close, let parent, let view = g.view else { return true }
            let x = touch.location(in: view).x
            return x < parent.width - 20 || x > parent.width + 4
        }

        // The edge swipe goes first, as the system's does. Closing goes before a row's
        // own swipe: leftward it closes, rightward it fails and the row's actions come.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g === open || (isInList(other) && !isScrollPan(other))
        }

        // Scrolling may run along with closing.

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g === close && isScrollPan(other)
        }

        private func isScrollPan(_ g: UIGestureRecognizer) -> Bool {
            (g.view as? UIScrollView)?.panGestureRecognizer === g
        }

        private func isInList(_ g: UIGestureRecognizer) -> Bool {
            var view = g.view
            while let v = view {
                if v is UICollectionView { return true }
                view = v.superview
            }
            return false
        }
    }
}
