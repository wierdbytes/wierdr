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
/// Telegram's (iOS 26's) motion, `PhoneNavCard`: the pane screen slides in from
/// the right edge over the full width, the list goes 0.3 of the width left under it
/// and dims (black, up to 10 %); while it moves, the pane screen has the display's
/// rounded corners and a faint shadow. A tap pushes or pops on a critically damped
/// spring (response 0.3 s). A swipe right anywhere on the pane screen
/// (`PhoneBackSwipe`) pops it with the finger; let go, it finishes or goes back by
/// UIKit's rule (`PhonePopTracker`) on a spring (response 0.3, damping 0.85) that
/// starts at the finger's speed.
struct PhoneWorkspaceView: View {
    @Environment(WorkspaceController.self) private var controller
    /// How much the pane screen covers the list: 0 the list alone, 1 the pane screen over it.
    @State private var progress: CGFloat = 0
    /// Where `progress` is headed: the last push, pop or swipe's end.
    @State private var target: CGFloat = 0
    /// The pane screen is in the hierarchy: pushed, or on its way in or out.
    @State private var mounted = false
    /// `progress` as the frame on screen draws it (mid-animation too).
    @State private var drawn = PhoneNavCard.Drawn()
    @State private var size: CGSize = CGSize(width: 430, height: 900)
    /// The window's safe area (never the keyboard) and height.
    @State private var window = WindowSafeArea.Metrics()
    /// The list's and the pane screen's area in the window: above the keyboard while it is up.
    @State private var frame: CGRect = .zero

    /// A push or a pop by a tap (or anything but a finger): critically damped, response 0.3 s.
    static let push = Animation.spring(duration: 0.3, bounce: 0)

    var body: some View {
        let shown = controller.compactColumn == .detail
        let width = max(1, size.width)
        ZStack {
            PhoneHome()
                .modifier(PhoneNavCard(role: .bottom, progress: progress, width: width))
                .allowsHitTesting(!shown)
                .accessibilityHidden(shown)
            // The list dims as the pane screen comes over it.
            Color.black.opacity(0.1 * min(max(progress, 0), 1))
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Group {
                if mounted {
                    PhonePaneScreen(covered: !shown)
                        .transition(.identity)
                }
            }
            .modifier(PhoneNavCard(role: .top, progress: progress, width: width, insets: cardInsets, drawn: drawn))
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { controller.showSidebar() }
        }
        // The size offered, whatever the content's: it is measured below for the cards' width,
        // so taking a wider content's size (maxWidth alone does) kept the landscape width back in
        // portrait, everything laid out 832 pt wide and centered in the 428-pt screen.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .top) { AttentionBanner(showing: shown) }
        .background {
            PhoneBackSwipe(
                enabled: shown && mounted,
                onBegin: beginSwipe,
                onDrag: { p in
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { progress = p }
                },
                onEnd: endSwipe
            )
            .frame(width: 0, height: 0)
        }
        .background { WindowSafeArea { window = $0 }.frame(width: 0, height: 0) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onChange(of: shown, initial: true) { _, shown in navigate(shown) }
        .onChange(of: controller.workspace.spaces) { old, new in
            // The pane on screen was closed (here, on the desktop, or its program
            // exited): back to the list rather than some other pane showing.
            guard shown, let id = Self.shownPane(controller.screen.snapshot, in: old),
                  !new.contains(where: { $0.tabs.contains { $0.panes.contains { $0.id == id } } }) else { return }
            controller.showSidebar()
        }
    }

    /// The safe area the pane screen's content gets back inside its edge-to-edge card: the
    /// window's, but none at the bottom while the keyboard is up (the card ends at it then).
    private var cardInsets: EdgeInsets {
        var insets = window.insets
        if window.height - frame.maxY > insets.bottom + 1 { insets.bottom = 0 }
        return insets
    }

    /// A push or a pop that no finger drives (a row, the back button, a status jump…).
    private func navigate(_ shown: Bool) {
        let goal: CGFloat = shown ? 1 : 0
        if !shown { controller.workspace.refreshLaunchers(machine: controller.activeSpace?.machine) }
        // The swipe's end already set off this very move.
        guard goal != target else { return }
        target = goal
        if shown { mounted = true }
        withAnimation(Self.push) { progress = goal } completion: { settle() }
    }

    /// A finger took the pane screen: from where it is drawn (a push on its way in too).
    /// The keyboards go at once, as Telegram's chat ends editing.
    private func beginSwipe() -> CGFloat {
        controller.closeCompose()
        UIView.performWithoutAnimation {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        return min(max(drawn.value, 0), 1)
    }

    /// The finger left: the pop finishes or the pane screen goes back, from the finger's
    /// speed (`velocity`, points per second, rightward positive); a swipe the system cancelled
    /// goes back on the tap's spring.
    private func endSwipe(_ finish: Bool, velocity: CGFloat, cancelled: Bool) {
        let goal: CGFloat = finish ? 0 : 1
        target = goal
        if finish { controller.showSidebar() }
        let delta = goal - progress
        // SwiftUI's initial velocity is in units of the whole change.
        let initial = abs(delta) > 0.001 ? min(max((-velocity / max(1, size.width)) / delta, -100), 100) : 0
        let animation = cancelled ? Self.push : .interpolatingSpring(duration: 0.3, bounce: 0.15, initialVelocity: initial)
        withAnimation(animation) { progress = goal } completion: { settle() }
    }

    /// A transition ended: popped, the pane screen leaves the hierarchy (its terminal detaches later).
    private func settle() {
        if target == 0, controller.compactColumn != .detail { mounted = false }
    }

    /// The pane the screen showed with these spaces (`ScreenState`'s resolution, fallbacks included).
    private static func shownPane(_ s: ScreenState.Snapshot, in spaces: [Space]) -> String? {
        guard let space = spaces.first(where: { $0.id == s.space }) ?? spaces.first else { return nil }
        guard let tab = space.tabs.first(where: { $0.id == s.tabBySpace[space.id] }) ?? space.tabs.first else { return nil }
        let panes = tab.panes
        return (panes.first { $0.id == s.focusByTab[tab.id] } ?? panes.first { $0.terminal != nil } ?? panes.first)?.id
    }
}

// MARK: - Cards

/// Where a screen of the push is drawn at `progress` (0 the list alone, 1 the pane screen
/// over it), as Telegram's (iOS 26's) navigation transition: the pane screen ("top") at
/// x = (1 − p)·W, pixel-rounded; the list ("bottom") at −0.3·W·p. Animatable, so a spring
/// that overshoots stops at either end, as Telegram's does (it halts at the first crossing).
///
/// While it moves, the top card has the display's rounded corners and Telegram's faint
/// shadow (black 4 %, radius 12, 3 pt up). Its content is laid out edge to edge with the
/// screen's safe area given back to it (`insets`), so the clip is the screen's outline and
/// the backgrounds that run into the safe area stay.
struct PhoneNavCard: ViewModifier, Animatable {
    enum Role { case bottom, top }

    /// The progress the frame on screen shows, kept out of SwiftUI's state (read when a finger takes over).
    final class Drawn { var value: CGFloat = 0 }

    var role: Role
    var progress: CGFloat
    var width: CGFloat
    var insets = EdgeInsets()
    var drawn: Drawn? = nil

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = drawnProgress()
        switch role {
        case .bottom:
            content.offset(x: -0.3 * width * p)
        case .top:
            let moving = p > 0.0005 && p < 0.9995
            let shape = RoundedRectangle(cornerRadius: moving ? DisplayCorner.radius : 0, style: .continuous)
            let scale = DisplayCorner.scale
            content
                .safeAreaPadding(insets)
                .ignoresSafeArea(.container)
                .clipShape(shape)
                .background {
                    if moving {
                        shape.fill(Color.black)
                            .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: -3)
                            .ignoresSafeArea(.container)
                    }
                }
                .offset(x: ((1 - p) * width * scale).rounded(.down) / scale)
        }
    }

    /// The progress within 0...1, after noting the frame's own for a finger that takes over.
    private func drawnProgress() -> CGFloat {
        drawn?.value = progress
        return min(max(progress, 0), 1)
    }
}

/// The window's safe area (never the keyboard's: SwiftUI's insets count it in) and height.
struct WindowSafeArea: UIViewRepresentable {
    struct Metrics: Equatable {
        var insets = EdgeInsets()
        var height: CGFloat = 0
    }

    var onChange: (Metrics) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
        probe.report()
    }

    final class Probe: UIView {
        var onChange: ((Metrics) -> Void)?
        private var last: Metrics?

        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }

        func report() {
            guard let window else { return }
            let i = window.safeAreaInsets
            let metrics = Metrics(insets: EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right),
                                  height: window.bounds.height)
            guard metrics != last else { return }
            last = metrics
            DispatchQueue.main.async { [weak self] in self?.onChange?(metrics) }
        }
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
struct PhoneBackSwipe: UIViewRepresentable {
    var enabled: Bool
    /// The finger took the pane screen: the progress it is drawn at.
    var onBegin: () -> CGFloat
    var onDrag: (CGFloat) -> Void
    /// Finishes (pops), the hand-off speed in points per second, cancelled by the system.
    var onEnd: (Bool, CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.pan.isEnabled != enabled { c.pan.isEnabled = enabled }
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
        var parent: PhoneBackSwipe?
        let pan = PhoneBackSwipeRecognizer()
        private var tracker = PhonePopTracker(width: 1)
        /// The progress the pane screen was drawn at when the finger took it.
        private var start: CGFloat = 1

        override init() {
            super.init()
            pan.delegate = self
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
            guard let parent, let view = g.view else { return }
            let width = max(1, view.bounds.width)
            let x = g.location(in: view).x - g.firstLocation.x
            let v = g.velocity(in: view).x
            let now = CACurrentMediaTime()
            // The pane screen's left edge: where it was taken plus the finger's travel, within the screen.
            let position = min(max(1 - start + x / width, 0), 1)
            switch g.state {
            case .began:
                start = parent.onBegin()
                tracker = PhonePopTracker(width: width)
                tracker.add(time: now, translation: x, velocity: v, isChange: false)
                parent.onDrag(1 - min(max(1 - start + x / width, 0), 1))
            case .changed:
                tracker.add(time: now, translation: x, velocity: v, isChange: true)
                parent.onDrag(1 - position)
            case .ended:
                tracker.add(time: now, translation: x, velocity: v, isChange: false)
                let r = tracker.release(position: position, velocity: v)
                parent.onEnd(r.finish, r.velocity, false)
            case .cancelled, .failed:
                parent.onEnd(false, 0, true)
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
