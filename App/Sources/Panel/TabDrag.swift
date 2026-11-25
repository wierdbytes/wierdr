import SwiftUI
import UIKit
import WierdrModel

/// A tab's long press, as the sidebar's rows' and cards' (`SpaceDrag`, `SpaceListDragDrop`):
/// held 0.12 s, the tab shrinks; at 0.32 s it's lifted over a dim with its menu under it
/// (`ListMenuOverlay`, `TabMenu`). Moved on along the bar (or off the tab and its menu),
/// the menu goes and the tab follows the finger (`LiftedCard`), the space's other tabs
/// parting round its slot, a dashed capsule as wide as it; let go over the bar, it lands
/// in its slot and moves there (`tab.move`), off it, it flies back. A pointer's press
/// moved on drags at once; its secondary click shows the menu at once.
///
/// The press is `ListPressRecognizer` on the window's root view (`TabDragDrop`, attached by
/// `TabDragHost`), taking only touches on a tab; the tabs' markers (`TabMarker`) say where
/// they are. The bar shows the space's tabs in `lane`'s order while one is dragged, and
/// after a drop until the workspace has that order.
@MainActor
@Observable
final class TabDrag {
    struct Lane: Equatable {
        var space: String
        /// Left to right.
        var ids: [String]
    }

    /// The tab held for its menu: it shrinks, Telegram's way.
    var pressing: String?
    /// The tab the menu has lifted: hidden in the bar meanwhile (its picture is lifted).
    var menuLifted: String? {
        didSet {
            if (menuLifted != nil) != (oldValue != nil) { Tutorial.shared.report(\.listMenu, open: menuLifted != nil) }
        }
    }
    /// The tab being dragged: it shows as its slot.
    private(set) var dragged: String?
    /// Its space's tabs as the bar shows them meanwhile.
    private(set) var lane: Lane?

    @ObservationIgnored weak var controller: WorkspaceController?
    /// The bar's look, for the tab's pictures.
    @ObservationIgnored var theme = Theme.atomOneDark
    @ObservationIgnored let markers = NSHashTable<TabMarker.Marker>.weakObjects()
    /// The tabs' room on screen (`TabDragHost`'s view, behind the strip).
    @ObservationIgnored weak var strip: UIView?
    /// Where the finger holds the tab, from its top left corner.
    @ObservationIgnored var grab = CGPoint.zero
    /// The dragged tab's width with the gap after it (the room its slot takes).
    @ObservationIgnored private var room: CGFloat = 0
    @ObservationIgnored private var dropped = false
    /// The move failed while the tab was still landing: the bar goes back once it's down.
    @ObservationIgnored private var failedLanding = false
    @ObservationIgnored private var origin: Lane?
    @ObservationIgnored private var settling: Task<Void, Never>?

    /// The other tabs part as the sidebar's cards do.
    static let part = SpaceDrag.part
    private static let settleAfter: Duration = .seconds(2)

    // MARK: The bar's order

    func arranged(_ tabs: [Tab], space: String) -> [Tab] {
        guard let lane, lane.space == space else { return tabs }
        var rank: [String: Int] = [:]
        for (i, id) in lane.ids.enumerated() { rank[id] = i }
        return tabs.enumerated()
            .sorted { (rank[$0.element.id] ?? -1, $0.offset) < (rank[$1.element.id] ?? -1, $1.offset) }
            .map(\.element)
    }

    /// The workspace's tabs changed: once they're in the dropped order, the bar follows them.
    func settle() {
        guard dragged == nil, let lane, let ws = controller?.workspace else { return }
        if ws.space(lane.space)?.tabs.map(\.id) == lane.ids { self.lane = nil }
    }

    // MARK: The drag (`view`: the window)

    func begin(_ id: String, in view: UIView) {
        dropped = false
        failedLanding = false
        guard let ws = controller?.workspace, let tab = ws.tab(id), let space = ws.space(tab.spaceID) else { return }
        settling?.cancel()
        if let f = frame(of: id, in: view) { room = f.width + TabBar.spacing }
        let lane = Lane(space: space.id, ids: arranged(space.tabs, space: space.id).map(\.id))
        origin = lane
        withAnimation(Self.part) {
            dragged = id
            self.lane = lane
        }
    }

    /// Back over the bar.
    func enter(_ id: String, in view: UIView) {
        dropped = false
        if dragged != id { begin(id, in: view) }
    }

    /// The finger moved (called every frame while over the bar): the slot goes where the
    /// tab's left edge would be nearest, counted as if it weren't in the bar. Only a bar at
    /// rest is measured (every tab right after the one before it), as the sidebar's cards.
    func update(at p: CGPoint, in view: UIView) {
        guard let id = dragged, let lane, let at = lane.ids.firstIndex(of: id) else { return }
        let others = lane.ids.filter { $0 != id }
        guard !others.isEmpty else { return }
        let frames = tabFrames(in: view)
        for (a, b) in zip(lane.ids, lane.ids.dropFirst()) {
            guard let left = frames[a], let right = frames[b] else { continue }
            if abs(right.minX - left.maxX - TabBar.spacing) > 1 { return }
        }
        if let f = frames[id] { room = f.width + TabBar.spacing }
        let left = p.x - grab.x
        // Slot k is before others[k] (k == count: after the last).
        var best: (k: Int, d: CGFloat)?
        for k in 0...others.count {
            let before = k < others.count
            let tab = before ? others[k] : others[k - 1]
            guard let f = frames[tab] else { continue }
            let after = (before ? k : k - 1) >= at  // right of the slot now: left by its room without it
            let x = (before ? f.minX : f.maxX + TabBar.spacing) - (after ? room : 0)
            let d = abs(x - left)
            if best == nil || d < best!.d { best = (k, d) }
        }
        guard let k = best?.k, k != at else { return }
        var ids = others
        ids.insert(id, at: k)
        withAnimation(Self.part) { self.lane = Lane(space: lane.space, ids: ids) }
    }

    /// Off the bar: the slot goes back where the tab was.
    func exit() {
        guard dragged != nil, !dropped, let origin, lane != origin else { return }
        withAnimation(Self.part) { lane = origin }
    }

    /// Flown back into its slot (let go off the bar): it shows there again.
    func cancelled() {
        guard dragged != nil, !dropped else { return }
        dragged = nil
        lane = nil
        origin = nil
    }

    /// Let go over the bar: the tab moves to its slot.
    func drop() {
        guard let id = dragged, let lane, let at = lane.ids.firstIndex(of: id) else { return }
        dropped = true
        if controller?.workspace.space(lane.space)?.tabs.map(\.id) != lane.ids {
            controller?.moveTab(id, to: at) { [weak self] in self?.failed(lane) }
        }
    }

    func slotFrame(in view: UIView) -> CGRect? {
        dragged.flatMap { frame(of: $0, in: view) }
    }

    /// Landed or flown back: the drag is over.
    func end() {
        if dropped, dragged != nil, failedLanding {
            failedLanding = false
            withAnimation(Self.part) {
                dragged = nil
                lane = nil
            }
            origin = nil
        } else if dropped, dragged != nil {
            dragged = nil
            origin = nil
            settle()
            if lane != nil {
                settling?.cancel()
                settling = Task { [weak self] in
                    try? await Task.sleep(for: Self.settleAfter)
                    guard let self, !Task.isCancelled, self.dragged == nil else { return }
                    withAnimation(Self.part) { self.lane = nil }
                }
            }
        }
        dropped = false
    }

    /// The move didn't take (the demo's never does): the bar shows the workspace's order
    /// again, once the tab has landed.
    private func failed(_ lane: Lane) {
        guard self.lane == lane else { return }
        settling?.cancel()
        if dragged != nil { failedLanding = true; return }
        withAnimation(Self.part) {
            dragged = nil
            self.lane = nil
        }
    }

    // MARK: Where the tabs are

    func tabFrames(in view: UIView) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for m in markers.allObjects {
            guard let id = m.id, m.window != nil else { continue }
            out[id] = m.convert(m.bounds, to: view)
        }
        return out
    }

    func frame(of id: String, in view: UIView) -> CGRect? {
        markers.allObjects.first { $0.id == id && $0.window != nil }.map { $0.convert($0.bounds, to: view) }
    }

    /// The tab at `p` (in `view`), where the bar shows it (not scrolled out under its ends).
    func tab(at p: CGPoint, in view: UIView) -> String? {
        guard let strip, strip.window != nil, strip.convert(strip.bounds, to: view).contains(p) else { return nil }
        return markers.allObjects.first { m in
            m.id != nil && m.window != nil && m.convert(m.bounds, to: view).contains(p)
        }?.id
    }

    /// The strip's scroll view (the markers' nearest).
    var scrollView: UIScrollView? {
        var view = markers.allObjects.first { $0.window != nil }?.superview
        while let v = view, !(v is UIScrollView) { view = v.superview }
        return view as? UIScrollView
    }
}

// MARK: - Markers

/// An empty view behind a tab, so the drag can ask UIKit where it is now.
struct TabMarker: UIViewRepresentable {
    var id: String
    var markers: NSHashTable<Marker>

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.id = id
        markers.add(view)
    }

    final class Marker: UIView {
        var id: String?
    }
}

/// Behind the tab strip: its room for the drag (`TabDrag.strip`), and the press put on the
/// window's root view while it's in a window.
struct TabDragHost: UIViewRepresentable {
    var drag: TabDrag
    var controller: WorkspaceController
    var theme: Theme

    func makeCoordinator() -> TabDragDrop { TabDragDrop(drag: drag) }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.dragDrop = context.coordinator
        drag.strip = anchor
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        drag.controller = controller
        drag.theme = theme
        drag.strip = anchor
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: TabDragDrop) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var dragDrop: TabDragDrop?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            dragDrop?.attach(to: window?.rootViewController?.view)
        }
    }
}

// MARK: - The press, the menu and the drag

@MainActor
final class TabDragDrop: NSObject, UIGestureRecognizerDelegate {
    let drag: TabDrag
    private weak var host: UIView?
    private lazy var press: ListPressRecognizer = {
        let press = ListPressRecognizer(target: self, action: #selector(pressed(_:)))
        press.delegate = self
        press.accepts = { [weak self] p in self?.holdable(at: p) != nil }
        press.dragsOnMove = { [weak self] p in self?.holdable(at: p) != nil }
        press.pressing = { [weak self] on in self?.pressing(on) }
        return press
    }()

    private var held: String?
    private var overlay: ListMenuOverlay?
    /// Where the menu came (the finger), in the window.
    private var openedAt: CGPoint = .zero

    private var card: LiftedCard?
    private var follower: CADisplayLink?
    private var finger: CGPoint = .zero
    private var dragging = false
    /// The finger is over the bar.
    private var dropping = false

    init(drag: TabDrag) {
        self.drag = drag
        super.init()
    }

    func attach(to view: UIView?) {
        guard let view, host !== view else { return }
        detach()
        host = view
        view.addGestureRecognizer(press)
    }

    func detach() {
        press.view?.removeGestureRecognizer(press)
        host = nil
    }

    /// Along with everything but a pan (the strip's scrolling, the overlay's swipes), as the
    /// sidebar's: begun, it takes the touch from the others (`takeTouch`).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other is UIPanGestureRecognizer)
    }

    /// The tab at `p` (in the root view), while nothing lies over the bar there: not under
    /// the sidebar's overlay or a sub-agent's window, not while a menu is out.
    private func holdable(at p: CGPoint) -> String? {
        guard let host, overlay == nil, card == nil, let controller = drag.controller,
              !controller.sidebarOverlay, controller.peek == nil else { return nil }
        return drag.tab(at: p, in: host)
    }

    /// The held tab shrinks (linearly, to 15 pt narrower, by the menu's time) or springs back.
    private func pressing(_ on: Bool) {
        if on, let host, let id = drag.tab(at: press.start, in: host) {
            withAnimation(.linear(duration: ListPressRecognizer.ramp)) { drag.pressing = id }
        } else if !on, drag.pressing != nil {
            withAnimation(.easeOut(duration: 0.2)) { drag.pressing = nil }
        }
    }

    @objc private func pressed(_ press: ListPressRecognizer) {
        guard let host, let window = host.window else { return }
        let p = press.location(in: window)
        finger = p
        switch press.state {
        case .began:
            guard let id = drag.tab(at: press.start, in: host) else { return }
            held = id
            takeTouch(from: press)
            if press.movedOff {
                startDragging(id)
            } else {
                openedAt = p
                openMenu(for: id, in: window)
            }
        case .changed:
            if dragging { return }
            guard let overlay, !overlay.dismissing, let id = held else { return }
            let local = overlay.convert(p, from: window)
            let dx = p.x - openedAt.x, dy = p.y - openedAt.y
            // Along the bar (mostly sideways), or off the tab and off its menu: the tab
            // follows the finger. Down onto the menu: its items light.
            let along = abs(dx) > 16 && abs(dx) > abs(dy) * 1.5
            let off = hypot(dx, dy) > 12 && !overlay.isOverItem(local, margin: 12)
            if !overlay.isOverMenu(local, margin: 24), along || off {
                closeMenuAtOnce()
                startDragging(id)
                return
            }
            overlay.fingerMoved(to: local)
        case .ended:
            if dragging {
                letGo(at: p)
            } else if let overlay {
                overlay.fingerLifted(at: overlay.convert(p, from: window))
            }
        case .cancelled, .failed:
            if dragging { letGo(at: nil) }
        default:
            break
        }
    }

    /// Begun, the press takes the touch from everything else on it (the tab's tap, the
    /// strip's scrolling).
    private func takeTouch(from press: ListPressRecognizer) {
        for other in press.touch?.gestureRecognizers ?? [] where other !== press && other.isEnabled {
            other.isEnabled = false
            other.isEnabled = true
        }
    }

    // MARK: The menu

    private func openMenu(for id: String, in window: UIWindow) {
        overlay?.removeFromSuperview()
        guard let controller = drag.controller, let tab = controller.workspace.tab(id),
              let frame = drag.frame(of: id, in: window), frame.width > 0,
              let picture = picture(of: tab, size: frame.size, style: .resting, in: window) else { return }
        let source = ListMenuOverlay.Source(
            identifier: "tab:\(id)", frame: frame, picture: picture, radius: frame.height / 2,
            menu: TabMenu.menu(tab: id, controller: controller),
            open: { [weak controller] in
                guard let controller, let tab = controller.workspace.tab(id) else { return }
                controller.select(tab: tab)
            })
        let overlay = ListMenuOverlay(source: source, dark: drag.theme.isDark, compact: false)
        overlay.returnFrame = { [weak self, weak window] in
            guard let self, let window else { return nil }
            return self.drag.frame(of: id, in: window)
        }
        overlay.onDismissed = { [weak self, weak overlay] in
            guard let self else { return }
            if self.overlay === overlay { self.overlay = nil }
            if self.drag.menuLifted == id { self.drag.menuLifted = nil }
        }
        self.overlay = overlay
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            drag.pressing = nil
            drag.menuLifted = id
        }
        overlay.present(in: window)
    }

    /// The menu went for the tab's drag: at once.
    private func closeMenuAtOnce() {
        overlay?.removeFromSuperview()
        overlay = nil
        drag.menuLifted = nil
    }

    private func picture(of tab: Tab, size: CGSize, style: TabPicture.Style, in window: UIWindow) -> UIImage? {
        guard let controller = drag.controller else { return nil }
        let content = TabPicture(tab: tab, style: style)
            .frame(width: size.width, height: size.height)
            .environment(controller)
            .environment(\.theme, drag.theme)
            .environment(\.tutorialAnchorsOff, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = window.traitCollection.displayScale
        return renderer.uiImage
    }

    // MARK: The drag

    /// Tab `id` lifts out of the bar and follows the finger, held where the touch came down.
    private func startDragging(_ id: String) {
        guard let host, let window = host.window, let controller = drag.controller,
              let tab = controller.workspace.tab(id), let frame = drag.frame(of: id, in: window) else { return }
        removeCard()
        let down = host.convert(press.start, to: window)
        drag.grab = CGPoint(x: down.x - frame.minX, y: down.y - frame.minY)
        let made = picture(of: tab, size: frame.size, style: .lifted, in: window).flatMap { lifted in
            picture(of: tab, size: frame.size, style: .resting, in: window).map { resting in
                LiftedCard(lifted: lifted, resting: resting, radius: frame.height / 2)
            }
        }
        drag.begin(id, in: window)
        dragging = true
        dropping = true
        guard let made else { return }
        made.frame.origin = frame.origin
        window.addSubview(made)
        card = made
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        follow()
        let link = CADisplayLink(target: self, selector: #selector(follow))
        link.add(to: .main, forMode: .common)
        follower = link
    }

    @objc private func follow() {
        guard dragging, let card, !card.landing, let window = card.superview, let id = drag.dragged else { return }
        card.frame.origin = CGPoint(x: finger.x - drag.grab.x, y: finger.y - drag.grab.y)
        let over = !isOffBar(finger, in: window)
        if over != dropping {
            dropping = over
            if over { drag.enter(id, in: window) } else { drag.exit() }
        }
        autoscroll(in: window)
        if dropping { drag.update(at: finger, in: window) }
    }

    /// Near the strip's ends (when its tabs don't all fit), it scrolls that way.
    private func autoscroll(in window: UIView) {
        guard dropping, let strip = drag.strip, let scroll = drag.scrollView else { return }
        let f = strip.convert(strip.bounds, to: window)
        let zone: CGFloat = 48, most: CGFloat = 10
        var step: CGFloat = 0
        if finger.x < f.minX + zone { step = -most * min(1, (f.minX + zone - finger.x) / zone) }
        if finger.x > f.maxX - zone { step = most * min(1, (finger.x - (f.maxX - zone)) / zone) }
        guard step != 0 else { return }
        let inset = scroll.adjustedContentInset
        let lowest = -inset.left
        let highest = max(lowest, scroll.contentSize.width + inset.right - scroll.bounds.width)
        let x = min(max(scroll.contentOffset.x + step, lowest), highest)
        if x != scroll.contentOffset.x { scroll.contentOffset.x = x }
    }

    /// Let go (nil: the touch was taken away): over the bar, the tab moves and lands in its
    /// slot; off it, it flies back.
    private func letGo(at point: CGPoint?) {
        follower?.invalidate()
        follower = nil
        dragging = false
        guard let host, let window = host.window else { return removeCard() }
        dropping = false
        if let point, !isOffBar(point, in: window) {
            drag.drop()
            guard let slot = drag.slotFrame(in: window) else {
                removeCard()
                drag.end()
                return
            }
            land(in: slot) { [drag] in drag.end() }
        } else {
            flyBack()
        }
    }

    /// The bar, and a band round it a finger drifts into.
    private func isOffBar(_ point: CGPoint, in view: UIView) -> Bool {
        guard let strip = drag.strip, strip.window != nil else { return true }
        return !strip.convert(strip.bounds, to: view).insetBy(dx: -24, dy: -36).contains(point)
    }

    private func land(in slot: CGRect, duration: TimeInterval = LiftedCard.landing, then done: @escaping () -> Void) {
        guard let card else { return done() }
        card.land(at: slot.origin, duration: duration) { [weak self, weak card] in
            done()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                card?.removeFromSuperview()
                if self?.card === card { self?.card = nil }
            }
        }
    }

    private func removeCard() {
        card?.removeFromSuperview()
        card = nil
    }

    /// Let go off the bar: the tab flies back into its slot, where it was.
    private func flyBack() {
        guard let card, !card.landing else {
            drag.cancelled()
            return
        }
        card.landing = true
        drag.exit()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.host?.window else { return }
            guard let slot = self.drag.slotFrame(in: window) else {
                self.removeCard()
                self.drag.cancelled()
                return
            }
            self.land(in: slot, duration: 0.3) { [drag = self.drag] in drag.cancelled() }
        }
    }
}

// MARK: - The menu's items

/// A tab's menu (`TabDragDrop`, VoiceOver's actions on the tab): Mark Idle or Mark Unread (as
/// the sidebar's rows', `unread`), Rename…; its focused pane's Split Right / Down, Zoom (with
/// more than one pane, under the pane's name, or while zoomed); Close Pane (with more than
/// one; else it's the tab), Close Tab. No New Tab: the bar's + has it.
@MainActor
enum TabMenu {
    static func menu(tab id: String, controller: WorkspaceController) -> PhoneMenu {
        let ws = controller.workspace
        guard let tab = ws.tab(id) else { return [] }
        var first: [PhoneMenuItem] = []
        if let unread = unread(tab, controller: controller) { first.append(unread) }
        first.append(PhoneMenuItem(title: "Rename…", icon: .asset("ui.square-pen")) { controller.beginRename(tab: id) })
        var menu: PhoneMenu = [first]
        let closeTab = PhoneMenuItem(title: "Close Tab", icon: .asset("ui.x"), destructive: true) { controller.closeTab(id) }
        guard let pane = controller.screen.focusedPane(of: tab) else { return menu + [[closeTab]] }
        let split = tab.panes.count > 1
        let zoomed = controller.screen.zoomedPane(of: tab) != nil
        var panes: [PhoneMenuItem] = []
        if split {
            panes.append(.caption(ws.terminal(pane.terminal).map { Format.paneName($0) } ?? (pane.mod ?? "panel")))
        }
        panes.append(PhoneMenuItem(title: "Split Right", icon: .asset("ui.split-right")) { controller.split(.right, pane: pane.id) })
        panes.append(PhoneMenuItem(title: "Split Down", icon: .asset("ui.split-down")) { controller.split(.down, pane: pane.id) })
        if split || zoomed {
            panes.append(PhoneMenuItem(title: zoomed ? "Unzoom" : "Zoom", icon: .asset(zoomed ? "ui.unzoom" : "ui.zoom")) {
                if let tab = controller.workspace.tab(id) { controller.select(tab: tab) }
                controller.toggleZoom(pane: pane.id)
            })
        }
        menu.append(panes)
        var close: [PhoneMenuItem] = []
        if split {
            close.append(PhoneMenuItem(title: "Close Pane", icon: .asset("ui.x"), destructive: true) { controller.closePane(pane.id) })
        }
        menu.append(close + [closeTab])
        return menu
    }

    /// As the sidebar's rows: while the tab is done (an agent of it is, its keyline green),
    /// Mark Idle (every done agent of it, `herdr.seen = turn`); else Mark Unread for the agent
    /// it's named after (`TabPill.subject`) when it's idle and can be (not a Codex saying
    /// idle); the active tab's too, as the sidebar's row of the agent on screen.
    private static func unread(_ tab: Tab, controller: WorkspaceController) -> PhoneMenuItem? {
        let ws = controller.workspace
        let done = tab.panes.compactMap { ws.terminal($0.terminal) }.filter { $0.isAgent && $0.status == .done }
        if !done.isEmpty {
            return PhoneMenuItem(title: "Mark Idle", icon: .system("circle")) {
                for t in done { controller.markRead(t.address) }
            }
        }
        guard let pane = TabPill.subject(of: tab, focused: controller.screen.focusedPane(of: tab), in: ws),
              let t = ws.terminal(pane.terminal), t.isAgent, t.status == .idle, t.canMarkUnread else { return nil }
        return PhoneMenuItem(title: "Mark Unread", icon: .system("circle.fill")) { controller.markUnread(t.address) }
    }
}
