import SwiftUI
import UIKit

/// Go to in the iPhone layout (`QuickSwitcher` with `panel`): not a sheet but a panel over
/// the screens, a sheet turned for the thumb. It comes up from the screen's bottom (as
/// the list pulled up past its bottom brought it, `PullToSearch`) and leaves upward: its
/// list pulled up past its bottom (where it rests) takes the panel up with the finger
/// (`PhoneGoToDrag`) instead of stretching, and let go it goes on up and away or comes
/// back down (`release`). Chosen a row, Esc or VoiceOver's escape, it goes up too.
///
/// A UIKit container, as the list's and the pane screen's (`PhoneNavController`): the
/// panel is a card (`PhoneCardView`, the display's corners while it moves) holding
/// `QuickSwitcher` in a hosting controller (`PhoneHosted`), moved by Core Animation;
/// under it the screens dim (black, up to 10 %) while it moves. It keeps over the
/// keyboard (the view's frame does), the screens under it don't (`PhoneWorkspaceView`).
/// Mounted while Go to is up or on its way (`onGone` at the end of its way out).
struct PhoneGoTo: UIViewControllerRepresentable {
    var isPresented: Bool
    /// Gone off the screen (its way out ended): unmount it.
    var onGone: () -> Void

    @Environment(WorkspaceController.self) private var controller
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(LiveConnector.self) private var connector: LiveConnector?

    func makeUIViewController(context: Context) -> PhoneGoToController {
        PhoneGoToController(host: PhoneHostContext(context.environment, controller: controller, app: app, connector: connector))
    }

    func updateUIViewController(_ panel: PhoneGoToController, context: Context) {
        panel.host.update(context.environment)
        panel.onGone = onGone
        panel.setPresented(isPresented)
    }
}

/// The panel's container: the dim and the card, the card at `position` screen heights
/// down (0 in place, 1 under the screen before it comes, −1 over it as it goes).
final class PhoneGoToController: UIViewController {
    let host: PhoneHostContext
    let drag = PhoneGoToDrag()
    /// The home indicator's room while the keyboard is down (the field keeps over it).
    let room = PhoneGoToRoom()
    var onGone: () -> Void = {}

    private var content: UIHostingController<PhoneHosted<PhoneGoToRoot>>!
    private let dim = UIView()
    private let card = PhoneCardView()
    /// The panel's ground under the card, behind the keyboard (the card ends over it; the
    /// keyboard's glass would show the list there).
    private let skirt = UIView()
    /// Go to is up (`showSwitcher`); nil before the first update.
    private var presented: Bool?
    /// Where the card is headed.
    private var target: CGFloat = 1
    /// The spring under way (its speed carries into the next one), in its own progress.
    private var move: PhoneSpringMove?
    /// The positions the move under way goes between.
    private var moveFrom: CGFloat = 1
    private var moveID = 0
    /// What a position of 1 is in points: the window's height (the view's shrinks over the keyboard).
    private var span: CGFloat = 0

    /// Coming up, or going up by itself: critically damped, response 0.35 s.
    static let slide = PhoneSpring(duration: 0.35, bounce: 0)
    /// Let go by the finger: response 0.3 s, damping 0.85, from the finger's speed.
    static let release = PhoneSpring(duration: 0.3, bounce: 0.15)
    private static let moveKey = "goTo"

    private var controller: WorkspaceController { host.controller }

    init(host: PhoneHostContext) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = PanelView()
        view.panel = self
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        dim.isAccessibilityElement = false
        view.addSubview(dim)
        content = .moving(PhoneHosted(context: host, content: PhoneGoToRoot(context: host, room: room, drag: drag)))
        content.view.backgroundColor = UIColor(host.theme.chrome)
        addChild(content)
        content.view.frame = card.content.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.content.addSubview(content.view)
        content.didMove(toParent: self)
        card.onEscape = { [weak self] in self?.controller.showSwitcher = false }
        card.accessibilityViewIsModal = true
        // Shown once laid out, under the screen.
        card.isHidden = true
        skirt.isUserInteractionEnabled = false
        card.insertSubview(skirt, at: 0)
        view.addSubview(card)
        drag.space = view
        drag.onBegin = { [weak self] in self?.beginDrag() }
        drag.onDrag = { [weak self] lift in self?.dragged(lift) }
        drag.onEnd = { [weak self] lift, velocity in self?.endDrag(lift: lift, velocity: velocity) }
    }

    fileprivate func laidOut() {
        let bounds = view.bounds
        card.bounds = CGRect(origin: .zero, size: bounds.size)
        card.center = CGPoint(x: bounds.midX, y: bounds.midY)
        dim.frame = bounds
        let chrome = UIColor(host.theme.chrome)
        content.view.backgroundColor = chrome
        skirt.backgroundColor = chrome
        let below = view.window.map { $0.bounds.height - view.convert(bounds, to: nil).maxY } ?? 0
        skirt.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: max(0, below) + 1)
        let span = max(bounds.height, view.window?.bounds.height ?? 0)
        guard span > 0, span != self.span else { return }
        let first = self.span == 0
        self.span = span
        stopMove()
        guard first else {
            // A new size (rotation): at the move's end, at once.
            apply(target)
            return moveEnded()
        }
        // The first layout: under the screen, and up it comes.
        card.isHidden = false
        target = 1
        apply(1)
        if presented == true {
            animate(to: 0, spring: Self.slide, velocity: 0)
        } else {
            onGone()
        }
    }

    // MARK: Showing

    func setPresented(_ presented: Bool) {
        guard presented != self.presented else { return }
        self.presented = presented
        if !presented { drag.closing() }
        // Not laid out yet: it comes up then (`laidOut`).
        guard span > 0 else { return }
        let goal: CGFloat = presented ? 0 : -1
        guard goal != target else { return }
        animate(to: goal, spring: Self.slide, velocity: currentVelocity())
    }

    // MARK: Moving

    /// The card at `p`, at once.
    private func apply(_ p: CGFloat) {
        let y = Self.pixel(p * span)
        card.transform = CGAffineTransform(translationX: 0, y: y)
        dim.alpha = 0.1 * (1 - min(1, abs(p)))
        card.isRounded = abs(p) > 0.0005
    }

    private static func pixel(_ y: CGFloat) -> CGFloat {
        let scale = DisplayCorner.scale
        return (y * scale).rounded() / scale
    }

    /// Where the card is drawn now (mid-move too).
    private var drawnPosition: CGFloat {
        guard span > 0 else { return target }
        return PhoneMotion.drawnTranslationY(card.layer) / span
    }

    /// The move under way's speed, in positions per second.
    private func currentVelocity() -> Double {
        guard let move else { return 0 }
        return move.velocity(at: CACurrentMediaTime()) * Double(target - moveFrom)
    }

    private func stopMove() {
        moveID += 1
        move = nil
        card.layer.removeAnimation(forKey: Self.moveKey)
        dim.layer.removeAnimation(forKey: Self.moveKey)
    }

    /// From where the card is drawn to `goal` on `spring`, starting at `velocity` (positions per second).
    private func animate(to goal: CGFloat, spring: PhoneSpring, velocity: Double) {
        let from = drawnPosition
        stopMove()
        target = goal
        apply(goal)
        let id = moveID
        guard span > 0, abs(from - goal) * span > 0.25 else {
            return DispatchQueue.main.async { [weak self] in
                guard let self, self.moveID == id else { return }
                self.moveEnded()
            }
        }
        // The spring runs over 0…1 from `from` to `goal` (it stops at its end).
        let distance = Double(goal - from)
        let (duration, values) = spring.samples(from: 0, to: 1, velocity: velocity / distance)
        move = PhoneSpringMove(spring: spring, start: CACurrentMediaTime(), duration: duration,
                               from: 0, to: 1, velocity: velocity / distance)
        moveFrom = from
        card.isRounded = true
        let positions = values.map { from + (goal - from) * CGFloat($0) }
        let span = self.span
        let end = PhoneAnimationEnd { [weak self] finished in
            guard finished, let self, self.moveID == id else { return }
            self.moveEnded()
        }
        PhoneMotion.keyframes(card.layer, PhoneMotion.translationY, positions.map { Self.pixel($0 * span) },
                              duration: duration, key: Self.moveKey, delegate: end)
        PhoneMotion.keyframes(dim.layer, "opacity", positions.map { 0.1 * (1 - min(1, abs($0))) },
                              duration: duration, key: Self.moveKey)
    }

    private func moveEnded() {
        move = nil
        card.isRounded = abs(target) > 0.0005
        if target == -1, presented == false { onGone() }
    }

    // MARK: The finger

    private let boost = PhoneFrameRateBoost()

    /// The list, at its bottom, took the panel: from where it's drawn.
    private func beginDrag() {
        boost.start()
        let p = drawnPosition
        stopMove()
        target = p
        apply(p)
        card.isRounded = true
    }

    /// `lift`: how far the finger took the panel up, in points (≤ 0).
    private func dragged(_ lift: CGFloat) {
        guard span > 0 else { return }
        target = lift / span
        apply(target)
        card.isRounded = true
    }

    /// Let go: up and away when it would get past a third of the screen (or 240 pt) in
    /// 0.2 s at the finger's speed (`velocity`, points per second, down positive); else back.
    private func endDrag(lift: CGFloat, velocity: CGFloat) {
        boost.stop()
        guard span > 0 else { return }
        let projected = lift + 0.2 * min(0, velocity)
        let away = projected < -min(240, span / 3) || (velocity < -600 && lift < -8)
        let speed = Double(velocity / span)
        if away {
            presented = false
            drag.closing()
            animate(to: -1, spring: Self.release, velocity: speed)
            // The move is on its way to the render server before the app redraws.
            CATransaction.flush()
            controller.showSwitcher = false
        } else {
            animate(to: 0, spring: Self.release, velocity: speed)
        }
    }

    /// Lays the card out with its size, hands its safe area down: the bottom's (the
    /// home indicator's, none over the keyboard) to the field's bar (`room`), not as the
    /// list's safe area, which its scroll view wouldn't count as its inset (its last rows
    /// would rest under the field).
    private final class PanelView: UIView {
        weak var panel: PhoneGoToController?

        override func layoutSubviews() {
            super.layoutSubviews()
            panel?.laidOut()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            guard let panel else { return }
            var insets = safeAreaInsets
            if panel.room.bottom != insets.bottom { panel.room.bottom = insets.bottom }
            insets.bottom = 0
            panel.host.setInsets(insets)
        }
    }
}

/// The home indicator's room under Go to's panel, while the keyboard is down.
@MainActor @Observable
final class PhoneGoToRoom {
    var bottom: CGFloat = 0
}

/// The panel's content: Go to, its list fading under the status bar as the iPhone list's does.
struct PhoneGoToRoot: View {
    let context: PhoneHostContext
    let room: PhoneGoToRoom
    let drag: PhoneGoToDrag

    var body: some View {
        QuickSwitcher(panel: drag, homeInset: room.bottom)
            .overlay(alignment: .top) {
                PhoneEdgeFade(edge: .top, height: PhoneEdgeFade.statusBar(context.insets.top))
                    .ignoresSafeArea(.container, edges: .top)
            }
    }
}

/// The finger on Go to's list and the panel (`PhoneGoToController`), as a sheet's scroll
/// view and the sheet: a target of the list's own pan (its scroll view's, found by
/// `PhoneGoToScrollProbe`). While the list is at its bottom (where it rests), a move up
/// takes the panel up instead of stretching the list past its end: the list is held
/// at its bottom and the panel follows the finger; brought back down to where it took
/// it, the list scrolls again. A move that scrolls the list puts the keyboard away
/// (`scrolled`), as the sheet's scrolling does.
@MainActor
final class PhoneGoToDrag: NSObject {
    /// The list scrolled by a finger (not taking the panel up): the keyboard goes.
    var scrolled: () -> Void = {}
    /// The panel goes away: the keyboard goes.
    var closing: () -> Void = {}
    var onBegin: () -> Void = {}
    /// How far the finger took the panel up, in points (≤ 0).
    var onDrag: (CGFloat) -> Void = { _ in }
    /// Let go: the lift and the finger's speed (points per second, down positive).
    var onEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// Where the finger is measured: the panel's container (it doesn't move).
    weak var space: UIView?

    private weak var scrollView: UIScrollView?
    /// The finger holds the panel.
    private var holding = false
    /// The finger's travel when it took the panel.
    private var anchor: CGFloat = 0
    /// The list's offset at its bottom when the finger took the panel: it's held there.
    /// Not its bottom as the panel moves: the list's inset changes on the way (UIKit adds
    /// the home indicator's safe area to it only while the panel is down).
    private var rest: CGFloat = 0
    private var last: CGFloat = 0
    private var scrolledOnce = false

    func attach(_ scrollView: UIScrollView) {
        guard scrollView !== self.scrollView else { return }
        self.scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
        self.scrollView = scrollView
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
    }

    /// The list's offset at its bottom.
    private static func bottom(_ s: UIScrollView) -> CGFloat {
        let inset = s.adjustedContentInset
        return max(-inset.top, s.contentSize.height + inset.bottom - s.bounds.height)
    }

    /// After the scroll view's own handling of the same step (its target came first).
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let s = scrollView else { return }
        let y = g.translation(in: space ?? s.superview).y
        switch g.state {
        case .began:
            holding = false
            scrolledOnce = false
            last = y
        case .changed:
            if !holding {
                let end = Self.bottom(s)
                if y < last, s.contentOffset.y >= end - 0.5 {
                    holding = true
                    anchor = last
                    rest = end
                    onBegin()
                } else if y != last, !scrolledOnce {
                    scrolledOnce = true
                    scrolled()
                }
            }
            if holding {
                let lift = min(0, y - anchor)
                if s.contentOffset.y != rest { s.contentOffset.y = rest }
                onDrag(lift)
                // Back where it took the panel: the list scrolls from here.
                if y > anchor { holding = false }
            }
            last = y
        case .ended, .cancelled, .failed:
            guard holding else { return }
            holding = false
            // Stops the list's own bounce from the finger's speed: it stays at its bottom.
            s.setContentOffset(CGPoint(x: s.contentOffset.x, y: rest), animated: false)
            let velocity = g.state == .ended ? g.velocity(in: space ?? s.superview).y : 0
            onEnd(min(0, y - anchor), velocity)
        default:
            break
        }
    }
}

/// Finds Go to's scroll view (the one SwiftUI's `ScrollView` draws with, around this
/// view in its content) for `PhoneGoToDrag`.
struct PhoneGoToScrollProbe: UIViewRepresentable {
    var drag: PhoneGoToDrag

    final class Probe: UIView {
        weak var drag: PhoneGoToDrag?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }

        func find() {
            guard window != nil else { return }
            var v = superview
            while let view = v {
                if let s = view as? UIScrollView {
                    drag?.attach(s)
                    return
                }
                v = view.superview
            }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        probe.drag = drag
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.drag = drag
        probe.find()
    }
}
