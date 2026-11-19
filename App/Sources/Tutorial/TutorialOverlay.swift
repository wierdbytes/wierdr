import SwiftUI
import UIKit

/// The tour's overlay: a window of its own over the app's (over its sheets, alerts and
/// the iPhone's screens moved by Core Animation alike), which takes a finger only where
/// the step lets it not through (`TutorialWindow`). A display link follows the step's
/// anchors (`TutorialAnchors`: where they're drawn now, mid-push or mid-scroll too) into
/// `TutorialOverlayModel`, which the SwiftUI overlay draws: the dim with the hole, the
/// ring round it, the pointer, the card.
@MainActor
final class TutorialPresenter {
    let model = TutorialOverlayModel()
    private unowned let tour: Tutorial
    private var window: TutorialWindow?
    private var link: CADisplayLink?
    /// Changes with each show and hide (a hide's late removal checks it).
    private var showings = 0
    private var observers: [NSObjectProtocol] = []

    init(tour: Tutorial) {
        self.tour = tour
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let hiding = name == UIResponder.keyboardWillHideNotification
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated { self?.keyboardMoved(hiding ? nil : end) }
            })
        }
    }

    func show() {
        showings += 1
        if window == nil, let scene = Self.scene {
            let window = TutorialWindow(windowScene: scene)
            // Over the app's window (its alerts and sheets are in it), under the keyboard's.
            window.windowLevel = .normal + 1
            window.backgroundColor = .clear
            let host = UIHostingController(rootView: TutorialOverlayRoot(model: model))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.tour = tour
            window.model = model
            self.window = window
        }
        // Not made key: the app keeps the keyboard and the first responder.
        window?.isHidden = false
        if link == nil {
            let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// Once the overlay has faded out.
    func hide() {
        showings += 1
        let showing = showings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.showings == showing else { return }
            self.link?.invalidate()
            self.link = nil
            self.window?.isHidden = true
            self.window = nil
            self.model.reset()
        }
    }

    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Each frame: where the step's anchors are drawn.
    fileprivate func tick() {
        guard let window else { return }
        let anchors = TutorialAnchors.shared
        let step = tour.step
        let target = step?.anchor.flatMap { anchors.frame($0) }
        model.follow(step: step?.id, target: target)
        model.passRects = (target.map { [$0] } ?? []) + (step?.also ?? []).compactMap { anchors.frame($0) }
        if model.safeArea != window.safeAreaInsets { model.safeArea = window.safeAreaInsets }
        // An anchor that doesn't show: the card offers Next rather than leave the person stuck.
        let lost = tour.shown && step?.anchor != nil && target == nil && Date().timeIntervalSince(tour.shownAt) > 1.5
        if model.lost != lost { model.lost = lost }
    }

    private func keyboardMoved(_ frame: CGRect?) {
        let screen = window?.bounds.height ?? UIScreen.main.bounds.height
        let top = frame.flatMap { $0.minY < screen - 1 ? $0.minY : nil }
        if model.keyboardTop != top { withAnimation(.snappy(duration: 0.3)) { model.keyboardTop = top } }
    }

    /// The display link's target (a link keeps its target: this one keeps the presenter weakly).
    private final class Tick: NSObject {
        weak var presenter: TutorialPresenter?
        init(_ presenter: TutorialPresenter) { self.presenter = presenter }
        @objc func tick() { MainActor.assumeIsolated { presenter?.tick() } }
    }
}

/// What the overlay draws, from the display link and the keyboard.
@MainActor
@Observable
final class TutorialOverlayModel {
    /// The step's anchor on screen; nil while it isn't there (or the step has none).
    private(set) var target: CGRect?
    /// The keyboard's top on screen while it's up.
    var keyboardTop: CGFloat?
    var safeArea = UIEdgeInsets.zero
    /// The anchor didn't show: the card offers Next.
    var lost = false
    /// A finger was blocked (the card shakes, the ring flashes).
    private(set) var nudges = 0

    /// Where a finger goes through (the anchor and the step's `also`), on screen.
    @ObservationIgnored var passRects: [CGRect] = []
    /// The card on screen (it takes its own touches).
    @ObservationIgnored var cardFrame: CGRect = .zero
    @ObservationIgnored private var step: String?
    @ObservationIgnored private var lastNudge = Date.distantPast

    /// The anchor where it's drawn: a new step's, or a jump, glides there; following it as
    /// it moves (a scroll, a push) is frame by frame.
    func follow(step: String?, target: CGRect?) {
        let newStep = step != self.step
        self.step = step
        let glide: Bool
        if let a = self.target, let b = target {
            let moved = max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
            guard moved >= 0.5 else { return }
            glide = newStep || moved > 60
        } else {
            // Coming or going: the hole opens out of the middle or closes into it.
            guard (self.target == nil) != (target == nil) else { return }
            glide = true
        }
        if glide {
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { self.target = target }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { self.target = target }
        }
    }

    /// A touch the step doesn't let through.
    func blocked() {
        guard Date().timeIntervalSince(lastNudge) > 0.6 else { return }
        lastNudge = Date()
        nudges += 1
    }

    func reset() {
        target = nil
        step = nil
        lost = false
        passRects = []
        cardFrame = .zero
    }
}

/// The overlay's window: touches on the card are its own; where the step lets a finger
/// through (its anchor, `also`; everything in a free step) they go to the app's window
/// under it; elsewhere they stop here (and nudge the card).
final class TutorialWindow: UIWindow {
    weak var tour: Tutorial?
    weak var model: TutorialOverlayModel?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let tour, let model, tour.isActive else { return nil }
        let root = rootViewController?.view
        if tour.shown, !tour.away, model.cardFrame.contains(point) { return super.hitTest(point, with: event) }
        // Between steps, or on its way back to the step's place: wait.
        guard tour.shown, !tour.away, let step = tour.step else { return root }
        if step.free { return nil }
        if !model.lost, step.gesture != nil,
           model.passRects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            return nil
        }
        if event?.type == .touches { model.blocked() }
        return root
    }
}

// MARK: - Drawing

struct TutorialOverlayRoot: View {
    let model: TutorialOverlayModel
    @AppStorage("appearance") private var appearance: AppearanceOverride = .system

    var body: some View {
        TutorialOverlayContent(model: model)
            .resolvingTheme()
            .preferredColorScheme(appearance.colorScheme)
    }
}

private struct TutorialOverlayContent: View {
    let model: TutorialOverlayModel
    @Environment(\.theme) private var theme
    @State private var cardSize: CGSize = .zero

    /// Around the anchor.
    static let holePadding: CGFloat = 6

    var body: some View {
        let tour = Tutorial.shared
        let step = tour.step
        let dimmed = tour.isActive && step?.free == false
        // Away from the step's place, its anchor is wherever that left it: no hole, no hint.
        let up = tour.shown && !tour.away
        let target = step?.kind == .normal && !model.lost && !tour.away ? model.target : nil
        let hole = target.map { $0.insetBy(dx: -Self.holePadding, dy: -Self.holePadding) }
        GeometryReader { geo in
            let bounds = geo.size
            ZStack(alignment: .topLeading) {
                HoleShape(hole: hole ?? CGRect(x: bounds.width / 2, y: bounds.height / 2, width: 0, height: 0))
                    .fill(Color.black.opacity(theme.isDark ? 0.62 : 0.45), style: FillStyle(eoFill: true))
                    .opacity(dimmed ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: dimmed)
                    .allowsHitTesting(false)
                if up, let step, let hole, let target, let gesture = step.gesture {
                    TutorialRing(rect: hole, flash: model.nudges)
                    if !quiet(step) {
                        TutorialPointer(gesture: gesture, target: target)
                            .transition(.opacity)
                    }
                }
                if up, let step {
                    let width = min(bounds.width - 32, 380)
                    TutorialCard(step: step, number: tour.index + 1, count: tour.count, lost: model.lost)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(Shake(amount: CGFloat(model.nudges)))
                        .animation(.linear(duration: 0.4), value: model.nudges)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            model.cardFrame = frame
                            if frame.size != cardSize { cardSize = frame.size }
                        }
                        .position(center(of: step, card: CGSize(width: width, height: cardSize.height),
                                         target: target, bounds: bounds))
                        .opacity(cardSize.height > 0 ? 1 : 0)
                        .transition(.opacity)
                        .id(step.id)
                }
            }
            .frame(width: bounds.width, height: bounds.height)
        }
        .ignoresSafeArea()
        .onChange(of: up) { _, up in if !up { model.cardFrame = .zero } }
    }

    /// The step's pointer rests (the person is at it).
    private func quiet(_ step: TutorialStep) -> Bool {
        guard let quiet = step.quiet, let ctx = Tutorial.shared.context else { return false }
        return quiet(ctx)
    }

    /// Where the card goes: by the anchor where there's room (under it when it's in the
    /// upper half), else over or under it, else at the top; a step can pin it to the top,
    /// the bottom or the middle. Clear of the status bar, the home indicator and the keyboard.
    private func center(of step: TutorialStep, card: CGSize, target: CGRect?, bounds: CGSize) -> CGPoint {
        let safe = model.safeArea
        let top = safe.top + 8
        var bottom = bounds.height - max(safe.bottom, 8) - 8
        if let keyboard = model.keyboardTop { bottom = min(bottom, keyboard - 8) }
        let h = card.height, gap: CGFloat = 14
        var y: CGFloat
        let placement: TutorialStep.Card = model.lost ? .center : (target == nil && step.card == .auto ? .center : step.card)
        switch placement {
        case .top: y = top
        case .bottom: y = bottom - h
        case .center: y = (top + bottom - h) / 2
        case .auto:
            let t = target!.insetBy(dx: -Self.holePadding, dy: -Self.holePadding)
            let below = t.maxY + gap, above = t.minY - gap - h
            let fitsBelow = below + h <= bottom, fitsAbove = above >= top
            if fitsBelow && (t.midY < bounds.height / 2 || !fitsAbove) {
                y = below
            } else if fitsAbove {
                y = above
            } else {
                y = top
            }
        }
        y = min(max(y, top), max(top, bottom - h))
        return CGPoint(x: bounds.width / 2, y: y + h / 2)
    }
}

/// The dim with the anchor's hole (even-odd), animated as the hole moves.
private struct HoleShape: Shape {
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -40, dy: -40))
        if hole.width > 0.5, hole.height > 0.5 {
            path.addPath(Path(roundedRect: hole, cornerRadius: TutorialRing.radius(hole), style: .continuous))
        }
        return path
    }
}

/// The accent ring round the hole, breathing; it flashes when a finger is blocked.
private struct TutorialRing: View {
    var rect: CGRect
    var flash: Int
    @Environment(\.theme) private var theme

    /// A round button's hole is a circle; others' corners are rounded.
    static func radius(_ rect: CGRect) -> CGFloat {
        abs(rect.width - rect.height) < 8 ? min(rect.width, rect.height) / 2 : min(20, rect.height / 2, rect.width / 2)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 2 * .pi / 1.6) + 1) / 2
            let shape = RoundedRectangle(cornerRadius: Self.radius(rect), style: .continuous)
            ZStack {
                shape.strokeBorder(theme.accent.opacity(0.35 * (1 - breath)), lineWidth: 6)
                    .padding(-4 - 4 * breath)
                shape.strokeBorder(theme.accent, lineWidth: 2)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
        .phaseAnimator([0, 1], trigger: flash) { view, phase in
            view.scaleEffect(phase == 1 ? 1.04 : 1)
        } animation: { _ in .easeInOut(duration: 0.15) }
        .allowsHitTesting(false)
    }
}

/// A shake left and right as `amount` goes up by one.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(amount * .pi * 4), y: 0))
    }
}

/// A finger showing the step's gesture on its anchor, over and over: a touch (a round
/// white dot in an accent ring) coming down, pressing, moving, lifting off.
private struct TutorialPointer: View {
    var gesture: TutorialGesture
    var target: CGRect
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            // Reduce Motion: the finger held where the gesture is under way.
            let time = reduceMotion ? PointerPath.still(gesture) : context.date.timeIntervalSinceReferenceDate
            let s = PointerPath.state(gesture, in: target, at: time)
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: 40, height: 40)
                    .scaleEffect(s.ripple)
                    .opacity(s.rippleOpacity)
                // See-through: what it touches stays readable.
                Circle()
                    .fill(Color.white.opacity(0.45))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                    .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2).padding(2.5))
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .scaleEffect(s.scale)
            }
            .position(s.point)
            .opacity(s.opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where the pointer is at a moment of its loop.
enum PointerPath {
    struct State {
        var point: CGPoint
        var scale: CGFloat = 1
        var opacity: Double = 0
        var ripple: CGFloat = 1
        var rippleOpacity: Double = 0
    }

    private static func ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// A moment of the loop that shows the gesture standing still (Reduce Motion).
    static func still(_ gesture: TutorialGesture) -> TimeInterval {
        switch gesture {
        case .tap: return 0.4
        case .hold: return 1.0
        case .swipeLeft, .swipeRight, .pullUp: return 0.75
        }
    }

    /// 0 before `a`, 1 after `b`, eased between.
    private static func phase(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }

    static func state(_ gesture: TutorialGesture, in r: CGRect, at time: TimeInterval) -> State {
        // On a row, where a thumb would: its title's side, not over its chips.
        let center = CGPoint(x: r.width > 240 ? r.minX + min(r.width * 0.3, 140) : r.midX, y: r.midY)
        switch gesture {
        case .tap:
            let t = time.truncatingRemainder(dividingBy: 1.8)
            let appear = phase(t, 0, 0.25), press = phase(t, 0.3, 0.42), lift = phase(t, 0.42, 0.55)
            let fade = phase(t, 0.8, 1.05), wave = phase(t, 0.42, 1.0)
            return State(point: center, scale: 1.25 - 0.25 * appear - 0.2 * press + 0.2 * lift,
                         opacity: appear * (1 - fade), ripple: 1 + 1.3 * wave,
                         rippleOpacity: lift > 0 ? 0.9 * (1 - wave) : 0)
        case .hold:
            let t = time.truncatingRemainder(dividingBy: 2.6)
            let appear = phase(t, 0, 0.25), press = phase(t, 0.3, 0.45), held = phase(t, 0.45, 1.5)
            let lift = phase(t, 1.5, 1.65), fade = phase(t, 1.7, 1.95)
            return State(point: center, scale: 1.25 - 0.25 * appear - 0.2 * press + 0.2 * lift,
                         opacity: appear * (1 - fade), ripple: 1 + 0.9 * held,
                         rippleOpacity: press > 0 ? 0.9 * (1 - lift) : 0)
        case .swipeLeft, .swipeRight, .pullUp:
            let t = time.truncatingRemainder(dividingBy: 2.2)
            let (from, to): (CGPoint, CGPoint) = {
                switch gesture {
                case .swipeRight:
                    return (CGPoint(x: r.minX + min(48, r.width * 0.15), y: r.midY),
                            CGPoint(x: r.minX + min(r.width * 0.62, 280), y: r.midY))
                case .swipeLeft:
                    return (CGPoint(x: r.maxX - 44, y: r.midY),
                            CGPoint(x: r.maxX - min(r.width * 0.55, 220), y: r.midY))
                default:
                    let start = r.maxY - 70
                    return (CGPoint(x: r.midX, y: start), CGPoint(x: r.midX, y: start - min(260, r.height * 0.45)))
                }
            }()
            let appear = phase(t, 0, 0.2), press = phase(t, 0.2, 0.32), move = phase(t, 0.35, 1.15)
            let lift = phase(t, 1.15, 1.3), fade = phase(t, 1.2, 1.45)
            let point = CGPoint(x: from.x + (to.x - from.x) * move, y: from.y + (to.y - from.y) * move)
            return State(point: point, scale: 1.25 - 0.25 * appear - 0.15 * press + 0.15 * lift,
                         opacity: appear * (1 - fade))
        }
    }
}
