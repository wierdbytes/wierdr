import SwiftUI
import UIKit

/// A place on screen the tour points at (`TutorialStep.anchor`, `also`, `spotlight`,
/// `near`, a phase's `pointer`). Views mark themselves with `tutorialAnchor(_:)`; the
/// tour's overlay finds them by their UIKit marker (`TutorialAnchors`), wherever they are:
/// the iPhone's screens and the list's blocks are each in their own hosting controller,
/// moved by Core Animation, so no SwiftUI preference or coordinate space reaches from them
/// to the overlay's window.
enum TutorialAnchor: Hashable {
    // The host list.
    case addHost, tryDemo
    // The list screen.
    /// The list's room between the status bar and the header (the pull to Go to).
    case list
    case card(String), spaceHeader(String)
    /// An agent's row (its terminal's address).
    case agentRow(String)
    /// The rows of an agent's tree (its address): many views, one place (`TutorialAnchors.union`).
    case tree(String)
    /// A row's swipe button (`PhoneSwipeAction.id`: pin, unread, …), while the row is open.
    case swipeButton(String)
    case statusRing, limits
    /// The limits' popover, while it's out.
    case limitsPopover
    // The pane screen.
    case paneTitle, paneBack, terminal, composer
    /// The key panel, and its ⏎.
    case keys, keyEnter
}

extension View {
    /// Marks this view as `anchor` for the tour: only while a step points at it (or lets a
    /// finger through it), so it costs nothing otherwise.
    func tutorialAnchor(_ anchor: TutorialAnchor) -> some View {
        modifier(TutorialAnchorModifier(anchor: anchor))
    }
}

private struct TutorialAnchorModifier: ViewModifier {
    let anchor: TutorialAnchor
    @Environment(\.tutorialAnchorsOff) private var off

    func body(content: Content) -> some View {
        // Behind the content, its size: the content's identity doesn't change with the marker.
        content.background {
            if !off, Tutorial.shared.marks(anchor) { TutorialMarker(anchor: anchor) }
        }
    }
}

private struct TutorialAnchorsOffKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Pictures drawn afresh (`ImageRenderer`: the list's lifted rows and cards) have no
    /// markers: it draws a UIKit view as a placeholder.
    var tutorialAnchorsOff: Bool {
        get { self[TutorialAnchorsOffKey.self] }
        set { self[TutorialAnchorsOffKey.self] = newValue }
    }
}

/// An empty UIKit view behind a marked view, registered with `TutorialAnchors`.
private struct TutorialMarker: UIViewRepresentable {
    let anchor: TutorialAnchor

    func makeUIView(context: Context) -> TutorialMarkerView {
        let view = TutorialMarkerView()
        view.anchor = anchor
        return view
    }

    func updateUIView(_ view: TutorialMarkerView, context: Context) {
        view.anchor = anchor
    }

    static func dismantleUIView(_ view: TutorialMarkerView, coordinator: ()) {
        view.anchor = nil
    }
}

final class TutorialMarkerView: UIView {
    var anchor: TutorialAnchor? {
        didSet {
            guard anchor != oldValue else { return }
            TutorialAnchors.shared.unregister(self)
            if let anchor { TutorialAnchors.shared.register(self, as: anchor) }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Where the marked views are on screen.
@MainActor
final class TutorialAnchors {
    static let shared = TutorialAnchors()

    private final class Entry {
        let anchor: TutorialAnchor
        weak var view: UIView?
        init(_ anchor: TutorialAnchor, _ view: UIView) { self.anchor = anchor; self.view = view }
    }

    private var entries: [Entry] = []

    func register(_ view: UIView, as anchor: TutorialAnchor) {
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(anchor, view))
    }

    func unregister(_ view: UIView) {
        entries.removeAll { $0.view == nil || $0.view === view }
    }

    /// The anchor's frame on screen (the windows fill the screen: window coordinates), as
    /// drawn now (mid-animation too): the latest marker that is in a window, not hidden
    /// and mostly on screen. Nil when none is.
    func frame(_ anchor: TutorialAnchor) -> CGRect? {
        for entry in entries.reversed() where entry.anchor == anchor {
            if let rect = Self.shownFrame(entry.view) { return rect }
        }
        return nil
    }

    /// All its markers shown, as one rectangle (an agent's tree is a row each). Nil when none is.
    func union(_ anchor: TutorialAnchor) -> CGRect? {
        entries.filter { $0.anchor == anchor }.compactMap { Self.shownFrame($0.view) }
            .reduce(nil) { (all: CGRect?, rect: CGRect) in all.map { $0.union(rect) } ?? rect }
    }

    private static func shownFrame(_ view: UIView?) -> CGRect? {
        guard let view, let window = view.window, !window.isHidden, isShown(view) else { return nil }
        let rect = drawnFrame(view, in: window)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let seen = rect.intersection(window.bounds)
        guard !seen.isNull, seen.width * seen.height >= 0.4 * rect.width * rect.height else { return nil }
        return rect
    }

    /// Hidden or transparent up its chain: not shown.
    private static func isShown(_ view: UIView) -> Bool {
        var v: UIView? = view
        while let current = v {
            if current.isHidden || current.alpha < 0.02 { return false }
            v = current.superview
        }
        return true
    }

    /// Its frame in its window as the render server draws it now: through the presentation
    /// layers, so a screen being pushed or a list being scrolled is followed frame by frame.
    private static func drawnFrame(_ view: UIView, in window: UIWindow) -> CGRect {
        if let layer = view.layer.presentation(), let root = window.layer.presentation() {
            return layer.convert(layer.bounds, to: root)
        }
        return view.convert(view.bounds, to: window)
    }
}
