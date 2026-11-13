import SwiftUI
import UIKit

/// How much of the window's bottom the keyboard covers, for the iPad's sidebar
/// and panel (`keyboardCoverPadding`), measured from the terminal's key bar.
///
/// Not SwiftUI's keyboard safe area: with the floating keyboard the key bar
/// (the terminal's `inputAccessoryView`) stays at the bottom while iPadOS gives
/// SwiftUI some docked keyboard's height or more (seen: 740 pt and moving with
/// the floating keyboard), which squeezed the panels into the top of the
/// screen. The keyboard frames in the notifications don't help either (when
/// the floating keyboard goes, the last one is a 50-pt strip at the bottom
/// that never goes away). The key bar is always where the cover starts: just
/// above a docked keyboard, at the bottom under a floating one or with a
/// hardware keyboard. The message field carries an empty accessory for the
/// same reason (`ComposerTextView.EmptyAccessory`). With neither having the keyboard
/// nothing is covered (the split view has no other text fields; sheets and
/// alerts that do sit above it).
@MainActor
@Observable
final class KeyboardCover {
    static let shared = KeyboardCover()

    /// Points covered above the window's bottom safe area (0: nothing).
    private(set) var height: CGFloat = 0

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let will: [Notification.Name] = [
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification,
        ]
        let did: [Notification.Name] = [
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification,
        ]
        for name in will + did {
            let isWill = will.contains(name)
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
                MainActor.assumeIsolated {
                    KeyboardCover.shared.keyboardChanged(duration: isWill ? duration : 0)
                }
            })
        }
    }

    private func keyboardChanged(duration: Double) {
        measure(duration: duration)
        // The key bar may get to its place only after the notification (seen when the keyboard docks).
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
            self?.measure(duration: 0.15)
        }
    }

    private func measure(duration: Double) {
        var covered: CGFloat = 0
        var accessory: (bar: UIView, window: UIWindow)?
        if let owner = WierdrTerminalView.keyboardOwner, owner.isFirstResponder, let window = owner.window,
           let bar = owner.inputAccessoryView {
            accessory = (bar, window)
        } else {
            accessory = ComposerUITextView.activeAccessory
        }
        if let (bar, window) = accessory, bar.window != nil, !bar.isHidden, bar.alpha > 0 {
            // The bar is in the keyboard's own window: go through the screen.
            let screen = window.screen.coordinateSpace
            let top = window.convert(bar.convert(bar.bounds, to: screen), from: screen).minY
            // Above the bottom safe area (the home indicator's), which views keep clear anyway.
            covered = min(max(window.bounds.maxY - window.safeAreaInsets.bottom - top, 0), window.bounds.height)
        }
        guard covered != height else { return }
        if duration > 0 {
            withAnimation(.easeOut(duration: duration)) { height = covered }
        } else {
            height = covered
        }
    }
}

extension View {
    /// Keeps the view's content above the keyboard and the key bar as
    /// `KeyboardCover` measures them, instead of SwiftUI's keyboard safe area.
    func keyboardCoverPadding() -> some View { modifier(KeyboardCoverPadding()) }
}

private struct KeyboardCoverPadding: ViewModifier {
    func body(content: Content) -> some View {
        BottomInsetLayout(inset: KeyboardCover.shared.height) {
            content
        }
        .background { NoKeyboardSafeArea().allowsHitTesting(false) }
        .ignoresSafeArea(.keyboard)
    }
}

/// Turns SwiftUI's keyboard safe area off in the hosting controllers above it
/// (the split view's column and the window's), back on when it goes. Ignoring
/// it in the view is not enough: views inside still see the keyboard's region,
/// and a `List` that overlaps it stretches its scroll view down to the
/// window's bottom (under the views below it, which then show its rows).
private struct NoKeyboardSafeArea: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {}
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.restore() }

    final class Anchor: UIView {
        /// The hosts this anchor turned the region off in.
        private var held: [ObjectIdentifier] = []
        /// Per host: how many anchors want its keyboard region off.
        private static var holds: [ObjectIdentifier: (host: WeakHost, count: Int)] = [:]

        override func didMoveToWindow() {
            super.didMoveToWindow()
            restore()
            guard window != nil else { return }
            var responder: UIResponder? = next
            while let r = responder {
                if let host = r as? SafeAreaRegionsHost {
                    let id = ObjectIdentifier(host)
                    var hold = Self.holds[id] ?? (WeakHost(host), 0)
                    hold.count += 1
                    Self.holds[id] = hold
                    held.append(id)
                    host.safeAreaRegions.remove(.keyboard)
                }
                responder = r.next
            }
        }

        func restore() {
            for id in held {
                guard var hold = Self.holds[id] else { continue }
                hold.count -= 1
                if hold.count > 0 {
                    Self.holds[id] = hold
                } else {
                    Self.holds[id] = nil
                    hold.host.host?.safeAreaRegions.insert(.keyboard)
                }
            }
            held = []
        }
    }

    private struct WeakHost {
        weak var host: (any SafeAreaRegionsHost)?
        init(_ host: any SafeAreaRegionsHost) { self.host = host }
    }
}

/// `UIHostingController.safeAreaRegions` for any `Content`.
@MainActor
private protocol SafeAreaRegionsHost: AnyObject {
    var safeAreaRegions: SafeAreaRegions { get set }
}

extension UIHostingController: SafeAreaRegionsHost {}

/// Lays its view out in all of its space but `inset` at the bottom, and takes
/// all of that space whatever size the view comes back with (with a bottom
/// padding instead, a sidebar that would not shrink that far grew the column
/// past the screen's top).
private struct BottomInsetLayout: Layout {
    var inset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let inner = subviews.first?.sizeThatFits(inner(proposal)) ?? .zero
        return CGSize(width: proposal.width ?? inner.width, height: proposal.height ?? inner.height + inset)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - inset)))
    }

    private func inner(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: proposal.height.map { max(0, $0 - inset) })
    }
}
