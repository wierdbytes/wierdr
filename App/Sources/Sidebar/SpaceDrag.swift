import SwiftUI
import UIKit
import WierdrModel

/// Dragging a space card to reorder it, as on the desktop (`wierd-agents`): the
/// card lifts and follows the finger, and where it would land the other cards of
/// its machine part around an empty slot (a dashed outline as tall as the card).
/// Let go over the list, it glides into the slot and the space moves there
/// (`space.move`); let go off the list, it flies back to where it was.
///
/// The drag is the list's own long press (`SpaceListDragDrop`: `ListPressRecognizer`
/// on the list's view, where its scrolling pan is, which shows a header's menu held, and
/// moved on lifts the card). The lifted card is drawn by
/// the app over the window (`LiftedCard`), the cards' markers (`SpaceMarker`) say
/// where the cards and their headers are, and `SpacesList` shows the machine's spaces
/// in `lane`'s order, the dragged one as its slot. The list is drawn bottom up (each block
/// in an upside-down host: the drag works in the window's coordinates): a lane's first
/// space is its lowest card.
@MainActor
@Observable
final class SpaceDrag {
    struct Lane: Equatable {
        var machine: String?
        /// In the workspace's order (drawn bottom up).
        var ids: [String]
    }

    /// The space being dragged over the list: its card shows as the slot.
    private(set) var dragged: String?
    /// What the list's menu has lifted (its identifier: `space:` or `row:` and the id):
    /// hidden in the list meanwhile, as UIKit hides a view it lifts itself; else the row
    /// showed through its picture, scaled, as a doubled text.
    var menuLifted: String? {
        didSet {
            if (menuLifted != nil) != (oldValue != nil) { Tutorial.shared.report(\.listMenu, open: menuLifted != nil) }
        }
    }
    /// What the list's press is holding (as `menuLifted`): it shrinks, Telegram's way.
    var pressing: String?
    /// Its machine's spaces as the list shows them meanwhile, it at its slot. After
    /// a drop, until the workspace has them in this order (or gives up, `settleAfter`).
    private(set) var lane: Lane?

    @ObservationIgnored weak var controller: WorkspaceController?
    /// The list's look, for drawing the lifted card (set by the list).
    @ObservationIgnored var theme = Theme.atomOneDark
    @ObservationIgnored var compact = false
    /// Every card's and header's marker (weakly).
    @ObservationIgnored let markers = NSHashTable<SpaceMarker.Marker>.weakObjects()
    /// Every row's marker (weakly), for the rows' menus (`RowMenuMarker`).
    @ObservationIgnored let rowMarkers = NSHashTable<RowMenuMarkerView>.weakObjects()
    /// Where the finger holds the card, from its top left corner, and the card's
    /// height with the gap after it (the room its slot takes).
    @ObservationIgnored var grab = CGPoint(x: 0, y: 22)
    @ObservationIgnored private var height: CGFloat = 0
    @ObservationIgnored private var dropped = false
    /// The lane as it was when the drag came: where the slot goes back while the
    /// card is off the list.
    @ObservationIgnored private var origin: Lane?
    @ObservationIgnored private var settling: Task<Void, Never>?

    /// The other cards part as quickly as the desktop's (PART_MS).
    nonisolated static let part = Animation.easeOut(duration: 0.16)
    /// After a drop, how long the list keeps the new order without the workspace's word.
    private static let settleAfter: Duration = .seconds(2)

    // MARK: The list's order

    /// `spaces` (one machine's, in the workspace's order) as the list shows them now.
    func arranged(_ spaces: [Space], machine: String?) -> [Space] {
        guard let lane, lane.machine == machine else { return spaces }
        var rank: [String: Int] = [:]
        for (i, id) in lane.ids.enumerated() { rank[id] = i }
        // Spaces that came meanwhile (new ones go first) stay before the others, in their own order.
        return spaces.enumerated()
            .sorted { (rank[$0.element.id] ?? -1, $0.offset) < (rank[$1.element.id] ?? -1, $1.offset) }
            .map(\.element)
    }

    /// The workspace's spaces changed: once they're in the dropped order, the list
    /// follows them again.
    func settle() {
        guard dragged == nil, let lane, let ws = controller?.workspace else { return }
        if ws.spaces(on: lane.machine).map(\.id) == lane.ids { self.lane = nil }
    }

    // MARK: The drag (`list`: the window, points and frames in its coordinates: they're
    // the screen's, up being up, while each block's host is upside down)

    /// A drag of space `id` came over the list (at the start, or back).
    func enter(_ id: String, in list: UIView) {
        dropped = false
        if dragged != id { begin(id, in: list) }
    }

    /// A drag of space `id` started: its card is lifted, its place in the list is its slot.
    func begin(_ id: String, in list: UIView) {
        dropped = false
        guard let ws = controller?.workspace, let space = ws.space(id) else { return }
        settling?.cancel()
        let ids = arranged(ws.spaces(on: space.machine), machine: space.machine).map(\.id)
        if let card = cardFrames(in: list)[id] { height = card.height + SpacesList.gap }
        let lane = Lane(machine: space.machine, ids: ids)
        origin = lane
        withAnimation(Self.part) {
            dragged = id
            self.lane = lane
        }
    }

    /// The finger moved (or the list scrolled under it; called every frame while the drag
    /// is over the list): the slot goes where the card would land, the slot whose top is
    /// nearest the card's top, counted as if the card weren't in the list (desktop's
    /// `dragLayout`). The cards are drawn bottom up: the lane's last space is the top one.
    ///
    /// Only a list at rest is measured. While the cards part (`part`), SwiftUI moves their
    /// views frame by frame, so they're between their old places and their new ones: a
    /// slot that has just moved would be measured as belonging back where it was, and with
    /// the card's middle near another's it jumped to and fro. Once they're in place (every
    /// card right under the one over it in the lane's order), the next frame decides.
    func update(at p: CGPoint, in list: UIView) {
        guard let id = dragged, let lane else { return }
        let drawn = Array(lane.ids.reversed())  // top to bottom
        guard let at = drawn.firstIndex(of: id) else { return }
        let others = drawn.filter { $0 != id }
        guard !others.isEmpty else { return }
        let frames = cardFrames(in: list)
        // The list hasn't laid out the last move yet, or its cards are still on their way: wait.
        for (a, b) in zip(drawn, drawn.dropFirst()) {
            guard let over = frames[a], let under = frames[b] else { continue }
            if abs(under.minY - over.maxY - SpacesList.gap) > 1 { return }
        }
        if let card = frames[id], card.height + SpacesList.gap > height { height = card.height + SpacesList.gap }
        let top = p.y - grab.y
        // Slot k is over others[k] (k == count: under the last). Cards off screen
        // (not laid out) have no place; they're far from the finger anyway.
        var best: (k: Int, d: CGFloat)?
        for k in 0...others.count {
            let over = k < others.count
            let card = over ? others[k] : others[k - 1]
            guard let f = frames[card] else { continue }
            let below = (over ? k : k - 1) >= at  // drawn under the slot: up by its room without it
            let y = (over ? f.minY : f.maxY + SpacesList.gap) - (below ? height : 0)
            let d = abs(y - top)
            if best == nil || d < best!.d { best = (k, d) }
        }
        guard let k = best?.k, k != at else { return }
        var ids = others
        ids.insert(id, at: k)
        withAnimation(Self.part) { self.lane = Lane(machine: lane.machine, ids: ids.reversed()) }
    }

    /// The drag left the list: its slot goes back where the card was (the card,
    /// still in the air, flies back there if let go off the list).
    func exit() {
        guard dragged != nil, !dropped, let origin, lane != origin else { return }
        withAnimation(Self.part) { lane = origin }
    }

    /// Let go off the list: the card flew back into its slot, and shows there again.
    func cancelled() {
        guard dragged != nil, !dropped else { return }
        dragged = nil
        lane = nil
        origin = nil
    }

    /// Let go over the list: the space moves to its slot (the card glides there, `slotFrame`).
    func drop() {
        guard let id = dragged, let lane, let at = lane.ids.firstIndex(of: id) else { return }
        dropped = true
        let before = at + 1 < lane.ids.count ? lane.ids[at + 1] : nil
        if controller?.workspace.spaces(on: lane.machine).map(\.id) != lane.ids {
            controller?.moveSpace(id, before: before) { [weak self] in self?.failed(lane) }
        }
    }

    /// Where the dragged card's slot is now, for the card to land in.
    func slotFrame(in list: UIView) -> CGRect? {
        dragged.flatMap { cardFrames(in: list)[$0] }
    }

    /// The card landed: it shows in its place again. The list keeps the new order
    /// until the workspace has it (`settle`), at most `settleAfter`.
    func landed() {
        guard dropped, dragged != nil else { return }
        dragged = nil
        origin = nil
        settle()
        guard lane != nil else { return }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: Self.settleAfter)
            guard let self, !Task.isCancelled, self.dragged == nil else { return }
            withAnimation(Self.part) { self.lane = nil }
        }
    }

    /// The move didn't take: the list shows the workspace's order again.
    private func failed(_ lane: Lane) {
        guard self.lane == lane else { return }
        settling?.cancel()
        withAnimation(Self.part) {
            dragged = nil
            self.lane = nil
        }
    }

    /// The drag is over: dropped, the card lies in its slot by now. (Not dropped,
    /// the list flies it back first and then calls `cancelled`.)
    func end() {
        if dropped { landed() }
        dropped = false
    }

    // MARK: Cards

    /// Each card's frame in `list` (on screen, or about to be).
    func cardFrames(in list: UIView) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for m in markers.allObjects where m.role == .card {
            guard let id = m.space, m.isShown(in: list) else { continue }
            out[id] = m.convert(m.bounds, to: list)
        }
        return out
    }

    /// Where a space's header is, in `view`.
    func headerFrame(_ id: String, in view: UIView) -> CGRect? {
        markers.allObjects.first { $0.role == .header && $0.space == id && $0.window != nil }
            .map { $0.convert($0.bounds, to: view) }
    }

    /// The space whose header is at `p` (in `view`).
    func header(at p: CGPoint, in view: UIView) -> (space: String, frame: CGRect)? {
        for m in markers.allObjects where m.role == .header {
            guard let id = m.space, m.window != nil else { continue }
            let f = m.convert(m.bounds, to: view)
            if f.contains(p) { return (id, f) }
        }
        return nil
    }

    // MARK: Rows

    /// The row at `p` (in `view`) that has a menu.
    func row(at p: CGPoint, in view: UIView) -> RowMenuMarkerView? {
        rowMarkers.allObjects.first { m in
            m.id != nil && m.window != nil && m.convert(m.bounds, to: view).contains(p)
        }
    }

    /// Row `id`'s marker, while it's in the window.
    func row(_ id: String) -> RowMenuMarkerView? {
        rowMarkers.allObjects.first { $0.id == id && $0.window != nil }
    }
}

// MARK: - Markers

/// An empty view behind a card (`card`) and behind its header (`header`), so the drag
/// can ask UIKit where the cards are now (their frames are current while the list
/// scrolls or cards move) and which header a touch came down on.
struct SpaceMarker: UIViewRepresentable {
    enum Role { case card, header }

    var space: String
    var role: Role
    var markers: NSHashTable<Marker>?

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.space = space
        view.role = role
        markers?.add(view)
    }

    final class Marker: UIView {
        var space: String?
        var role = Role.card

        /// In `list`'s window, and under it.
        func isShown(in list: UIView) -> Bool {
            guard window != nil else { return false }
            var view: UIView? = self
            while let v = view, v !== list {
                if v.isHidden { return false }
                view = v.superview
            }
            return view === list
        }
    }
}

// MARK: - The list's drag and drop

/// The list's long press (Telegram's `ContextGesture`): a touch on a header or on a row
/// with a menu, held 0.12 s, starts the item shrinking (`pressing`), and at 0.32 s, still
/// within 10 pt of where it came down, it begins: the menu. Then it follows the finger
/// to its end (the menu's items, a card's drag). Moving on before (scrolling, a swipe)
/// lets it go. A pointer's secondary click begins it at once; a pointer's press on a
/// header moved on begins it at once too, as a card's drag (`movedOff`).
final class ListPressRecognizer: UIGestureRecognizer {
    /// Whether there's something to hold at this point (in the view).
    var accepts: (CGPoint) -> Bool = { _ in false }
    /// Whether a pointer's press moved off this point drags (a header's).
    var dragsOnMove: (CGPoint) -> Bool = { _ in false }
    /// The shrinking starts (true) or is let go (false).
    var pressing: (Bool) -> Void = { _ in }

    static let delay: TimeInterval = 0.12
    static let ramp: TimeInterval = 0.2

    /// Where the touch came down, in the view.
    private(set) var start: CGPoint = .zero
    private(set) var secondary = false
    /// Begun by a pointer's press moved on (a card's drag), not by holding.
    private(set) var movedOff = false
    private(set) weak var touch: UITouch?
    private var timers: [Timer] = []
    private var pressed = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let t = touches.first, let view else {
            if state == .possible { fail() }
            return
        }
        let p = t.location(in: view)
        // Telegram leaves the screen's left 8 pt to the swipe back.
        guard accepts(p), t.type != .direct || t.location(in: nil).x >= 8 else {
            state = .failed
            return
        }
        touch = t
        start = p
        if event.buttonMask.contains(.secondary) {
            secondary = true
            state = .began
            return
        }
        schedule(Self.delay) { [weak self] in
            guard let self, self.state == .possible else { return }
            self.pressed = true
            self.pressing(true)
        }
        schedule(Self.delay + Self.ramp) { [weak self] in
            guard let self, self.state == .possible else { return }
            self.state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t), let view else { return }
        let p = t.location(in: view)
        if state == .possible {
            let moved = hypot(p.x - start.x, p.y - start.y)
            if t.type == .indirectPointer, moved > 4, dragsOnMove(start) {
                movedOff = true
                state = .began
            } else if moved > 10 {
                fail()
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        if state == .possible { fail() } else { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        if state == .possible { fail() } else { state = .cancelled }
    }

    override func reset() {
        super.reset()
        timers.forEach { $0.invalidate() }
        timers = []
        if pressed { pressing(false) }
        pressed = false
        touch = nil
        secondary = false
        movedOff = false
    }

    private func fail() {
        timers.forEach { $0.invalidate() }
        timers = []
        state = .failed
    }

    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }
}

/// The list's long press (`ListPressRecognizer`, on the list's view, `SpacesListView`, where
/// its scrolling pan is): a header's or a row's menu (`ListMenuOverlay`, the item drawn
/// afresh: each block's host is upside down, a picture of it would be too), and dragging a
/// card by its header. Held, a header shows
/// its menu; moved on away from the menu, its card lifts out of the list and follows
/// the finger (`LiftedCard`, over the window, so off the list too), the list scrolling
/// while the finger is near its top or bottom; let go over the list, it lands in its
/// slot, off it, it flies back. A pointer's press on a header moved on drags at once.
@MainActor
final class SpaceListDragDrop: NSObject, UIGestureRecognizerDelegate {
    var drag: SpaceDrag
    private(set) weak var list: SpacesListView?
    private lazy var press: ListPressRecognizer = {
        let press = ListPressRecognizer(target: self, action: #selector(pressed(_:)))
        press.delegate = self
        press.accepts = { [weak self] p in self?.held(at: p) != nil }
        press.dragsOnMove = { [weak self] p in
            guard let self, let list = self.list else { return false }
            return self.drag.header(at: p, in: list) != nil
        }
        press.pressing = { [weak self] on in self?.pressing(on) }
        return press
    }()

    /// What's held: a header (its space) or a row.
    private enum Held {
        case header(String)
        case row(RowMenuMarkerView)

        var identifier: String {
            switch self {
            case .header(let id): return "space:\(id)"
            case .row(let row): return "row:\(row.id ?? "")"
            }
        }
    }

    private var held: Held?
    private var overlay: ListMenuOverlay?
    /// Where the menu came (the finger), in the window.
    private var openedAt: CGPoint = .zero

    /// The dragged card, drawn over the window, and the finger it follows, frame by frame.
    private var card: LiftedCard?
    private var follower: CADisplayLink?
    private var finger: CGPoint = .zero
    /// The card follows the finger.
    private var dragging = false
    /// The finger is over the list.
    private var dropping = false

    init(drag: SpaceDrag) {
        self.drag = drag
        super.init()
    }

    func attach(list: SpacesListView) {
        guard self.list !== list else { return }
        detach()
        self.list = list
        list.addGestureRecognizer(press)
    }

    func detach() {
        press.view?.removeGestureRecognizer(press)
        list = nil
    }

    /// Along with everything but a pan (the list's scrolling), as Telegram's: a button in
    /// a row (a chip) doesn't take the press from it. Begun, it takes the touch (`takeTouch`).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other is UIPanGestureRecognizer)
    }

    // MARK: The press

    /// The header or the row (with a menu) at `p`, in the list.
    private func held(at p: CGPoint) -> Held? {
        guard let list else { return nil }
        if let id = drag.header(at: p, in: list)?.space { return .header(id) }
        guard let row = drag.row(at: p, in: list), row.id != nil, row.menu().contains(where: { !$0.isEmpty }) else { return nil }
        return .row(row)
    }

    /// The held item shrinks (Telegram's: linearly, to 15 pt narrower, by the menu's time)
    /// or springs back.
    private func pressing(_ on: Bool) {
        if on, let held = held(at: press.start) {
            withAnimation(.linear(duration: ListPressRecognizer.ramp)) { drag.pressing = held.identifier }
        } else if !on, drag.pressing != nil {
            withAnimation(.easeOut(duration: 0.2)) { drag.pressing = nil }
        }
    }

    @objc private func pressed(_ press: ListPressRecognizer) {
        guard let list, let window = list.window else { return }
        let p = press.location(in: window)
        finger = p
        switch press.state {
        case .began:
            guard let held = held(at: press.start) else { return }
            self.held = held
            takeTouch(from: press)
            if press.movedOff, case .header(let id) = held {
                startDragging(id)
            } else {
                openedAt = p
                openMenu(for: held, in: window)
            }
        case .changed:
            if dragging { return }
            guard let overlay, !overlay.dismissing else { return }
            let local = overlay.convert(p, from: window)
            // A header's menu: the finger gone off it and off the lifted header, the card lifts.
            if case .header(let id) = held, hypot(p.x - openedAt.x, p.y - openedAt.y) > 12,
               !overlay.isOverMenu(local, margin: 24), !overlay.isOverItem(local, margin: 12) {
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

    /// Begun, the press takes the touch from everything else on it (the list's scrolling,
    /// the row's press, swipe and tap), as Telegram's does.
    private func takeTouch(from press: ListPressRecognizer) {
        for other in press.touch?.gestureRecognizers ?? [] where other !== press && other.isEnabled {
            other.isEnabled = false
            other.isEnabled = true
        }
    }

    // MARK: The menu

    private func openMenu(for held: Held, in window: UIWindow) {
        overlay?.removeFromSuperview()
        let source: ListMenuOverlay.Source
        switch held {
        case .header(let id):
            guard let frame = drag.headerFrame(id, in: window), let picture = headerPicture(id, width: frame.width, in: window),
                  let controller = drag.controller else { return }
            source = .init(identifier: held.identifier, frame: frame, picture: picture, radius: SpaceCard.radius,
                           menu: SpaceHeaderMenu.menu(space: id, controller: controller), open: nil)
        case .row(let row):
            let frame = row.convert(row.bounds, to: window)
            guard frame.width > 0, frame.height > 0, let picture = render(row.picture(frame.size), in: window) else { return }
            source = .init(identifier: held.identifier, frame: frame, picture: picture, radius: SpaceCard.radius,
                           menu: row.menu(), open: row.open)
        }
        let overlay = ListMenuOverlay(source: source, dark: drag.theme.isDark,
                                      compact: window.traitCollection.horizontalSizeClass == .compact)
        overlay.returnFrame = { [weak self, weak window] in
            guard let self, let window else { return nil }
            switch held {
            case .header(let id): return self.drag.headerFrame(id, in: window)
            case .row(let row):
                guard let id = row.id, let marker = self.drag.row(id) else { return nil }
                return marker.convert(marker.bounds, to: window)
            }
        }
        overlay.onDismissed = { [weak self, weak overlay] in
            guard let self else { return }
            if self.overlay === overlay { self.overlay = nil }
            if self.drag.menuLifted == held.identifier { self.drag.menuLifted = nil }
        }
        self.overlay = overlay
        // Lifted: its picture stands in for it, the item itself is hidden in the list.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            drag.pressing = nil
            drag.menuLifted = held.identifier
        }
        let (container, sibling) = list.map { menuContainer(over: $0, in: window) } ?? (window, nil)
        overlay.present(in: container, over: sibling)
    }

    /// Where the menu goes: over the list's screen in its container, when the list is a
    /// full-screen child's (the iPhone's: `PhoneNavController`, which pushes the pane
    /// screen over it), so a pushed screen covers the menu as it goes; else the window.
    private func menuContainer(over list: UIView, in window: UIWindow) -> (UIView, UIView?) {
        var view: UIView? = list
        while let v = view {
            if let child = controller(of: v), let parent = child.parent, let host = parent.viewIfLoaded,
               v.superview === host, v.bounds.size == window.bounds.size {
                return (host, v)
            }
            view = v.superview
        }
        return (window, nil)
    }

    /// The view controller whose view `view` is (SwiftUI's hosting view has a key-press
    /// responder before its controller in the chain).
    private func controller(of view: UIView) -> UIViewController? {
        var next = view.next
        while let responder = next, !(responder is UIView) {
            if let controller = responder as? UIViewController { return controller.view === view ? controller : nil }
            next = responder.next
        }
        return nil
    }

    /// A header's menu went for its card's drag: at once.
    private func closeMenuAtOnce() {
        overlay?.removeFromSuperview()
        overlay = nil
        drag.menuLifted = nil
    }

    private func headerPicture(_ id: String, width: CGFloat, in window: UIWindow) -> UIImage? {
        guard let controller = drag.controller, let space = controller.workspace.space(id) else { return nil }
        let closed = controller.closedSpaces.contains(id)
        let page = controller.workspace.phoneList(space: id)
        let bar = SpaceHeaderBar(space: space, hasRows: !page.isEmpty, closed: closed,
                                 bodyShown: !closed && !page.isEmpty, isActive: false, hovering: false)
            .frame(width: width)
            .environment(controller)
            .environment(\.theme, drag.theme)
            .environment(\.rowGround, drag.theme.surface)
        return render(bar, in: window)
    }

    private func render(_ content: some View, in window: UIWindow) -> UIImage? {
        let renderer = ImageRenderer(content: content.environment(\.tutorialAnchorsOff, true))
        renderer.scale = window.traitCollection.displayScale
        return renderer.uiImage
    }

    // MARK: The card's drag

    /// Space `id`'s card lifts out of the list and follows the finger, held where the
    /// touch came down on it.
    private func startDragging(_ id: String) {
        guard let list, let window = list.window, let frame = drag.cardFrames(in: window)[id] else { return }
        removeCard()
        let down = list.convert(press.start, to: window)
        drag.grab = CGPoint(x: down.x - frame.minX, y: down.y - frame.minY)
        let made = makeCard(id, in: list)
        drag.begin(id, in: window)
        dragging = true
        dropping = true
        guard let made else { return }
        window.addSubview(made)
        card = made
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        follow()
        let link = CADisplayLink(target: self, selector: #selector(follow))
        link.add(to: .main, forMode: .common)
        follower = link
    }

    /// Held where the finger took it (desktop's `dragLayout` card), wherever it is; the
    /// list scrolls while the finger is near its top or bottom.
    @objc private func follow() {
        guard dragging, let card, !card.landing, let window = card.superview, let id = drag.dragged else { return }
        card.frame.origin = CGPoint(x: finger.x - drag.grab.x, y: finger.y - drag.grab.y)
        let over = !isOffList(finger, in: window)
        if over != dropping {
            dropping = over
            if over { drag.enter(id, in: window) } else { drag.exit() }
        }
        autoscroll()
        // The finger may hold still while the cards part: once they're in place, the slot
        // is decided again (`SpaceDrag.update`).
        if dropping { drag.update(at: finger, in: window) }
    }

    /// Near the list's visible top or bottom (its insets: the status bar's, the
    /// header's), it scrolls that way, faster nearer the edge.
    private func autoscroll() {
        guard let list, let window = list.window, dropping else { return }
        let p = list.convert(finger, from: window)
        let area = list.contentArea
        let zone: CGFloat = 70, most: CGFloat = 14
        var step: CGFloat = 0
        // Near the top, what's over it comes down; near the bottom, what's under it comes up.
        if p.y < area.minY + zone { step = most * min(1, (area.minY + zone - p.y) / zone) }
        if p.y > area.maxY - zone { step = -most * min(1, (p.y - (area.maxY - zone)) / zone) }
        guard step != 0 else { return }
        list.scroll(by: step)
    }

    /// Let go (nil: the touch was taken away): over the list, the space moves and the card
    /// glides into its slot; off it, the card flies back.
    private func letGo(at point: CGPoint?) {
        follower?.invalidate()
        follower = nil
        dragging = false
        guard let list, let window = list.window else { return removeCard() }
        if let point, !isOffList(point, in: window) {
            dropping = false
            drag.drop()
            guard let slot = drag.slotFrame(in: window) else {
                removeCard()
                drag.end()
                return
            }
            land(in: slot) { [drag] in drag.end() }
        } else {
            dropping = false
            flyBack(in: list)
        }
    }

    /// Whether `point` (in `view`) is off the list.
    private func isOffList(_ point: CGPoint, in view: UIView) -> Bool {
        guard let list, list.window != nil else { return true }
        return !list.convert(list.bounds, to: view).contains(point)
    }

    /// The card glides into `slot` (in the window), turning into its look there; then
    /// the list shows the card itself, and this one goes.
    private func land(in slot: CGRect, duration: TimeInterval = LiftedCard.landing,
                      then done: @escaping () -> Void) {
        guard let card else { return done() }
        card.land(at: slot.origin, duration: duration) { [weak self, weak card] in
            done()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                card?.removeFromSuperview()
                if self?.card === card { self?.card = nil }
            }
        }
    }

    /// The card as it is now, drawn afresh, as wide as it is in the list and where it is
    /// (in the window).
    private func makeCard(_ id: String, in list: UIView) -> LiftedCard? {
        guard let controller = drag.controller, let space = controller.workspace.space(id),
              let window = list.window, let frame = drag.cardFrames(in: window)[id] else { return nil }
        func render(lifted: Bool) -> UIImage? {
            let content = SpaceDragPreview(space: space, width: frame.width, lifted: lifted)
                .environment(controller)
                .environment(PhoneRowSwipes())
                .environment(\.theme, drag.theme)
                .environment(\.isCompactLayout, drag.compact)
                .environment(\.homeFolder, controller.workspace.home)
                .environment(\.tutorialAnchorsOff, true)
            let renderer = ImageRenderer(content: content)
            renderer.scale = list.traitCollection.displayScale
            return renderer.uiImage
        }
        guard let resting = render(lifted: false), let lifted = render(lifted: true) else { return nil }
        let card = LiftedCard(lifted: lifted, resting: resting)
        card.frame.origin = frame.origin
        return card
    }

    private func removeCard() {
        card?.removeFromSuperview()
        card = nil
    }

    /// Let go off the list (or the drag was called off): the card flies back into its
    /// slot, where it was.
    private func flyBack(in list: UIView) {
        guard let card, !card.landing else {
            drag.cancelled()
            return
        }
        card.landing = true  // no longer follows; flies back once
        drag.exit()
        // The slot is back where the card was once the list has laid that out.
        DispatchQueue.main.async { [weak self, weak list] in
            guard let self, let window = list?.window else { return }
            guard let slot = self.drag.slotFrame(in: window) else {
                self.removeCard()
                self.drag.cancelled()
                return
            }
            self.land(in: slot, duration: 0.3) { [drag = self.drag] in drag.cancelled() }
        }
    }
}

/// The card being dragged, drawn over the window: raised with an accent
/// edge and a shadow, as on the desktop; landing, it crossfades to its look in the
/// list as it glides into its slot.
final class LiftedCard: UIView {
    /// The desktop's SETTLE_MS, near enough for a finger.
    nonisolated static let landing: TimeInterval = 0.22

    private let resting = UIImageView()
    private let lifted = UIImageView()
    private let shadow = UIView()
    var landing = false

    init(lifted: UIImage, resting: UIImage) {
        super.init(frame: CGRect(origin: .zero, size: resting.size))
        isUserInteractionEnabled = false
        shadow.frame = bounds
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.35
        shadow.layer.shadowRadius = 18
        shadow.layer.shadowOffset = CGSize(width: 0, height: 10)
        shadow.layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: SpaceCard.radius).cgPath
        self.resting.image = resting
        self.resting.frame = bounds
        self.lifted.image = lifted
        self.lifted.frame = bounds
        addSubview(shadow)
        addSubview(self.resting)
        addSubview(self.lifted)
    }

    required init?(coder: NSCoder) { fatalError() }

    func land(at origin: CGPoint, duration: TimeInterval = LiftedCard.landing, completion: @escaping () -> Void) {
        landing = true
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.frame.origin = origin
            self.lifted.alpha = 0
            self.shadow.alpha = 0
        } completion: { _ in completion() }
    }
}

/// A space's card as a drag draws it (`LiftedCard`): its header and (unless folded)
/// its rows on a raised card with an accent edge, or as it lies in the list.
struct SpaceDragPreview: View {
    var space: Space
    var width: CGFloat
    /// Lifted: raised, with an accent edge; else as it lies in the list.
    var lifted = true

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let page = controller.workspace.phoneList(space: space.id)
        let closed = controller.closedSpaces.contains(space.id)
        let shape = RoundedRectangle(cornerRadius: SpaceCard.radius, style: .continuous)
        SpaceCardContent(space: space, page: page, closed: closed, bodyShown: !closed && !page.isEmpty)
            .frame(width: width)
            .background(lifted ? theme.raised : theme.surface)
            .environment(\.rowGround, lifted ? theme.raised : theme.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(lifted ? theme.accent.opacity(0.6) : theme.border, lineWidth: 1))
    }
}
