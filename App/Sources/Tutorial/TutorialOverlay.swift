import SwiftUI
import UIKit

/// The tour's overlay: a window of its own over the app's (over its sheets, alerts and
/// the iPhone's screens moved by Core Animation alike), which takes a finger only where
/// the step lets it not through (`TutorialWindow`). A display link follows the step's
/// anchors (`TutorialAnchors`: where they're drawn now, mid-push or mid-scroll too) and its
/// phase into `TutorialOverlayModel`, which the SwiftUI overlay draws: the dim with its
/// holes (the anchor and the spotlight clear, `also` lightly dimmed), the ring round the
/// anchor, the pointer, the card.
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

    /// Each frame: the step's phase, and where its anchors are drawn.
    fileprivate func tick() {
        guard let window else { return }
        let anchors = TutorialAnchors.shared
        let step = tour.step
        var phase: Int?
        if let step, !step.phases.isEmpty, let ctx = tour.context {
            for (i, p) in step.phases.enumerated() {
                var on = false
                if let when = p.when {
                    on = when(ctx)
                } else if let pointer = p.pointer, let r = anchors.frame(pointer) {
                    // Most of it out (a swipe button grows in as the row uncovers it).
                    on = r.width * r.height >= 300
                }
                if on { phase = i }
            }
        }
        let pointer = phase.flatMap { step?.phases[$0].pointer }.flatMap { anchors.frame($0) }
        // The anchor; without it, the phase's (the keys gone: the terminal to swipe again).
        let target = step?.anchor.flatMap { anchors.frame($0) } ?? pointer
        model.follow(step: step?.id, target: target,
                     spots: step?.spotlight.compactMap { anchors.union($0) } ?? [],
                     soft: step?.also.compactMap { anchors.frame($0) } ?? [])
        model.set(phase: phase, pointer: pointer, near: step?.near.flatMap { anchors.frame($0) })
        model.passRects = [target, pointer].compactMap { $0 } + model.soft
        // A free step lets the app open things over its anchor (a system menu over the +).
        let covered = step?.free == true && step?.anchor.map { anchors.covered($0) } == true
        if model.covered != covered { model.covered = covered }
        if model.safeArea != window.safeAreaInsets { model.safeArea = window.safeAreaInsets }
        if model.width != window.bounds.width { model.width = window.bounds.width }
        // An anchor that doesn't show: the card offers Next rather than leave the person stuck.
        let lost = tour.shown && !tour.succeeded && !tour.detour && step?.anchor != nil && target == nil
            && Date().timeIntervalSince(tour.shownAt) > 1.5
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
    /// Around an anchor.
    static let holePadding: CGFloat = 6

    /// The step's anchor on screen (the hole); nil while it isn't there (or the step has none).
    private(set) var target: CGRect?
    /// The spotlight's places (clear), and `also`'s (lightly dimmed).
    private(set) var spots: [CGRect] = []
    private(set) var soft: [CGRect] = []
    /// The step's phase under way (`TutorialStep.phases`), since when.
    private(set) var phase: Int?
    private(set) var phaseSince = Date.distantPast
    /// Where the phase points, when not at the anchor (the Pin button).
    private(set) var pointer: CGRect?
    /// What the card goes by in a free step.
    private(set) var near: CGRect?
    /// The keyboard's top on screen while it's up.
    var keyboardTop: CGFloat?
    var safeArea = UIEdgeInsets.zero
    /// The screen's.
    var width: CGFloat = 0
    /// The anchor didn't show: the card offers Next.
    var lost = false
    /// Something is over the anchor (a menu a free step let open): no ring, no pointer.
    var covered = false
    /// A finger was blocked (the card shakes, the ring flashes).
    private(set) var nudges = 0

    /// Where a finger goes through (the anchor, the phase's pointer and the step's `also`), on screen.
    @ObservationIgnored var passRects: [CGRect] = []
    /// The card on screen (it takes its own touches).
    @ObservationIgnored var cardFrame: CGRect = .zero
    @ObservationIgnored private var step: String?
    @ObservationIgnored private var lastNudge = Date.distantPast

    /// The places where they're drawn: a new step's, or a jump, glide there (a hole coming
    /// opens out of the middle); following them as they move (a scroll, a push) is frame by frame.
    func follow(step: String?, target: CGRect?, spots: [CGRect], soft: [CGRect]) {
        let newStep = step != self.step
        self.step = step
        if let a = self.target, let b = target {
            let moved = Self.distance(a, b)
            if moved >= 0.5 { apply(glide: newStep || moved > 60) { self.target = b } }
        } else if (self.target == nil) != (target == nil) {
            apply(glide: true) { self.target = target }
        }
        if let moved = Self.distance(self.spots, spots) {
            if moved >= 0.5 { apply(glide: newStep || moved > 60) { self.spots = spots } }
        } else {
            apply(glide: true) { self.spots = spots }
        }
        if let moved = Self.distance(self.soft, soft) {
            if moved >= 0.5 { apply(glide: newStep || moved > 60) { self.soft = soft } }
        } else {
            apply(glide: true) { self.soft = soft }
        }
    }

    func set(phase: Int?, pointer: CGRect?, near: CGRect?) {
        if self.phase != phase {
            self.phase = phase
            phaseSince = Date()
        }
        if Self.changed(self.pointer, pointer) { self.pointer = pointer }
        if Self.changed(self.near, near) { self.near = near }
    }

    /// A touch the step doesn't let through.
    func blocked() {
        guard Date().timeIntervalSince(lastNudge) > 0.6 else { return }
        lastNudge = Date()
        nudges += 1
    }

    func reset() {
        target = nil
        spots = []
        soft = []
        phase = nil
        pointer = nil
        near = nil
        step = nil
        lost = false
        covered = false
        passRects = []
        cardFrame = .zero
    }

    private func apply(glide: Bool, _ change: () -> Void) {
        if glide {
            withAnimation(.spring(duration: 0.4, bounce: 0.1), change)
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t, change)
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    /// Nil when they don't pair up (a place came or went).
    private static func distance(_ a: [CGRect], _ b: [CGRect]) -> CGFloat? {
        guard a.count == b.count else { return nil }
        return zip(a, b).map { distance($0, $1) }.max() ?? 0
    }

    private static func changed(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return distance(a, b) >= 0.5
        case (nil, nil): return false
        default: return true
        }
    }
}

/// The overlay's window: touches on the card are its own, and on what an explanation
/// shows (a tap there is Next); where the step lets a finger through (its anchor, `also`;
/// everything in a free step or while a menu it didn't ask for is out) they go to the
/// app's window under it; elsewhere they stop here (and nudge the card).
final class TutorialWindow: UIWindow {
    weak var tour: Tutorial?
    weak var model: TutorialOverlayModel?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A menu it didn't ask for: the person closes it (the hint waits, hidden).
        guard let tour, let model, tour.isActive, !tour.detour else { return nil }
        let root = rootViewController?.view
        let up = tour.shown && !tour.away
        if up, model.cardFrame.contains(point) { return super.hitTest(point, with: event) }
        // Between steps, or on its way back to the step's place: wait.
        guard up, let step = tour.step else { return root }
        if step.free { return nil }
        // The result showing: hold.
        if tour.succeeded { return root }
        let pad = TutorialOverlayModel.holePadding
        if !model.lost, step.isExplanation, let hole = model.target?.insetBy(dx: -pad, dy: -pad), hole.contains(point) {
            return super.hitTest(point, with: event)
        }
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

    var body: some View {
        let tour = Tutorial.shared
        let step = tour.step
        let dimmed = tour.isActive && step?.free == false && !tour.detour
        // Away from the step's place, its anchors are wherever that left them: no holes, no
        // hint; nor while a menu it didn't ask for is out (it's the person's).
        let up = tour.shown && !tour.away && !tour.detour
        let holes = step?.kind == .normal && !model.lost && !tour.away && !tour.detour
        let padded = { (r: CGRect) in Self.padded(r, width: model.width) }
        let hole = holes ? model.target.map(padded) : nil
        let spots = holes ? model.spots.map(padded) : []
        let soft = holes ? model.soft.map(padded) : []
        let phase = model.phase.flatMap { i in step.flatMap { i < $0.phases.count ? $0.phases[i] : nil } }
        GeometryReader { geo in
            let bounds = geo.size
            ZStack(alignment: .topLeading) {
                TutorialDim(hole: hole ?? CGRect(x: bounds.width / 2, y: bounds.height / 2, width: 0, height: 0),
                            spots: spots, soft: soft, alpha: theme.isDark ? 0.62 : 0.45)
                    .opacity(dimmed ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: dimmed)
                    .allowsHitTesting(false)
                if up, let step, let hole {
                    if step.isExplanation, !tour.succeeded {
                        // A tap on what it shows goes on, as Next does (`TutorialWindow` lets it here).
                        RoundedRectangle(cornerRadius: TutorialRing.radius(hole), style: .continuous)
                            .fill(Color.white.opacity(0.001))
                            .frame(width: hole.width, height: hole.height)
                            .position(x: hole.midX, y: hole.midY)
                            .onTapGesture { tour.next() }
                            .accessibilityHidden(true)
                    }
                    // Not round what fills the screen (the list, the terminal): it would frame the screen;
                    // nor while something is over it (a free step's menu).
                    if hole.height < bounds.height * 0.6, !model.covered {
                        TutorialRing(rect: hole, flash: model.nudges, breathing: step.gesture != nil && !tour.succeeded)
                    }
                    let gesture = phase != nil ? phase?.gesture : step.gesture
                    if let gesture, !tour.succeeded, !model.covered, let at = model.pointer ?? model.target {
                        TutorialPointer(gesture: gesture, target: at, since: max(tour.shownAt, model.phaseSince))
                            .transition(.opacity)
                    }
                }
                if up, let step {
                    let lane = Self.lane(spots + soft, bounds: bounds)
                    let focus = ([hole] + spots.map { Optional($0) } + [model.near.map(padded)])
                        .compactMap { $0 }.reduce(nil) { (u: CGRect?, r: CGRect) in u.map { $0.union(r) } ?? r }
                    TutorialCard(step: step, progress: tour.progress(of: tour.index), lost: model.lost,
                                 phase: phase, succeeded: tour.succeeded)
                        .frame(width: lane.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(Shake(amount: CGFloat(model.nudges)))
                        .animation(.linear(duration: 0.4), value: model.nudges)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            model.cardFrame = frame
                            if frame.size != cardSize { cardSize = frame.size }
                        }
                        .position(cardCenter(step, height: cardSize.height, lane: lane, hole: hole, focus: focus,
                                             bounds: bounds))
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

    /// Round an anchor; a row or a button on screen stays 4 pt clear of its sides (its ring in sight).
    private static func padded(_ r: CGRect, width: CGFloat) -> CGRect {
        var p = r.insetBy(dx: -TutorialOverlayModel.holePadding, dy: -TutorialOverlayModel.holePadding)
        guard width > 0, r.minX >= 0, r.maxX <= width, r.height < 200 else { return p }
        let minX = max(p.minX, 4), maxX = min(p.maxX, width - 4)
        p.origin.x = minX
        p.size.width = max(0, maxX - minX)
        return p
    }

    /// The card's column: the screen's, 16 pt in (`x0`…`x1`), the card at most 380 wide in
    /// its middle; beside a tall narrow place it shows by an edge (the key column, the iPad's
    /// sidebar slid out), the rest of the width, if that leaves 260.
    private static func lane(_ shown: [CGRect], bounds: CGSize) -> (midX: CGFloat, width: CGFloat, x0: CGFloat, x1: CGFloat) {
        var x0: CGFloat = 16, x1 = bounds.width - 16
        for r in shown where r.width < bounds.width * 0.4 && r.height > 120 {
            if r.midX > bounds.width / 2 { x1 = min(x1, r.minX - 6) } else { x0 = max(x0, r.maxX + 6) }
        }
        if x1 - x0 < 260 { x0 = 16; x1 = bounds.width - 16 }
        return ((x0 + x1) / 2, min(x1 - x0, 380), x0, x1)
    }

    /// Where the card's middle goes: up and down by `cardY`, in its lane's middle. The iPad's
    /// tour has room aside: by itself (`auto`), the card goes beside what the step shows (a
    /// sidebar row, the ring, ⏎) at its height, to its right, else its left, where the screen
    /// has room for it; else it's over that place's middle (a pane, the composer), in its lane.
    private func cardCenter(_ step: TutorialStep, height h: CGFloat, lane: (midX: CGFloat, width: CGFloat, x0: CGFloat, x1: CGFloat),
                            hole: CGRect?, focus: CGRect?, bounds: CGSize) -> CGPoint {
        let w = lane.width
        let y = cardY(step, height: h, hole: hole, focus: focus, bounds: bounds)
        guard !Tutorial.shared.phone, !model.lost, let focus, [.auto, .below, .above].contains(step.card) else {
            return CGPoint(x: lane.midX, y: y)
        }
        if step.card == .auto, focus.width <= bounds.width / 2 {
            let gap: CGFloat = 16, margin: CGFloat = 16
            let top = model.safeArea.top + 8
            var bottom = bounds.height - max(model.safeArea.bottom, 8) - 8
            if let keyboard = model.keyboardTop { bottom = min(bottom, keyboard - 8) }
            let beside = min(max(focus.midY - h / 2, top), max(top, bottom - h)) + h / 2
            if bounds.width - margin - (focus.maxX + gap) >= w {
                return CGPoint(x: focus.maxX + gap + w / 2, y: beside)
            }
            if focus.minX - gap - margin >= w {
                return CGPoint(x: focus.minX - gap - w / 2, y: beside)
            }
        }
        let x = min(max(focus.midX, lane.x0 + w / 2), max(lane.x0 + w / 2, lane.x1 - w / 2))
        return CGPoint(x: x, y: y)
    }

    /// Where the card's middle goes, up and down: by what the step shows (`focus`: the hole,
    /// the spotlight, a free step's `near`), under it when it's in the upper half (or
    /// `below`), else over it, else at the top; what fills the screen (the terminal, the
    /// list) puts it by the anchor when that's small, else inside it at its top. A step can
    /// pin it to the top, the bottom or the middle. Clear of the status bar, the home
    /// indicator and the keyboard.
    private func cardY(_ step: TutorialStep, height h: CGFloat, hole: CGRect?, focus: CGRect?, bounds: CGSize) -> CGFloat {
        let safe = model.safeArea
        let top = safe.top + 8
        var bottom = bounds.height - max(safe.bottom, 8) - 8
        if let keyboard = model.keyboardTop { bottom = min(bottom, keyboard - 8) }
        let big = (bottom - top) * 0.6
        let gap: CGFloat = 14
        var placement = step.card
        if model.lost || (focus == nil && [.auto, .below, .above].contains(placement)) { placement = .center }
        var y: CGFloat
        switch placement {
        case .top: y = top
        case .bottom: y = bottom - h
        case .center: y = (top + bottom - h) / 2
        case .auto, .below, .above:
            var around = focus ?? .zero
            if around.height > big, let hole, hole.height <= big { around = hole }
            if around.height > big {
                y = around.minY + gap
            } else {
                let below = around.maxY + gap, above = around.minY - gap - h
                let fitsBelow = below + h <= bottom, fitsAbove = above >= top
                let preferBelow = placement == .below || (placement == .auto && around.midY < bounds.height / 2)
                if preferBelow {
                    y = fitsBelow ? below : fitsAbove ? above : top
                } else {
                    y = fitsAbove ? above : fitsBelow ? below : top
                }
            }
        }
        y = min(max(y, top), max(top, bottom - h))
        return y + h / 2
    }
}

/// The dim: clear in the hole and the spotlight, light over `soft` (where a finger may
/// go besides), each place rounded as the ring is; cut out of one layer, so places that
/// overlap don't add up.
private struct TutorialDim: View {
    var hole: CGRect
    var spots: [CGRect]
    var soft: [CGRect]
    var alpha: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(alpha)).padding(-40)
            ForEach(Array(soft.enumerated()), id: \.offset) { _, r in place(r).blendMode(.destinationOut) }
            ZStack(alignment: .topLeading) {
                ForEach(Array(soft.enumerated()), id: \.offset) { _, r in place(r) }
            }
            .compositingGroup()
            .opacity(alpha * 0.4)
            ForEach(Array(spots.enumerated()), id: \.offset) { _, r in place(r).blendMode(.destinationOut) }
            place(hole).blendMode(.destinationOut)
        }
        .compositingGroup()
    }

    private func place(_ r: CGRect) -> some View {
        RoundedRectangle(cornerRadius: TutorialRing.radius(r), style: .continuous)
            .fill(Color.black)
            .frame(width: max(0, r.width), height: max(0, r.height))
            .position(x: r.midX, y: r.midY)
    }
}

/// The accent ring round the hole: breathing while the step waits for a gesture, still
/// round what an explanation shows; it flashes when a finger is blocked.
private struct TutorialRing: View {
    var rect: CGRect
    var flash: Int
    var breathing: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A round button's hole is a circle; others' corners are rounded.
    static func radius(_ rect: CGRect) -> CGFloat {
        abs(rect.width - rect.height) < 8 ? min(rect.width, rect.height) / 2 : min(20, rect.height / 2, rect.width / 2)
    }

    var body: some View {
        TimelineView(.animation(paused: !breathing || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = breathing && !reduceMotion ? (sin(t * 2 * .pi / 1.6) + 1) / 2 : 0
            let shape = RoundedRectangle(cornerRadius: Self.radius(rect), style: .continuous)
            ZStack {
                if breathing {
                    shape.strokeBorder(theme.accent.opacity(0.35 * (1 - breath)), lineWidth: 6)
                        .padding(-4 - 4 * breath)
                }
                shape.strokeBorder(theme.accent.opacity(breathing ? 1 : 0.75), lineWidth: breathing ? 2 : 1.5)
            }
            .frame(width: rect.width, height: rect.height)
            // Round its own middle (the view fills the screen once positioned).
            .phaseAnimator([0, 1], trigger: flash) { view, phase in
                view.scaleEffect(phase == 1 ? 1.04 : 1)
            } animation: { _ in .easeInOut(duration: 0.15) }
            .position(x: rect.midX, y: rect.midY)
        }
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
/// white dot in an accent ring) coming down, pressing, moving, lifting off. It waits a
/// moment first (`since`), so what it points at is seen before it's covered; on a small
/// target it's smaller and shows only round the tap.
private struct TutorialPointer: View {
    var gesture: TutorialGesture
    var target: CGRect
    /// When the step (or its phase) came.
    var since: Date
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let delay: TimeInterval = 0.7

    var body: some View {
        let small = PointerPath.isSmall(target)
        let size: CGFloat = small ? 28 : 36
        TimelineView(.animation(paused: reduceMotion)) { context in
            // Reduce Motion: the finger held where the gesture is under way.
            let local = context.date.timeIntervalSince(since) - Self.delay
            let s = reduceMotion ? PointerPath.state(gesture, in: target, at: PointerPath.still(gesture), small: small)
                : local < 0 ? PointerPath.State(point: CGPoint(x: target.midX, y: target.midY))
                : PointerPath.state(gesture, in: target, at: local, small: small)
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: size + 4, height: size + 4)
                    .scaleEffect(s.ripple)
                    .opacity(s.rippleOpacity)
                // See-through: what it touches stays readable.
                Circle()
                    .fill(Color.white.opacity(small ? 0.3 : 0.45))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                    .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2).padding(2.5))
                    .frame(width: size, height: size)
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

    /// A target the dot would hide (the status ring, a limit's ring).
    static func isSmall(_ r: CGRect) -> Bool { max(r.width, r.height) <= 56 }

    private static func ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// A moment of the loop that shows the gesture standing still (Reduce Motion).
    static func still(_ gesture: TutorialGesture) -> TimeInterval {
        switch gesture {
        case .tap: return 0.4
        case .hold: return 1.0
        case .swipeLeft, .swipeRight: return 0.75
        }
    }

    /// 0 before `a`, 1 after `b`, eased between.
    private static func phase(_ t: Double, _ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }

    /// Where a thumb would touch it: a row by its title's side, not over its chips; a short
    /// wide button (‹ with its badge, the limits) by its first part, not over what follows.
    static func touch(_ r: CGRect) -> CGPoint {
        if r.width > 240 { return CGPoint(x: r.minX + min(r.width * 0.3, 140), y: r.midY) }
        if r.width > 1.6 * r.height { return CGPoint(x: r.minX + min(r.height / 2, 26), y: r.midY) }
        return CGPoint(x: r.midX, y: r.midY)
    }

    static func state(_ gesture: TutorialGesture, in r: CGRect, at time: TimeInterval, small: Bool = false) -> State {
        let center = touch(r)
        switch gesture {
        case .tap:
            let t = time.truncatingRemainder(dividingBy: 1.8)
            let appear = phase(t, 0, 0.25), press = phase(t, 0.3, 0.42), lift = phase(t, 0.42, 0.55)
            // Small: gone right after the tap, the target in sight most of the loop.
            let fade = small ? phase(t, 0.55, 0.75) : phase(t, 0.8, 1.05), wave = phase(t, 0.42, 1.0)
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
        case .swipeLeft, .swipeRight:
            let t = time.truncatingRemainder(dividingBy: 2.2)
            let (from, to): (CGPoint, CGPoint) = gesture == .swipeRight
                ? (CGPoint(x: r.minX + min(48, r.width * 0.15), y: r.midY),
                   CGPoint(x: r.minX + min(r.width * 0.62, 280), y: r.midY))
                : (CGPoint(x: r.maxX - 44, y: r.midY),
                   CGPoint(x: r.maxX - min(r.width * 0.55, 220), y: r.midY))
            let appear = phase(t, 0, 0.2), press = phase(t, 0.2, 0.32), move = phase(t, 0.35, 1.15)
            let lift = phase(t, 1.15, 1.3), fade = phase(t, 1.2, 1.45)
            let point = CGPoint(x: from.x + (to.x - from.x) * move, y: from.y + (to.y - from.y) * move)
            return State(point: point, scale: 1.25 - 0.25 * appear - 0.15 * press + 0.15 * lift,
                         opacity: appear * (1 - fade))
        }
    }
}
