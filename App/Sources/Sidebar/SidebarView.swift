import SwiftUI
import UIKit
import WierdrModel

/// The sidebar, one for the iPhone (the list screen under the pane screen) and the iPad
/// (the split view's column and the overlay over a hidden one), turned for one hand. Two
/// screens in it, as a navigation of its own (`SidebarNavController`): the spaces
/// (`SpacesSidebar`), and over them, pushed from the right by the status ring's tap or
/// ⌘P, the agents panel (`AgentsPanel`), which a swipe right puts back.
///
/// In the iPhone layout the connection's banner and the toasts show over both, where the
/// header and the panel's field are (the iPad's panel has its own).
struct SidebarView: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var insets = EdgeInsets()

    var body: some View {
        let bottomGap = SidebarHeader.bottomGap(safeBottom: insets.bottom)
        let headerHeight = SidebarHeader.height + bottomGap
        ZStack(alignment: .bottom) {
            // The screens fill it, their grounds under the status bar and the home indicator;
            // they lay out in its safe area, handed down (`PhoneHostContext`).
            SidebarNavigation(insets: insets, agents: controller.showAgents, atOnce: controller.agentsAtOnce)
                .ignoresSafeArea(.container)
            if controller.singlePane, case .failed = controller.workspace.phase {
                // The reason and Retry, over the header (its title says "Not Connected").
                ConnectionBanner(inset: headerHeight + 8, edge: .bottom)
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .overlay(alignment: .bottom) {
            if controller.singlePane {
                // Over the header (this overlay keeps to the safe area).
                ToastStack().padding(.horizontal, 12).padding(.bottom, headerHeight - insets.bottom + 10)
            }
        }
        .background(theme.chrome.ignoresSafeArea())
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
    }
}

/// The sidebar's spaces: the space cards drawn bottom up (`SpacesList`: the first space
/// lowest, each card's agents in the iPhone's rows, the newest and pinned lowest), and the
/// header floating over the list's bottom (`SidebarHeader`: the limits, the agents' ring
/// that opens the agents panel, +). The list runs to the screen's top (its rows scroll
/// under the status bar) and under the header.
struct SpacesSidebar: View {
    @Environment(\.theme) private var theme
    @State private var safeTop: CGFloat = 0
    @State private var safeBottom: CGFloat = 0

    var body: some View {
        let bottomGap = SidebarHeader.bottomGap(safeBottom: safeBottom)
        let headerHeight = SidebarHeader.height + bottomGap
        ZStack(alignment: .bottom) {
            SpacesList(topInset: safeTop, bottomInset: headerHeight)
            PhoneEdgeFade(edge: .top, height: PhoneEdgeFade.statusBar(safeTop))
                .frame(maxHeight: .infinity, alignment: .top)
            PhoneEdgeFade(edge: .bottom, height: headerHeight)
            SidebarHeader()
                .padding(.bottom, bottomGap)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .background(theme.chrome.ignoresSafeArea())
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: {
            safeTop = $0.top
            safeBottom = $0.bottom
        }
    }
}

/// The spaces and the agents panel in their UIKit container (`SidebarNavController`).
private struct SidebarNavigation: UIViewControllerRepresentable {
    /// The sidebar's safe area, which its screens lay out in.
    var insets: EdgeInsets
    /// The agents panel is up (`showAgents`).
    var agents: Bool
    /// …without its push (`agentsAtOnce`).
    var atOnce: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(LiveConnector.self) private var connector: LiveConnector?

    func makeUIViewController(context: Context) -> SidebarNavController {
        SidebarNavController(host: PhoneHostContext(context.environment, controller: controller, app: app, connector: connector))
    }

    func updateUIViewController(_ nav: SidebarNavController, context: Context) {
        nav.host.update(context.environment)
        nav.menusLook(theme: context.environment.theme, compact: context.environment.isCompactLayout)
        nav.host.setInsets(UIEdgeInsets(top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing))
        nav.setShown(agents, animated: !atOnce)
    }

    static func dismantleUIViewController(_ nav: SidebarNavController, coordinator: ()) {
        nav.swipe.detach()
    }
}

/// The sidebar's two screens, moved as the iPhone's pane screen over its list
/// (`PhoneNavController`), by Core Animation at a progress (0 the spaces alone, 1 the
/// agents panel over them): the panel at x = (1 − p)·W, its card (`PhoneCardView`) with
/// the display's corners (the iPhone's; none on the iPad) and a faint shadow while it
/// moves; the spaces at −0.3·W·p under a black dim of 0.1·p. Pushed and popped on the
/// same springs (`PhoneNavController.push`, `.release`), and a swipe right anywhere on
/// the panel (`PhoneBackSwipe`, on this container's view, which stays put, while the panel
/// is up: Telegram's start rule, every other pan there waits for it, UIKit's release rule)
/// pops it with the finger; where a row's own swipe takes the touch (its edge zones, an
/// open row) that goes first (`yieldsToRows`). The panel's rows have the spaces list's
/// long-press menu, its own press on the panel's view (`SpaceListDragDrop` with the panel's
/// `SpaceDrag`, `menus`). The panel leaves the hierarchy once popped. Its bounds clip the screens: on the iPad the panel comes from
/// the sidebar's right edge, not over the panes.
final class SidebarNavController: UIViewController {
    let host: PhoneHostContext
    let swipe = PhoneBackSwipe()
    /// The panel's rows' menus: their markers, the held and the lifted row.
    private let menus = SpaceDrag()
    /// The press that opens them, on the panel's view.
    private lazy var press = SpaceListDragDrop(drag: menus)

    private var base: UIHostingController<PhoneHosted<SpacesSidebar>>!
    private let dim = UIView()
    private let card = PhoneCardView()
    /// The agents panel: pushed, or on its way in or out.
    private var panel: UIHostingController<PhoneHosted<AgentsPanelRoot>>?
    /// The panel is up (`showAgents`); nil before the first update.
    private var shown: Bool?
    /// Where the screens are headed: the last push, pop or swipe's end.
    private var target: CGFloat = 0
    private var move: PhoneSpringMove?
    private var moveID = 0
    private var width: CGFloat = 0

    private static let moveKey = "agents"

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
        view.clipsToBounds = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        base = .moving(PhoneHosted(context: host, content: SpacesSidebar()))
        addChild(base)
        view.addSubview(base.view)
        base.didMove(toParent: self)
        dim.backgroundColor = .black
        dim.alpha = 0
        dim.isUserInteractionEnabled = false
        dim.isAccessibilityElement = false
        view.addSubview(dim)
        card.onEscape = { [weak self] in self?.controller.closeAgents() }
        card.isHidden = true
        view.addSubview(card)
        // On the container, not the card: the finger's travel is measured in a view that
        // doesn't move with it (on the card, each step shifted the next one's place).
        swipe.attach(to: view)
        swipe.yieldsToRows = true
        menus.controller = controller
        swipe.onBegin = { [weak self] in self?.beginSwipe() ?? 1 }
        swipe.onDrag = { [weak self] p in self?.drag(to: p) }
        swipe.onEnd = { [weak self] finish, velocity, cancelled in
            self?.endSwipe(finish, velocity: velocity, cancelled: cancelled)
        }
        apply(target)
        updateAccess()
    }

    fileprivate func laidOut() {
        let bounds = view.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Bounds and center, not frames: the layers carry the move's translation.
        for v in [base.view!, card] {
            v.bounds = CGRect(origin: .zero, size: bounds.size)
            v.center = center
        }
        dim.frame = bounds
        guard bounds.width != width else { return }
        // A new width (first layout, rotation, the iPad's sidebar resized): at the move's end, at once.
        width = bounds.width
        stopMove()
        apply(target)
        moveEnded()
    }

    // MARK: Showing

    /// The controller's word: the panel up or not. A change pushes or pops it, or (not
    /// `animated`, or the first word) puts it there at once.
    func setShown(_ shown: Bool, animated: Bool) {
        let first = self.shown == nil
        guard shown != self.shown else { return }
        self.shown = shown
        if shown { mountPanel() } else { AgentsSearchUITextField.resignActive() }
        updateAccess()
        let goal: CGFloat = shown ? 1 : 0
        // The swipe's end already set off this very move.
        guard goal != target || first else { return }
        target = goal
        guard animated, !first, width > 0 else {
            stopMove()
            apply(goal)
            return moveEnded()
        }
        animate(to: goal, spring: PhoneNavController.push, velocity: move?.velocity(at: CACurrentMediaTime()) ?? 0)
    }

    private func mountPanel() {
        guard panel == nil else { return }
        // The bottom's safe area goes to the field's bar (`AgentsPanelRoot`).
        let panel = UIHostingController.moving(PhoneHosted(context: host, content: AgentsPanelRoot(context: host, menus: menus),
                                                           edges: [.top, .leading, .trailing]))
        panel.view.backgroundColor = UIColor(host.theme.chrome)
        addChild(panel)
        panel.view.frame = card.content.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.content.addSubview(panel.view)
        panel.didMove(toParent: self)
        press.attach(list: panel.view)
        self.panel = panel
        card.isHidden = false
    }

    /// The menus' look (the lifted row's, the overlay's dim).
    func menusLook(theme: Theme, compact: Bool) {
        if menus.theme != theme { menus.theme = theme }
        menus.compact = compact
    }

    /// Popped: the panel leaves the hierarchy (its query with it).
    private func unmountPanel() {
        guard let panel else { return }
        press.detach()
        panel.willMove(toParent: nil)
        panel.view.removeFromSuperview()
        panel.removeFromParent()
        self.panel = nil
        card.isHidden = true
        updateAccess()
    }

    /// Who takes touches and VoiceOver: the panel while it's up, else the spaces.
    private func updateAccess() {
        let up = shown == true
        base?.view.isUserInteractionEnabled = !up
        base?.view.accessibilityElementsHidden = up
        card.isUserInteractionEnabled = up
        card.accessibilityElementsHidden = !up
        let swipes = up && panel != nil
        if swipe.pan.isEnabled != swipes { swipe.pan.isEnabled = swipes }
    }

    // MARK: Moving

    /// The screens at `p`, at once.
    private func apply(_ p: CGFloat) {
        let p = min(max(p, 0), 1)
        card.transform = CGAffineTransform(translationX: Self.cardX(p, width), y: 0)
        base?.view.transform = CGAffineTransform(translationX: -0.3 * width * p, y: 0)
        dim.alpha = 0.1 * p
        card.isRounded = p > 0.0005 && p < 0.9995
    }

    private static func cardX(_ p: CGFloat, _ width: CGFloat) -> CGFloat {
        let scale = DisplayCorner.scale
        return ((1 - p) * width * scale).rounded(.down) / scale
    }

    /// The progress the frame on screen shows (mid-move too).
    private var drawnProgress: CGFloat {
        guard width > 0 else { return target }
        return 1 - PhoneMotion.drawnTranslationX(card.layer) / width
    }

    private func stopMove() {
        moveID += 1
        move = nil
        for layer in [card.layer, base?.view.layer, dim.layer] { layer?.removeAnimation(forKey: Self.moveKey) }
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
        if let layer = base?.view.layer {
            PhoneMotion.keyframes(layer, PhoneMotion.translationX, values.map { -0.3 * w * CGFloat($0) },
                                  duration: duration, key: Self.moveKey)
        }
        PhoneMotion.keyframes(dim.layer, "opacity", values.map { 0.1 * CGFloat($0) }, duration: duration, key: Self.moveKey)
    }

    /// A move got to its end: square corners; popped, the panel goes.
    private func moveEnded() {
        move = nil
        card.isRounded = false
        if target == 0, shown != true { unmountPanel() }
    }

    // MARK: The swipe back

    /// A finger took the panel: from where it is drawn (a push on its way in too). The
    /// keyboard goes, as it does (not at once: on the iPhone the screens are kept over it).
    private func beginSwipe() -> CGFloat {
        AgentsSearchUITextField.resignActive()
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

    /// The finger left: the pop finishes or the panel goes back, from the finger's speed
    /// (`velocity`, points per second, rightward positive); a swipe the system cancelled
    /// goes back on the tap's spring.
    private func endSwipe(_ finish: Bool, velocity: CGFloat, cancelled: Bool) {
        let goal: CGFloat = finish ? 0 : 1
        target = goal
        if finish {
            shown = false
            updateAccess()
        }
        let speed = cancelled ? 0 : Double(-velocity / max(1, width))
        animate(to: goal, spring: cancelled ? PhoneNavController.push : PhoneNavController.release, velocity: speed)
        guard finish else { return }
        // The pop is on its way to the render server before the app redraws for it.
        CATransaction.flush()
        controller.closeAgents()
    }

    /// Lays the screens out with its size.
    private final class NavView: UIView {
        weak var nav: SidebarNavController?

        override func layoutSubviews() {
            super.layoutSubviews()
            nav?.laidOut()
        }
    }
}
