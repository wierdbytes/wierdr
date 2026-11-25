import UIKit
import UIKit.UIGestureRecognizerSubclass
import QuartzCore

/// Inertia for the scrolls a program takes (pi, Claude Code, vim with the mouse, less on the
/// alternate screen). SwiftTerm turns a finger's one-finger drag and a trackpad's two-finger
/// scroll into wheel reports (or cursor keys) only while the fingers move, so the program stopped
/// dead when they lifted; the local scrollback is a `UIScrollView` and coasts on its own.
///
/// After a flick the travel goes on, slowing as a `UIScrollView` does (`.normal`: 0.998 a
/// millisecond), and is handed to SwiftTerm's own handler (`panMouseHandler:` for a finger,
/// `handlePointerScroll:` for a trackpad) with a stand-in recognizer, so routing, the cell grid
/// and its report budget (100 a second) stay SwiftTerm's. A new scroll, a touch on the terminal
/// or the terminal leaving the window stops it (`WierdrTerminalView`: the touch that stopped it
/// is no tap). A mouse wheel's notches don't coast. Settings → Terminal turns it off
/// (`enabledKey`); the shell's history coasts either way.
@MainActor
final class ScrollCoast: NSObject {
    /// `UserDefaults` key of Settings → Terminal → Scroll Inertia in Programs (absent: on).
    nonisolated static let enabledKey = "terminalScrollInertia"
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private enum Source {
        case finger, trackpad

        var action: Selector {
            switch self {
            case .finger: NSSelectorFromString("panMouseHandler:")
            case .trackpad: NSSelectorFromString("handlePointerScroll:")
            }
        }
    }

    /// `UIScrollView.DecelerationRate.normal`: the speed kept per millisecond.
    private static let rate: Double = 0.998
    /// Slower than this (pt/s) it doesn't start, or ends: what's left is under half a line.
    private static let minimumSpeed: Double = 20
    /// Held still this long (s) before lifting: no coast. A pan's velocity at its end is that of
    /// its last move, however long ago.
    private static let stillness: CFTimeInterval = 0.1

    private weak var host: UIView?
    private var link: CADisplayLink?
    private var source = Source.finger
    private var velocity: Double = 0
    private var startTime: CFTimeInterval = 0
    /// Travel handed to SwiftTerm so far (pt).
    private var sent: Double = 0
    /// When and where (in the window) the scroll last moved.
    private var lastMove: CFTimeInterval = 0
    private var lastPlace: CGPoint = .zero
    private let step = CoastStep(target: nil, action: nil)

    /// Every recognizer added to the terminal passes here (`addGestureRecognizer`); SwiftTerm's
    /// program scrolls get a second target. The finger's one is added each time a program starts
    /// taking scrolls (`enableMousePanGesture`: one touch at most); the pointer's two, once
    /// (no touches; continuous: a trackpad, discrete: a mouse wheel). Subclasses (the scroll
    /// view's own pan) aren't SwiftTerm's.
    func watch(_ g: UIGestureRecognizer, on view: UIView) {
        guard let pan = g as? UIPanGestureRecognizer, type(of: pan) == UIPanGestureRecognizer.self else { return }
        host = view
        if pan.allowedTouchTypes.isEmpty {
            if pan.allowedScrollTypesMask == .continuous {
                watch(pan, .trackpad, #selector(trackpadScrolled(_:)))
            } else {
                pan.addTarget(self, action: #selector(wheelScrolled(_:)))
            }
        } else if pan.maximumNumberOfTouches == 1 {
            watch(pan, .finger, #selector(fingerScrolled(_:)))
        }
    }

    private func watch(_ pan: UIPanGestureRecognizer, _ source: Source, _ action: Selector) {
        // A SwiftTerm update renamed its handler: no coasting until this follows it.
        assert(host?.responds(to: source.action) == true, "SwiftTerm has no \(source.action)")
        pan.addTarget(self, action: action)
    }

    @objc private func fingerScrolled(_ g: UIPanGestureRecognizer) { follow(g, .finger) }
    @objc private func trackpadScrolled(_ g: UIPanGestureRecognizer) { follow(g, .trackpad) }
    @objc private func wheelScrolled(_ g: UIPanGestureRecognizer) {
        if g.state == .began { stop() }
    }

    private func follow(_ g: UIPanGestureRecognizer, _ source: Source) {
        let now = CACurrentMediaTime()
        // A trackpad's pan is at the pointer, which stays: each change of it is a move.
        let place = source == .finger ? g.location(in: nil) : .zero
        switch g.state {
        case .began:
            stop()
            (lastMove, lastPlace) = (now, place)
        case .changed:
            if source == .trackpad || place != lastPlace { (lastMove, lastPlace) = (now, place) }
        case .ended:
            guard let view = g.view else { return }
            if place != lastPlace { lastMove = now }
            guard now - lastMove < Self.stillness else { return }
            let p = g.location(in: view)
            start(source, velocity: g.velocity(in: view).y,
                  // From the view's visible top left: its bounds move as the content does.
                  at: CGPoint(x: p.x - view.bounds.minX, y: p.y - view.bounds.minY),
                  modifiers: g.modifierFlags)
        default:
            break
        }
    }

    private func start(_ source: Source, velocity: Double, at place: CGPoint, modifiers: UIKeyModifierFlags) {
        stop()
        guard Self.isEnabled, abs(velocity) > Self.minimumSpeed, let host, host.window != nil,
              host.responds(to: source.action) else { return }
        self.source = source
        self.velocity = velocity
        startTime = CACurrentMediaTime()
        sent = 0
        step.host = host
        step.place = place
        step.flags = modifiers
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Whole lines go out, at most a few a frame.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops a coast; whether one was running.
    @discardableResult
    func stop() -> Bool {
        guard let link else { return false }
        link.invalidate()
        self.link = nil
        return true
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let host, host.window != nil else { stop(); return }
        // v(t) = v₀·rateᵗ (t in ms); the travel is its integral, so a late frame catches up.
        let ms = max(0, link.targetTimestamp - startTime) * 1000
        let kept = pow(Self.rate, ms)
        let travelled = velocity / 1000 * (kept - 1) / log(Self.rate)
        let delta = travelled - sent
        sent = travelled
        feed(delta, .changed, to: host)
        if abs(velocity * kept) < Self.minimumSpeed {
            feed(0, .ended, to: host) // SwiftTerm drops the fraction of a line it banked
            stop()
        }
    }

    private func feed(_ dy: Double, _ state: UIGestureRecognizer.State, to host: UIView) {
        step.state = state
        step.travel = CGPoint(x: 0, y: dy)
        _ = host.perform(source.action, with: step)
    }
}

/// Stands in for SwiftTerm's scroll recognizer while a scroll coasts: its handler reads the
/// state, the travel (and zeroes it), the place and the modifiers from the recognizer it gets.
/// Never added to a view.
private final class CoastStep: UIPanGestureRecognizer {
    weak var host: UIView?
    /// Where the scroll was, from the host's visible top left.
    var place: CGPoint = .zero
    var flags: UIKeyModifierFlags = []
    var travel: CGPoint = .zero
    private var phase: UIGestureRecognizer.State = .possible

    override var view: UIView? { host }
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override var modifierFlags: UIKeyModifierFlags { flags }

    override func translation(in view: UIView?) -> CGPoint { travel }
    override func setTranslation(_ translation: CGPoint, in view: UIView?) { travel = translation }
    override func velocity(in view: UIView?) -> CGPoint { .zero }

    override func location(in view: UIView?) -> CGPoint {
        guard let host else { return place }
        let p = CGPoint(x: place.x + host.bounds.minX, y: place.y + host.bounds.minY)
        return view === host ? p : host.convert(p, to: view)
    }
}
