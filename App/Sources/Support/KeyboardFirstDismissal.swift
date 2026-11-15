import SwiftUI
import UIKit

/// A sheet whose keyboard goes before it does: a swipe down that starts while
/// the keyboard is up puts the keyboard away (`hide`) and leaves the sheet
/// where it is; with the keyboard down, a swipe closes it as sheets do. A tap
/// beside the sheet (the iPad) still closes it at once. Put it in the sheet's
/// content (a background).
///
/// UIKit asks the sheet's presentation controller's delegate whether a swipe
/// may close it (`presentationControllerShouldDismiss`); SwiftUI owns that
/// delegate, so it's wrapped (`Guard`, everything else goes on to SwiftUI's).
/// Whether a finger on the sheet came down while the keyboard was up is watched
/// by a gesture recognizer on the sheet that recognizes nothing (`TouchWatcher`):
/// the swipe that put the keyboard away (a scroll does) doesn't close it either.
struct KeyboardFirstDismissal: UIViewRepresentable {
    var hide: () -> Void

    func makeCoordinator() -> Guard { Guard() }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.guard = context.coordinator
        context.coordinator.hide = hide
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        context.coordinator.hide = hide
        probe.install()
    }

    static func dismantleUIView(_ probe: Probe, coordinator: Guard) {
        coordinator.uninstall()
    }

    /// Finds the sheet once it's in a window.
    final class Probe: UIView {
        weak var `guard`: Guard?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            install()
        }

        func install() {
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let r = responder, !(r is UIViewController) { responder = r.next }
            guard var top = responder as? UIViewController else { return }
            while let parent = top.parent { top = parent }
            // Only a presented controller: asking another for its presentation controller makes one.
            guard top.presentingViewController != nil else { return }
            self.guard?.attach(to: top.presentationController)
        }
    }

    @MainActor
    final class Guard: NSObject, UIAdaptivePresentationControllerDelegate {
        var hide: () -> Void = {}
        private weak var presentation: UIPresentationController?
        private weak var original: UIAdaptivePresentationControllerDelegate?
        private var watcher: TouchWatcher?
        private var observers: [NSObjectProtocol] = []
        /// The keyboard is up (a hardware keyboard's bar doesn't count).
        private var keyboardShown = false
        /// A finger on the sheet came down while the keyboard was up (held a moment after it lifts).
        private var held = false
        private var touchGeneration = 0

        override init() {
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                MainActor.assumeIsolated { self?.keyboardMoved(to: end) }
            })
            observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardShown = false }
            })
        }

        private func keyboardMoved(to end: CGRect) {
            let screen = UIScreen.main.bounds
            keyboardShown = end.height > 100 && end.intersection(screen).height > 100
        }

        func attach(to presentation: UIPresentationController?) {
            guard let presentation else { return }
            if presentation.delegate !== self {
                original = presentation.delegate
                presentation.delegate = self
            }
            self.presentation = presentation
            if watcher == nil, let view = presentation.presentedView {
                let w = TouchWatcher { [weak self] down in self?.touch(down: down) }
                view.addGestureRecognizer(w)
                watcher = w
            }
        }

        func uninstall() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let watcher { watcher.view?.removeGestureRecognizer(watcher) }
            watcher = nil
            if let presentation, presentation.delegate === self { presentation.delegate = original }
        }

        private func touch(down: Bool) {
            touchGeneration += 1
            if down {
                held = keyboardShown
                return
            }
            // A moment after the finger lifts: UIKit may ask as the swipe ends.
            let generation = touchGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.touchGeneration == generation else { return }
                self.held = false
            }
        }

        // MARK: The delegate

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            if held {
                hide()
                return false
            }
            return original?.presentationControllerShouldDismiss?(presentationController) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }

    /// Tells when fingers come down on the sheet and when the last one lifts;
    /// recognizes nothing, holds nothing up, can't be stopped by the others.
    final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let changed: (Bool) -> Void

        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        /// Fingers down on the sheet.
        private var down = 0

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if down == 0 { changed(true) }
            down += touches.count
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches.count) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches.count) }

        private func lifted(_ count: Int) {
            down = max(0, down - count)
            // Failing ends the sequence (`reset` follows).
            if down == 0 { state = .failed }
        }

        override func reset() {
            super.reset()
            down = 0
            changed(false)
        }

        override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { false }
        override func canPrevent(_ prevented: UIGestureRecognizer) -> Bool { false }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
