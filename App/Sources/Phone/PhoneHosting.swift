import QuartzCore
import SwiftUI
import UIKit
import WierdrModel

// MARK: - Hosted screens

/// What a screen the iPhone moves by Core Animation (the list, the pane screen, Go to)
/// needs from the app's environment. Each such screen is a SwiftUI view in its own
/// `UIHostingController` under a UIKit container (`PhoneNavController`), and SwiftUI
/// doesn't carry its environment into those, so
/// it is copied over here; the system's own values (color scheme, size classes, text
/// size, scene phase) come with the UIKit traits.
///
/// And the safe area the screen lays out in (`insets`): the hosting controllers ignore
/// UIKit's (`safeAreaRegions = []`), which follows a view's place on screen (one moved
/// half off the screen gets an inset there, and its content would be laid out again at
/// every step of the move); the container, which doesn't move, hands down its own.
@MainActor
@Observable
final class PhoneHostContext {
    /// The safe area of the hosted screen (its container's).
    var insets = EdgeInsets()
    private(set) var theme: Theme
    private(set) var homeFolder: String?
    private(set) var isCompactLayout: Bool

    @ObservationIgnored let controller: WorkspaceController
    @ObservationIgnored let app: AppModel?
    @ObservationIgnored let connector: LiveConnector?
    // Values with no equality that don't change while a session is open.
    @ObservationIgnored let services: AppServices
    @ObservationIgnored let terminalViews: TerminalViewProvider

    init(_ environment: EnvironmentValues, controller: WorkspaceController, app: AppModel?, connector: LiveConnector?) {
        theme = environment.theme
        homeFolder = environment.homeFolder
        isCompactLayout = environment.isCompactLayout
        services = environment.services
        terminalViews = environment.terminalViewProvider
        self.controller = controller
        self.app = app
        self.connector = connector
    }

    /// Carries the environment's changes over (only real ones: each one updates the screen).
    func update(_ environment: EnvironmentValues) {
        if theme != environment.theme { theme = environment.theme }
        if homeFolder != environment.homeFolder { homeFolder = environment.homeFolder }
        if isCompactLayout != environment.isCompactLayout { isCompactLayout = environment.isCompactLayout }
    }

    func setInsets(_ i: UIEdgeInsets) {
        let e = EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
        if e != insets { insets = e }
    }
}

/// The root of a hosted screen (`PhoneHostContext`): the screen in its container's safe
/// area (on `edges`), with the app's environment.
struct PhoneHosted<Content: View>: View {
    let context: PhoneHostContext
    let content: Content
    var edges: Edge.Set = .all

    var body: some View {
        let i = context.insets
        content
            .safeAreaPadding(EdgeInsets(top: edges.contains(.top) ? i.top : 0,
                                        leading: edges.contains(.leading) ? i.leading : 0,
                                        bottom: edges.contains(.bottom) ? i.bottom : 0,
                                        trailing: edges.contains(.trailing) ? i.trailing : 0))
            .environment(\.theme, context.theme)
            .environment(\.homeFolder, context.homeFolder)
            .environment(\.isCompactLayout, context.isCompactLayout)
            .environment(\.services, context.services)
            .environment(\.terminalViewProvider, context.terminalViews)
            .environment(context.controller)
            .environment(context.app)
            .environment(context.connector)
    }
}

extension UIHostingController {
    /// A hosting controller for a screen that Core Animation moves: clear, and blind to
    /// UIKit's safe area (its root gives it the container's, `PhoneHosted`).
    static func moving(_ root: Content) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host
    }
}

extension UIView {
    /// The view of the view controller this view is in (a hosting controller's: SwiftUI's
    /// global coordinate space).
    var controllerRoot: UIView? {
        var view: UIView? = self
        while let v = view {
            if v.next is UIViewController { return v }
            view = v.superview
        }
        return nil
    }
}

// MARK: - Core Animation

/// The iPhone's moving screens run on Core Animation, as Telegram's do: a finger moves
/// a layer (no SwiftUI update per step), and the settling moves are animations the
/// render server plays at the display's rate, whatever the main thread is doing.
enum PhoneMotion {
    /// ProMotion: as fast as the display goes (the app opts in with
    /// `CADisableMinimumFrameDurationOnPhone`, else iPhones cap it at 60 Hz).
    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    static let translationX = "transform.translation.x"

    /// The layer's horizontal translation as drawn now: mid-animation, the presentation's;
    /// else the model's (just set, the presentation is still the last frame's).
    static func drawnTranslationX(_ layer: CALayer) -> CGFloat {
        let animating = !(layer.animationKeys() ?? []).isEmpty
        let shown = animating ? (layer.presentation() ?? layer) : layer
        return (shown.value(forKeyPath: translationX) as? CGFloat) ?? 0
    }

    /// Plays `values` (evenly spaced over `duration`) on the layer's `keyPath`; the
    /// model value must already be the last one.
    static func keyframes(_ layer: CALayer, _ keyPath: String, _ values: [CGFloat], duration: Double,
                          key: String, delegate: CAAnimationDelegate? = nil) {
        guard values.count > 1, duration > 0 else { return layer.removeAnimation(forKey: key) }
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = duration
        a.calculationMode = .linear
        a.preferredFrameRateRange = frameRate
        a.delegate = delegate
        layer.add(a, forKey: key)
    }
}

/// Asks the display for its top rate while a finger moves a screen (the pane screen, Go
/// to): ProMotion otherwise keeps a finger's custom drag at 60 Hz (a scroll view asks
/// for itself), and touches come at the display's rate. A display link that does nothing
/// but ask.
@MainActor
final class PhoneFrameRateBoost {
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: Tick.shared, selector: #selector(Tick.tick(_:)))
        link.preferredFrameRateRange = PhoneMotion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The links' target (a link keeps its target).
    private final class Tick: NSObject {
        static let shared = Tick()
        @objc func tick(_ link: CADisplayLink) {}
    }
}

/// Calls back when a Core Animation animation ends: `finished` false when it was
/// taken off (a finger took the layer, another move replaced it).
final class PhoneAnimationEnd: NSObject, CAAnimationDelegate {
    private let done: (Bool) -> Void

    init(_ done: @escaping (Bool) -> Void) { self.done = done }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) { done(flag) }
}

/// SwiftUI's spring (`Animation.spring(duration:bounce:)`: mass 1, response
/// `duration`, damping ratio 1 − `bounce`), solved in closed form, to play as
/// keyframes on Core Animation with what SwiftUI's version did around it: values
/// stay within 0...1 (a spring that would overshoot its end stops there, at its
/// first crossing, as Telegram's halts), and a move taken over keeps its speed.
struct PhoneSpring {
    var duration: Double
    var bounce: Double = 0

    private var omega: Double { 2 * .pi / duration }
    private var zeta: Double { 1 - min(max(bounce, 0), 0.99) }

    /// Displacement from the target and its speed at `t`, from `x0` and `v0` (units per second).
    func state(at t: Double, x0: Double, v0: Double) -> (x: Double, v: Double) {
        let w = omega, z = zeta
        if z >= 1 {
            let b = v0 + w * x0
            let e = exp(-w * t)
            return ((x0 + b * t) * e, (v0 - w * b * t) * e)
        }
        let wd = w * (1 - z * z).squareRoot()
        let a = x0, b = (v0 + z * w * x0) / wd
        let e = exp(-z * w * t), c = cos(wd * t), s = sin(wd * t)
        return (e * (a * c + b * s), e * ((-z * w * a + wd * b) * c + (-z * w * b - wd * a) * s))
    }

    /// The move from `from` to `to` (0 or 1) starting at `velocity` (units per second),
    /// sampled at `rate` per second, clamped to 0...1, ending when it reaches `to` (its
    /// first crossing) or comes to rest there.
    func samples(from: Double, to: Double, velocity: Double, rate: Double = 240) -> (duration: Double, values: [Double]) {
        let x0 = from - to
        var values = [from]
        var previous = x0
        let dt = 1 / rate
        var t = dt
        while t < 3 {
            let (x, v) = state(at: t, x0: x0, v0: velocity)
            let crossed = previous != 0 && (x == 0 || (x > 0) != (previous > 0))
            if crossed || (abs(x) < 0.0005 && abs(v) < 0.05) {
                values.append(to)
                return (t, values)
            }
            values.append(min(max(to + x, 0), 1))
            previous = x
            t += dt
        }
        values.append(to)
        return (t, values)
    }
}

/// A spring move under way, to know where it is and how fast it goes when another takes over.
struct PhoneSpringMove {
    var spring: PhoneSpring
    var start: CFTimeInterval
    var duration: Double
    var from: Double
    var to: Double
    var velocity: Double

    /// Its speed now (units per second); 0 once it has ended.
    func velocity(at now: CFTimeInterval) -> Double {
        let t = now - start
        guard t >= 0, t < duration else { return 0 }
        return spring.state(at: t, x0: from - to, v0: velocity).v
    }
}
