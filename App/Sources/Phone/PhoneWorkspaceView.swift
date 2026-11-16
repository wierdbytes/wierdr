import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WierdrModel

/// The iPhone layout, Telegram's navigation: the list of agents (`PhoneHome`) is the
/// root screen, and a pane (`PhonePaneScreen`) is pushed over it from the right, as
/// a chat over Telegram's chat list. On the list no pane is shown, so none is selected.
///
/// Whether a pane is pushed is `controller.compactColumn` (`.detail` = pushed,
/// `.sidebar` = the list), so focusing a pane from anywhere (rows, quick switcher,
/// status jumps, the Live Activity) pushes it, and `showSidebar()` pops it.
///
/// Telegram's (iOS 26's) motion (`PhoneNavController`): the pane screen slides in from
/// the right edge over the full width, the list goes 0.3 of the width left under it
/// and dims (black, up to 10 %); while it moves, the pane screen has the display's
/// rounded corners and a faint shadow. A tap pushes or pops on a critically damped
/// spring (response 0.3 s). A swipe right anywhere on the pane screen
/// (`PhoneBackSwipe`) pops it with the finger; let go, it finishes or goes back by
/// UIKit's rule (`PhonePopTracker`) on a spring (response 0.3, damping 0.85) that
/// starts at the finger's speed.
///
/// The two screens are UIKit views (each a hosting controller), moved by Core Animation
/// as Telegram's are: the finger moves layers, the springs play in the render server
/// at the display's rate, and no frame waits for SwiftUI.
///
/// Go to (`showSwitcher`) is a third screen pushed over both the same way, as Telegram's
/// archive over its chat list (`PhoneNavController.setGoTo`).
struct PhoneWorkspaceView: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    /// Go to's screen is up or on its way out.
    @State private var goTo = false

    var body: some View {
        let shown = controller.compactColumn == .detail
        ZStack(alignment: .top) {
            PhoneNavigation(shown: shown, goTo: controller.showSwitcher) { goTo = false }
                // The whole window (the screens' grounds run under the status bar and the home
                // indicator; their content keeps to the safe area, `PhoneHostContext`), above
                // the keyboard while it is up; not with Go to (`PhoneNavController.mountGoTo`).
                .ignoresSafeArea(.container)
            AttentionBanner(showing: shown && !goTo)
        }
        .onChange(of: controller.showSwitcher, initial: true) { _, on in
            if on { goTo = true }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        // Behind the keyboard's edge as it comes and goes: the pane screen's ground, Go to's
        // while it's up.
        .background((goTo ? theme.chrome : theme.background).ignoresSafeArea())
        .onChange(of: controller.workspace.spaces) { old, new in
            // The pane on screen was closed (here, on the desktop, or its program
            // exited): back to the list rather than some other pane showing.
            guard shown, let id = Self.shownPane(controller.screen.snapshot, in: old),
                  !new.contains(where: { $0.tabs.contains { $0.panes.contains { $0.id == id } } }) else { return }
            controller.showSidebar()
        }
    }

    /// The pane the screen showed with these spaces (`ScreenState`'s resolution, fallbacks included).
    private static func shownPane(_ s: ScreenState.Snapshot, in spaces: [Space]) -> String? {
        guard let space = spaces.first(where: { $0.id == s.space }) ?? spaces.first else { return nil }
        guard let tab = space.tabs.first(where: { $0.id == s.tabBySpace[space.id] }) ?? space.tabs.first else { return nil }
        let panes = tab.panes
        return (panes.first { $0.id == s.focusByTab[tab.id] } ?? panes.first { $0.terminal != nil } ?? panes.first)?.id
    }
}

/// The list, the pane screen and Go to in their UIKit container (`PhoneNavController`).
private struct PhoneNavigation: UIViewControllerRepresentable {
    var shown: Bool
    /// Go to is up (`showSwitcher`).
    var goTo: Bool
    /// Go to's screen went off the screen (its pop ended).
    var goToGone: () -> Void

    @Environment(WorkspaceController.self) private var controller
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(LiveConnector.self) private var connector: LiveConnector?

    func makeUIViewController(context: Context) -> PhoneNavController {
        PhoneNavController(host: PhoneHostContext(context.environment, controller: controller, app: app, connector: connector))
    }

    func updateUIViewController(_ nav: PhoneNavController, context: Context) {
        nav.host.update(context.environment)
        nav.onGoToGone = goToGone
        // First: a pane chosen in Go to is put under it at once, then Go to goes.
        nav.setShown(shown)
        nav.setGoTo(goTo)
    }

    static func dismantleUIViewController(_ nav: PhoneNavController, coordinator: ()) {
        nav.swipe.detach()
        nav.stopObserving()
    }
}

// MARK: - Container

/// Where the two screens are drawn at `progress` (0 the list alone, 1 the pane screen
/// over it), as Telegram's (iOS 26's) navigation transition: the pane screen at
/// x = (1 − p)·W, pixel-rounded; the list at −0.3·W·p; the dim between them at 0.1·p.
/// A spring that would overshoot stops at either end, as Telegram's does (it halts at
/// the first crossing, `PhoneSpring`).
///
/// While it moves, the pane screen (`PhoneCardView`) has the display's rounded corners
/// and Telegram's faint shadow (black 4 %, radius 12, 3 pt up). Both screens fill the
/// window (their grounds run under the status bar and the home indicator) and lay out
/// in its safe area, which this container hands down (`PhoneHostContext`).
///
/// Go to is a screen over both: it comes up from under the screen (`enterGo`, as it came
/// out of the list pulled up), and goes as a pane screen does, to the right (its
/// progress `goTarget`: its screen, `goCard`, at x = (1 − g)·W, without parallax, a dim
/// of its own), on the same springs and the same swipe right (`swipe` takes Go to while
/// it's there).
final class PhoneNavController: UIViewController {
    let host: PhoneHostContext
    let swipe = PhoneBackSwipe()
    /// Go to's screen went off the screen (its pop ended).
    var onGoToGone: () -> Void = {}

    private var list: UIHostingController<PhoneHosted<PhoneHome>>!
    private let dim = UIView()
    private let card = PhoneCardView()
    /// The pane screen: pushed, or on its way in or out.
    private var pane: UIHostingController<PhoneHosted<PhonePaneScreen>>?
    /// A pane is pushed (`compactColumn`); nil before the first update.
    private var shown: Bool?
    /// Go to's screen: pushed, or on its way in or out.
    private var goTo: UIHostingController<PhoneHosted<PhoneGoToRoot>>?
    private let goDim = UIView()
    private let goCard = PhoneCardView()
    /// Go to's ground under its card, down to the screen's bottom (behind the keyboard's glass).
    private let goSkirt = UIView()
    /// How much of this view the keyboard covers (0: down); Go to's card keeps over it.
    private var keyboardOverlap: CGFloat = 0
    /// While Go to is up: SwiftUI's keyboard safe area off above this container, so the
    /// screens under Go to stay whole (squeezed over the keyboard, they grew back only at
    /// SwiftUI's next update, late when the main thread was busy as Go to went, the
    /// window's black under the keyboard as it went down); Go to keeps over the keyboard
    /// itself (`keyboardMoved`). Ignoring the keyboard in the view wasn't enough on iOS 27.
    private var keyboardRegionOff: KeyboardRegionOff?
    private var keyboardObservers: [NSObjectProtocol] = []
    /// Go to is up (`showSwitcher`).
    private var goPresented = false
    /// Where Go to is headed, 1 pushed, 0 popped.
    private var goTarget: CGFloat = 0
    private var goMove: PhoneSpringMove?
    private var goMoveID = 0
    /// The swipe under way takes Go to (not the pane screen).
    private var swipingGoTo = false
    /// Where the screens are headed: the last push, pop or swipe's end.
    private var target: CGFloat = 0
    /// The progress the layers are set to (mid-move, its end).
    private var progress: CGFloat = 0
    /// The spring under way (its speed carries into the next one).
    private var move: PhoneSpringMove?
    private var moveID = 0
    private var width: CGFloat = 0

    /// A push or a pop by a tap (or anything but a finger): critically damped, response 0.3 s.
    static let push = PhoneSpring(duration: 0.3, bounce: 0)
    /// A swipe let go: response 0.3 s, damping 0.85, from the finger's speed.
    static let release = PhoneSpring(duration: 0.3, bounce: 0.15)
    private static let moveKey = "nav"
    private static let goKey = "goTo"
    private static let goEnterKey = "goToEnter"
    /// Go to coming up: critically damped, response 0.35 s.
    static let enter = PhoneSpring(duration: 0.35, bounce: 0)

    private var controller: WorkspaceController { host.controller }

    init(host: PhoneHostContext) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = NavView()
        view.nav = self
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        list = .moving(PhoneHosted(context: host, content: PhoneHome()))
        addChild(list)
        view.addSubview(list.view)
        list.didMove(toParent: self)
        for d in [dim, goDim] {
            d.backgroundColor = .black
            d.alpha = 0
            d.isUserInteractionEnabled = false
            d.isAccessibilityElement = false
        }
        view.addSubview(dim)
        card.onEscape = { [weak self] in self?.controller.showSidebar() }
        view.addSubview(card)
        view.addSubview(goDim)
        goCard.onEscape = { [weak self] in self?.controller.showSwitcher = false }
        goCard.isHidden = true
        goSkirt.isUserInteractionEnabled = false
        goCard.insertSubview(goSkirt, at: 0)
        view.addSubview(goCard)
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            keyboardObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let hiding = name == UIResponder.keyboardWillHideNotification
                MainActor.assumeIsolated { self?.keyboardMoved(note, hiding: hiding) }
            })
        }
        swipe.onBegin = { [weak self] in
            guard let self else { return 1 }
            self.swipingGoTo = self.goTo != nil
            return self.swipingGoTo ? self.beginGoSwipe() : self.beginSwipe()
        }
        swipe.onDrag = { [weak self] p in
            guard let self else { return }
            if self.swipingGoTo { self.dragGo(to: p) } else { self.drag(to: p) }
        }
        swipe.onEnd = { [weak self] finish, velocity, cancelled in
            guard let self else { return }
            if self.swipingGoTo {
                self.endGoSwipe(finish, velocity: velocity, cancelled: cancelled)
            } else {
                self.endSwipe(finish, velocity: velocity, cancelled: cancelled)
            }
        }
        apply(progress)
        applyGo(goTarget)
        updateAccess()
    }

    fileprivate func laidOut() {
        let bounds = view.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Bounds and center, not frames: the layers carry the move's translation.
        for v in [list.view!, card] {
            v.bounds = CGRect(origin: .zero, size: bounds.size)
            v.center = center
        }
        layoutGoCard()
        dim.frame = bounds
        goDim.frame = bounds
        guard bounds.width != width else { return }
        // A new width (first layout, rotation): at the moves' ends, at once.
        width = bounds.width
        stopMove()
        apply(target)
        moveEnded()
        stopGoMove()
        applyGo(goTarget)
        goMoveEnded()
    }

    // MARK: Showing

    /// The controller's word: a pane pushed or not. A change pushes or pops (`navigate`).
    func setShown(_ shown: Bool) {
        let changed = shown != self.shown
        self.shown = shown
        guard changed else { return }
        if let pane { pane.rootView = PhoneHosted(context: host, content: PhonePaneScreen(covered: !shown)) }
        updateAccess()
        navigate(shown)
    }

    /// A push or a pop that no finger drives (a row, the back button, a status jump…).
    private func navigate(_ shown: Bool) {
        let goal: CGFloat = shown ? 1 : 0
        if !shown { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
        // The swipe's end already set off this very move.
        guard goal != target else { return }
        target = goal
        if shown { mountPane() }
        if goTo != nil, goPresented {
            // Chosen in Go to: at once under it, and Go to's pop shows it.
            stopMove()
            apply(goal)
            return DispatchQueue.main.async { [weak self] in self?.moveEnded() }
        }
        let velocity = move?.velocity(at: CACurrentMediaTime()) ?? 0
        animate(to: goal, spring: Self.push, velocity: velocity)
    }

    private func mountPane() {
        guard pane == nil else { return }
        let pane = UIHostingController.moving(PhoneHosted(context: host, content: PhonePaneScreen(covered: shown != true)))
        addChild(pane)
        pane.view.frame = card.content.bounds
        pane.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.content.addSubview(pane.view)
        pane.didMove(toParent: self)
        self.pane = pane
        updateAccess()
    }

    /// Popped: the pane screen leaves the hierarchy (its terminal detaches later).
    private func unmountPane() {
        guard let pane else { return }
        pane.willMove(toParent: nil)
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        self.pane = nil
        updateAccess()
    }

    /// Who takes touches and VoiceOver: Go to, else the pushed pane screen, else the list.
    private func updateAccess() {
        let shown = shown == true
        let covered = goTo != nil
        list?.view.isUserInteractionEnabled = !shown && !covered
        list?.view.accessibilityElementsHidden = shown || covered
        card.isUserInteractionEnabled = shown && !covered
        card.accessibilityElementsHidden = !shown || covered
        card.accessibilityViewIsModal = shown && !covered
        goCard.isUserInteractionEnabled = covered
        goCard.accessibilityElementsHidden = !covered
        goCard.accessibilityViewIsModal = covered
        let swipes = (shown && pane != nil) || covered
        if swipe.pan.isEnabled != swipes { swipe.pan.isEnabled = swipes }
    }

    // MARK: Moving

    /// The screens at `p`, at once.
    private func apply(_ p: CGFloat) {
        progress = p
        let p = min(max(p, 0), 1)
        card.transform = CGAffineTransform(translationX: Self.cardX(p, width), y: 0)
        list?.view.transform = CGAffineTransform(translationX: -0.3 * width * p, y: 0)
        dim.alpha = 0.1 * p
        card.isRounded = p > 0.0005 && p < 0.9995
    }

    private static func cardX(_ p: CGFloat, _ width: CGFloat) -> CGFloat {
        let scale = DisplayCorner.scale
        return ((1 - p) * width * scale).rounded(.down) / scale
    }

    /// The progress the frame on screen shows (mid-move too).
    private var drawnProgress: CGFloat {
        guard width > 0 else { return progress }
        return 1 - PhoneMotion.drawnTranslationX(card.layer) / width
    }

    private func stopMove() {
        moveID += 1
        move = nil
        for layer in [card.layer, list?.view.layer, dim.layer] { layer?.removeAnimation(forKey: Self.moveKey) }
    }

    /// From where the screens are drawn to `goal` on `spring`, starting at `velocity`
    /// (progress per second).
    private func animate(to goal: CGFloat, spring: PhoneSpring, velocity: Double) {
        let from = drawnProgress
        stopMove()
        apply(goal)
        let id = moveID
        guard width > 0, abs(from - goal) * width > 0.25 || abs(velocity) > 0.01 else {
            return DispatchQueue.main.async { [weak self] in
                guard let self, self.moveID == id else { return }
                self.moveEnded()
            }
        }
        let (duration, values) = spring.samples(from: Double(from), to: Double(goal), velocity: velocity)
        move = PhoneSpringMove(spring: spring, start: CACurrentMediaTime(), duration: duration,
                               from: Double(from), to: Double(goal), velocity: velocity)
        card.isRounded = true
        let w = width
        let end = PhoneAnimationEnd { [weak self] finished in
            guard finished, let self, self.moveID == id else { return }
            self.moveEnded()
        }
        PhoneMotion.keyframes(card.layer, PhoneMotion.translationX, values.map { Self.cardX(CGFloat($0), w) },
                              duration: duration, key: Self.moveKey, delegate: end)
        if let layer = list?.view.layer {
            PhoneMotion.keyframes(layer, PhoneMotion.translationX, values.map { -0.3 * w * CGFloat($0) },
                                  duration: duration, key: Self.moveKey)
        }
        PhoneMotion.keyframes(dim.layer, "opacity", values.map { 0.1 * CGFloat($0) }, duration: duration, key: Self.moveKey)
    }

    /// A move got to its end: square corners; popped, the pane screen goes.
    private func moveEnded() {
        move = nil
        card.isRounded = false
        if target == 0, controller.compactColumn != .detail { unmountPane() }
    }

    // MARK: The swipe back

    /// A finger took the pane screen: from where it is drawn (a push on its way in too).
    /// The keyboards go at once, as Telegram's chat ends editing.
    private func beginSwipe() -> CGFloat {
        controller.closeCompose()
        UIView.performWithoutAnimation {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        let p = min(max(drawnProgress, 0), 1)
        stopMove()
        apply(p)
        card.isRounded = true
        return p
    }

    private func drag(to p: CGFloat) {
        apply(p)
        card.isRounded = true
    }

    /// The finger left: the pop finishes or the pane screen goes back, from the finger's
    /// speed (`velocity`, points per second, rightward positive); a swipe the system cancelled
    /// goes back on the tap's spring.
    private func endSwipe(_ finish: Bool, velocity: CGFloat, cancelled: Bool) {
        let goal: CGFloat = finish ? 0 : 1
        target = goal
        let speed = cancelled ? 0 : Double(-velocity / max(1, width))
        animate(to: goal, spring: cancelled ? Self.push : Self.release, velocity: speed)
        guard finish else { return }
        // The pop is on its way to the render server before the app redraws for the list.
        CATransaction.flush()
        controller.showSidebar()
    }

    // MARK: Go to

    /// The controller's word: Go to up or not. Up, its screen comes up from under the
    /// screen (back from the right if it was on its way out); down, it goes to the right
    /// (and leaves the hierarchy at the end, `onGoToGone`).
    func setGoTo(_ presented: Bool) {
        guard presented != goPresented else { return }
        goPresented = presented
        if presented {
            let fresh = goTo == nil
            mountGoTo()
            if fresh { return enterGo() }
        } else {
            Self.putKeyboardAway()
        }
        let goal: CGFloat = presented ? 1 : 0
        guard goal != goTarget else { return }
        animateGo(to: goal, spring: Self.push, velocity: goMove?.velocity(at: CACurrentMediaTime()) ?? 0)
    }

    /// The keyboard goes, as it does: not at once (without animation the keyboard was gone
    /// while the screens, kept over it, grew back only at SwiftUI's next update, the
    /// window's black between).
    private static func putKeyboardAway() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Go to comes up from under the screen (across, at its place): its screen from the
    /// view's height to 0, the dim with it.
    private func enterGo() {
        stopGoMove()
        goTarget = 1
        applyGo(1)
        let h = view.bounds.height
        guard h > 0 else { return }
        let (duration, values) = Self.enter.samples(from: 0, to: 1, velocity: 0)
        goCard.isRounded = true
        let id = goMoveID
        let end = PhoneAnimationEnd { [weak self] finished in
            guard finished, let self, self.goMoveID == id else { return }
            self.goMoveEnded()
        }
        let scale = DisplayCorner.scale
        PhoneMotion.keyframes(goCard.layer, "transform.translation.y",
                              values.map { ((1 - CGFloat($0)) * h * scale).rounded() / scale },
                              duration: duration, key: Self.goEnterKey, delegate: end)
        PhoneMotion.keyframes(goDim.layer, "opacity", values.map { 0.1 * CGFloat($0) }, duration: duration,
                              key: Self.goEnterKey)
    }

    func stopObserving() {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
        keyboardObservers = []
    }

    /// Go to's card: over the keyboard, as the screens are without Go to. Its bottom 20 pt
    /// behind the keyboard where there's a home indicator: the field's bar keeps 28 pt
    /// over the card's bottom (over the home indicator with the keyboard down), so 8 pt
    /// over the keyboard. Its skirt goes on to the screen's bottom.
    private func layoutGoCard() {
        let b = view.bounds
        let tuck: CGFloat = view.safeAreaInsets.bottom > 0 ? 20 : 0
        let lift = keyboardOverlap > 0 ? max(0, keyboardOverlap - tuck) : 0
        let h = max(0, b.height - lift)
        goCard.bounds = CGRect(x: 0, y: 0, width: b.width, height: h)
        goCard.center = CGPoint(x: b.midX, y: h / 2)
        goSkirt.frame = CGRect(x: 0, y: h - 1, width: b.width, height: b.height - h + 1)
        goSkirt.backgroundColor = UIColor(host.theme.chrome)
    }

    /// The keyboard comes, goes or changes: Go to's card follows it on its own curve, set
    /// off here at once (the notification comes as the field takes or loses the keyboard),
    /// not at SwiftUI's next update.
    private func keyboardMoved(_ note: Notification, hiding: Bool) {
        guard let info = note.userInfo, let window = view.window,
              let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let frame = view.convert(end, from: window.screen.coordinateSpace)
        let overlap = hiding ? 0 : max(0, view.bounds.maxY - frame.minY)
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7
        guard goTo != nil, duration > 0 else { return layoutGoCard() }
        UIView.animate(withDuration: duration, delay: 0,
                       options: [UIView.AnimationOptions(rawValue: UInt(curve) << 16), .beginFromCurrentState]) {
            self.layoutGoCard()
            self.goCard.layoutIfNeeded()
        }
    }

    private func mountGoTo() {
        guard goTo == nil else { return }
        // The bottom's safe area goes to the field's bar (`PhoneGoToRoot`).
        let goTo = UIHostingController.moving(PhoneHosted(context: host, content: PhoneGoToRoot(context: host),
                                                          edges: [.top, .leading, .trailing]))
        goTo.view.backgroundColor = UIColor(host.theme.chrome)
        addChild(goTo)
        goTo.view.frame = goCard.content.bounds
        goTo.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        goCard.content.addSubview(goTo.view)
        goTo.didMove(toParent: self)
        self.goTo = goTo
        goCard.isHidden = false
        let off = KeyboardRegionOff()
        view.addSubview(off)
        keyboardRegionOff = off
        updateAccess()
    }

    private func unmountGoTo() {
        guard let goTo else { return }
        goTo.willMove(toParent: nil)
        goTo.view.removeFromSuperview()
        goTo.removeFromParent()
        self.goTo = nil
        goCard.isHidden = true
        keyboardRegionOff?.removeFromSuperview()
        keyboardRegionOff = nil
        updateAccess()
        onGoToGone()
    }

    /// Go to at `g` across, at once: its screen at (1 − g)·W.
    private func applyGo(_ g: CGFloat) {
        let g = min(max(g, 0), 1)
        goCard.transform = CGAffineTransform(translationX: Self.cardX(g, width), y: 0)
        goDim.alpha = 0.1 * g
        goCard.isRounded = g > 0.0005 && g < 0.9995
    }

    private var drawnGoProgress: CGFloat {
        guard width > 0 else { return goTarget }
        return 1 - PhoneMotion.drawnTranslationX(goCard.layer) / width
    }

    private func stopGoMove() {
        goMoveID += 1
        goMove = nil
        // Not its coming up (another key): a move across taking over goes on with it.
        for layer in [goCard.layer, goDim.layer] { layer.removeAnimation(forKey: Self.goKey) }
    }

    /// As `animate`, for Go to's screen across (no parallax under it).
    private func animateGo(to goal: CGFloat, spring: PhoneSpring, velocity: Double) {
        let from = drawnGoProgress
        stopGoMove()
        goTarget = goal
        applyGo(goal)
        let id = goMoveID
        guard width > 0, abs(from - goal) * width > 0.25 || abs(velocity) > 0.01 else {
            return DispatchQueue.main.async { [weak self] in
                guard let self, self.goMoveID == id else { return }
                self.goMoveEnded()
            }
        }
        let (duration, values) = spring.samples(from: Double(from), to: Double(goal), velocity: velocity)
        goMove = PhoneSpringMove(spring: spring, start: CACurrentMediaTime(), duration: duration,
                                 from: Double(from), to: Double(goal), velocity: velocity)
        goCard.isRounded = true
        let w = width
        let end = PhoneAnimationEnd { [weak self] finished in
            guard finished, let self, self.goMoveID == id else { return }
            self.goMoveEnded()
        }
        PhoneMotion.keyframes(goCard.layer, PhoneMotion.translationX, values.map { Self.cardX(CGFloat($0), w) },
                              duration: duration, key: Self.goKey, delegate: end)
        PhoneMotion.keyframes(goDim.layer, "opacity", values.map { 0.1 * CGFloat($0) }, duration: duration, key: Self.goKey)
    }

    /// Popped and not up: Go to's screen goes.
    private func goMoveEnded() {
        goMove = nil
        goCard.isRounded = false
        if goTarget == 0, !goPresented { unmountGoTo() }
    }

    /// The swipe back took Go to's screen: from where it's drawn; the keyboard goes.
    private func beginGoSwipe() -> CGFloat {
        Self.putKeyboardAway()
        let g = min(max(drawnGoProgress, 0), 1)
        stopGoMove()
        applyGo(g)
        goCard.isRounded = true
        return g
    }

    private func dragGo(to g: CGFloat) {
        applyGo(g)
        goCard.isRounded = true
    }

    /// As `endSwipe`, for Go to: popped, Go to is down (`showSwitcher`).
    private func endGoSwipe(_ finish: Bool, velocity: CGFloat, cancelled: Bool) {
        let goal: CGFloat = finish ? 0 : 1
        if finish { goPresented = false }
        let speed = cancelled ? 0 : Double(-velocity / max(1, width))
        animateGo(to: goal, spring: cancelled ? Self.push : Self.release, velocity: speed)
        guard finish else { return }
        CATransaction.flush()
        controller.showSwitcher = false
    }

    /// Lays the screens out with its size, hands its safe area down, puts the swipe on the window.
    private final class NavView: UIView {
        weak var nav: PhoneNavController?

        override func layoutSubviews() {
            super.layoutSubviews()
            nav?.laidOut()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            nav?.host.setInsets(safeAreaInsets)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            nav?.swipe.attach(to: window?.rootViewController?.view)
        }
    }
}

/// The pane screen's card: its content clipped (to the display's rounded corners while
/// it moves, `isRounded`) over a black shadow caster, shown only then.
final class PhoneCardView: UIView {
    /// Where the pane screen goes.
    let content = UIView()
    private let shadow = UIView()
    /// VoiceOver's escape (the two-finger scrub): back to the list.
    var onEscape: (() -> Void)?

    var isRounded = false {
        didSet { if isRounded != oldValue { restyle() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shadow.backgroundColor = .black
        shadow.isUserInteractionEnabled = false
        shadow.isHidden = true
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.04
        shadow.layer.shadowRadius = 12
        shadow.layer.shadowOffset = CGSize(width: 0, height: -3)
        shadow.layer.cornerCurve = .continuous
        content.clipsToBounds = true
        content.layer.cornerCurve = .continuous
        addSubview(shadow)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shadow.frame = bounds
        content.frame = bounds
        if isRounded { shadow.layer.shadowPath = path() }
    }

    private func restyle() {
        let radius = isRounded ? DisplayCorner.radius : 0
        content.layer.cornerRadius = radius
        shadow.layer.cornerRadius = radius
        shadow.isHidden = !isRounded
        if isRounded { shadow.layer.shadowPath = path() }
    }

    private func path() -> CGPath {
        UIBezierPath(roundedRect: bounds, cornerRadius: DisplayCorner.radius).cgPath
    }

    override func accessibilityPerformEscape() -> Bool {
        guard let onEscape else { return false }
        onEscape()
        return true
    }
}

/// The screen's corner radius (the cards' while they move; none in an iPad's narrow
/// window, which isn't at the screen's corners) and scale.
enum DisplayCorner {
    @MainActor static let radius: CGFloat = {
        guard Device.isPhone, let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first
        else { return 0 }
        let key = ["_display", "Corner", "Radius"].joined()
        guard screen.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (screen.value(forKey: key) as? CGFloat) ?? 0
    }()

    @MainActor static var scale: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 3
    }
}

// MARK: - Swipe back

/// The swipe that pops the pane screen, Telegram's (`InteractiveTransitionGestureRecognizer`
/// on its navigation container): a pan on the window's root view, so it sees touches on
/// everything over the pane screen. It may start anywhere but the rightmost 16 pt and only
/// goes right; it begins after 2 pt of a mostly horizontal move (from the left 16 pt, at
/// UIKit's threshold), fails on a move left or a vertical one, and every other pan on the
/// screen (the terminal's, the message field's, the keys' column) waits for it to fail, so
/// a swipe right always goes back. Except: with the key panel out, its own swipe right
/// (which puts the panel back) goes first; over a terminal's selection a drag extends the
/// selection.
///
/// It reports the progress the finger sets (the finger's travel over the width, from where
/// the pane screen was drawn when it took it) and, at the end, whether the pop finishes
/// and the speed to hand over (`PhonePopTracker`).
@MainActor
final class PhoneBackSwipe: NSObject, UIGestureRecognizerDelegate {
    let pan = PhoneBackSwipeRecognizer()
    /// The finger took the pane screen: the progress it is drawn at.
    var onBegin: () -> CGFloat = { 1 }
    var onDrag: (CGFloat) -> Void = { _ in }
    /// Finishes (pops), the hand-off speed in points per second, cancelled by the system.
    var onEnd: (Bool, CGFloat, Bool) -> Void = { _, _, _ in }

    private var tracker = PhonePopTracker(width: 1)
    /// The progress the pane screen was drawn at when the finger took it.
    private var start: CGFloat = 1
    private let boost = PhoneFrameRateBoost()

    override init() {
        super.init()
        pan.delegate = self
        pan.isEnabled = false
        pan.addTarget(self, action: #selector(moved(_:)))
    }

    func attach(to view: UIView?) {
        guard let view, pan.view !== view else { return }
        detach()
        view.addGestureRecognizer(pan)
    }

    func detach() {
        pan.view?.removeGestureRecognizer(pan)
    }

    @objc private func moved(_ g: PhoneBackSwipeRecognizer) {
        guard let view = g.view else { return }
        let width = max(1, view.bounds.width)
        let x = g.location(in: view).x - g.firstLocation.x
        let v = g.velocity(in: view).x
        let now = CACurrentMediaTime()
        // The pane screen's left edge: where it was taken plus the finger's travel, within the screen.
        let position = min(max(1 - start + x / width, 0), 1)
        switch g.state {
        case .began:
            boost.start()
            start = onBegin()
            tracker = PhonePopTracker(width: width)
            tracker.add(time: now, translation: x, velocity: v, isChange: false)
            onDrag(1 - min(max(1 - start + x / width, 0), 1))
        case .changed:
            tracker.add(time: now, translation: x, velocity: v, isChange: true)
            onDrag(1 - position)
        case .ended:
            boost.stop()
            tracker.add(time: now, translation: x, velocity: v, isChange: false)
            let r = tracker.release(position: position, velocity: v)
            onEnd(r.finish, r.velocity, false)
        case .cancelled, .failed:
            boost.stop()
            onEnd(false, 0, true)
        default:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = g.view else { return false }
        // Not the rightmost 16 pt (Telegram's edge).
        if touch.location(in: view).x > view.bounds.width - PhoneBackSwipeRecognizer.edge { return false }
        // A drag over a terminal's selection extends it.
        if let terminal = WierdrTerminalView.under(touch), terminal.hasActiveSelection { return false }
        return true
    }

    // With the key panel out, its swipe right puts the panel back first.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard other.name == PhoneKeyPanelGestures.panName else { return false }
        return (other.delegate as? PhoneKeyPanelGestures.Coordinator)?.parent?.isOpen == true
    }

    // Every other pan waits for it (it fails at once on a vertical move or one to the
    // left), not the root view's own (the key panel's). Only pans: a held finger never
    // fails a pan, so the terminal's long press (its menu) or a held key would wait.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view !== g.view
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
}

/// Telegram's start rule for a swipe that only goes right: it fails at once on a move
/// left, or on a vertical one (more than 2 pt, twice the horizontal), begins after 2 pt
/// of a mostly horizontal move (UIKit's pan waits ~10 pt), and after 10 pt of travel the
/// dominant axis decides. A touch from the left 16 pt is a swipe at UIKit's own threshold.
final class PhoneBackSwipeRecognizer: UIPanGestureRecognizer {
    static let edge: CGFloat = 16
    /// Where the touch went down (the finger's travel is measured from it).
    private(set) var firstLocation: CGPoint = .zero
    private var validated = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
        delaysTouchesBegan = false
    }

    override func reset() {
        super.reset()
        validated = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first, let view { firstLocation = touch.location(in: view) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else { return super.touchesMoved(touches, with: event) }
        let p = touch.location(in: view)
        let dx = p.x - firstLocation.x, dy = p.y - firstLocation.y
        var fire = false
        if !validated {
            if firstLocation.x < Self.edge {
                validated = true
            } else if dx < 0 {
                state = .failed
                return
            } else if hypot(dx, dy) > 10 {
                guard abs(dx) >= abs(dy) else { state = .failed; return }
                validated = true
                fire = true
            } else if abs(dy) > 2 && abs(dy) > abs(dx) * 2 {
                state = .failed
                return
            } else if abs(dx) > 2 && abs(dy) * 2 < abs(dx) {
                validated = true
                fire = true
            }
        }
        guard validated else { return }
        super.touchesMoved(touches, with: event)
        if fire && state == .possible { state = .began }
    }
}

/// When a swipe back is let go, whether the pop finishes and at what speed the pane
/// screen goes on: UIKit's rule for its Liquid Glass navigation, as Telegram has it. The
/// finger's speed (widths per second) is averaged over the last three samples, with its
/// acceleration (changing by at most 5 per sample; samples closer than 10 ms apart are
/// dropped unless the finger moved). The pop finishes when the position projected 0.35 s
/// ahead (with that speed and acceleration) is past 187.5 pt (or half the width if less);
/// with fewer than three samples, when the finger went right at least 10 pt. The speed
/// handed over is the last sample's, ×4.25 while the swipe is still an edge flick (its
/// average speed never fell under 1.5 widths per second).
struct PhonePopTracker {
    private let width: CGFloat
    private var count = 0
    private var flick = false
    private var sawChange = false
    private var averageVelocity: CGFloat = 0
    private var averageAcceleration: CGFloat = 0
    private var lastAcceleration: CGFloat = 0
    private var lastTranslation: CGFloat = 0
    private var previousTime: Double = 0
    private var skipTime: Double = 0
    private var previousPosition: CGFloat = 0
    private var previousVelocity: CGFloat = 0
    private var velocities: [CGFloat] = [0, 0, 0]
    private var accelerations: [CGFloat] = [0, 0, 0]

    init(width: CGFloat) { self.width = max(1, width) }

    /// One event: the finger's travel and speed to the right, in points and points per second.
    mutating func add(time: Double, translation: CGFloat, velocity: CGFloat, isChange: Bool) {
        if isChange { sawChange = true }
        lastTranslation = translation
        let position = max(0, translation) / width
        let v = velocity / width
        guard count > 0 else {
            previousTime = time; skipTime = time
            previousPosition = position; previousVelocity = v
            averageVelocity = v; averageAcceleration = 0; lastAcceleration = 0
            velocities[0] = v; accelerations[0] = 0
            count = 1
            flick = true
            return
        }
        let since = time - skipTime
        skipTime = time
        guard since >= 0.01 || (since > 0.001 && position != previousPosition) else { return }
        let n = CGFloat(count), i = count % 3
        let dt = CGFloat(time - previousTime)
        averageVelocity = count <= 2 ? (averageVelocity * n + v) / (n + 1) : (3 * averageVelocity - velocities[i] + v) / 3
        velocities[i] = v
        if flick && abs(averageVelocity) < 1.5 { flick = false }
        var a = dt > 0 ? (v - previousVelocity) / dt : lastAcceleration
        if abs(a - lastAcceleration) > 5 { a = lastAcceleration + (a > lastAcceleration ? 5 : -5) }
        averageAcceleration = count <= 2 ? (averageAcceleration * n + a) / (n + 1) : (3 * averageAcceleration - accelerations[i] + a) / 3
        accelerations[i] = a
        lastAcceleration = a
        previousVelocity = v
        previousPosition = position
        previousTime = time
        count += 1
    }

    /// `position`: the pane screen's left edge over the width when let go; `velocity`: the pan's, points per second.
    func release(position: CGFloat, velocity: CGFloat) -> (finish: Bool, velocity: CGFloat) {
        var finish: Bool
        var handOff: CGFloat
        if count >= 3 && sawChange {
            let t: CGFloat = 0.35
            let projected = position + averageVelocity * t + 0.5 * averageAcceleration * t * t
            finish = projected > min(187.5 / width, 0.5)
            handOff = width * previousVelocity
        } else {
            finish = averageVelocity > 0 && sawChange && lastTranslation >= 10
            handOff = velocity
        }
        if flick { handOff *= 4.25 }
        return (finish, handOff)
    }
}

// MARK: - Attention banner

/// While you are in a pane, another agent that starts waiting for you
/// ("needs you") or finishes ("done") slides a banner in from the top, with
/// a tap to go there. The list shows these changes by itself, so no banner there.
private struct AttentionBanner: View {
    var showing: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var last: [String: AgentStatus] = [:]
    /// The connection was live at the last update (a reconnect's refill is not news).
    @State private var wasLive = false
    @State private var banner: Banner?
    @State private var hide: Task<Void, Never>?

    struct Banner: Equatable {
        var id = UUID()
        var paneID: String
        var status: AgentStatus
        var title: String
        var space: Space
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let banner {
                card(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }
        }
        .animation(.snappy(duration: 0.3), value: banner)
        .sensoryFeedback(trigger: banner?.id) { _, _ in
            guard let banner else { return nil }
            return banner.status == .blocked ? .warning : .success
        }
        .onChange(of: statusKey, initial: true) { _, _ in update() }
        .onChange(of: controller.workspace.phase) { _, phase in
            guard phase == .live else { wasLive = false; return }
            // Back live without any status change: news count again after the refill.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if controller.workspace.phase == .live { wasLive = true }
            }
        }
        .onChange(of: showing) { _, showing in if !showing { banner = nil } }
        #if DEBUG
        .task(id: showing) {
            // `-open banner`: show one for the first agent that needs you (screenshots).
            guard showing, UserDefaults.standard.string(forKey: "open") == "banner" else { return }
            try? await Task.sleep(for: .seconds(1))
            let ws = controller.workspace
            if let t = ws.terminals.values.first(where: { $0.status == .blocked }), let l = ws.pane(showing: t.address) {
                show(Banner(paneID: l.pane.id, status: .blocked, title: Format.agentTitle(t, tab: l.tab), space: l.space))
            }
        }
        #endif
    }

    /// Changes when any agent's status changes.
    private var statusKey: String {
        controller.workspace.terminals.values
            .compactMap { t in t.status.map { "\(t.address)=\($0.rawValue)" } }
            .sorted().joined(separator: ",")
    }

    private func update() {
        let ws = controller.workspace
        var now: [String: AgentStatus] = [:]
        for (address, t) in ws.terminals { if let s = t.status { now[address] = s } }
        let live = ws.phase == .live
        defer {
            last.merge(now) { _, new in new }
            wasLive = live
        }
        // Only fresh changes on a live connection (not the first snapshot or a reconnect's refill).
        guard live, wasLive, !last.isEmpty, showing else { return }
        let onScreen = Set(controller.onScreenPanes.compactMap(\.terminal))
        let fresh = now.filter { address, status in
            (status == .blocked || status == .done) && last[address].map { $0 != status } == true
                && !onScreen.contains(address) && ws.pane(showing: address) != nil
        }
        // Needs you beats done; then the most recent.
        guard let pick = fresh.max(by: { a, b in
            if a.value != b.value { return a.value < b.value }
            let ta = ws.terminals[a.key]?.statusChangedAt ?? .distantPast
            let tb = ws.terminals[b.key]?.statusChangedAt ?? .distantPast
            return ta < tb
        }), let location = ws.pane(showing: pick.key), let t = ws.terminals[pick.key] else { return }
        show(Banner(paneID: location.pane.id, status: pick.value,
                    title: Format.agentTitle(t, tab: location.tab), space: location.space))
    }

    private func show(_ b: Banner) {
        banner = b
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            banner = nil
        }
    }

    private func card(_ b: Banner) -> some View {
        Button {
            banner = nil
            controller.focus(pane: b.paneID)
        } label: {
            HStack(spacing: 10) {
                SpaceAvatar(space: b.space, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusMark(status: b.status)
                        Text(b.status == .blocked ? "Needs you" : "Done")
                            .font(.ui(12, .semibold))
                            .foregroundStyle(b.status == .blocked ? theme.blocked : theme.done)
                        Text(b.space.displayName)
                            .font(.ui(12))
                            .foregroundStyle(theme.dim)
                            .lineLimit(1)
                    }
                    Text(b.title)
                        .font(.ui(14.5, .medium))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Icon("chevron-right", size: 14, color: theme.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.popover, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.15), radius: 14, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressStyle())
        .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { v in
            if v.translation.height < -10 { banner = nil }
        })
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityLabel("\(b.status == .blocked ? "Needs you" : "Done"): \(b.title), \(b.space.displayName)")
        .accessibilityHint("Opens it")
    }
}
