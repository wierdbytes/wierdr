import SwiftUI
import UIKit
import WierdrModel

/// Dragging a space card to reorder it, as on the desktop (`wierd-agents`): the
/// card lifts and follows the finger, and where it would land the other cards of
/// its machine part around an empty slot (a dashed outline as tall as the card).
/// Let go over the list, it glides into the slot and the space moves there
/// (`space.move`); let go off the list, it flies back to where it was.
///
/// The drag is UIKit's (`SpaceListInteractions`: a drag interaction on the list's scroll
/// view with the headers' own menu interaction, so it plays along with the menu, held
/// then moved; a drop interaction there too). The lifted card is drawn by
/// the app over the window (`LiftedCard`), the cards' markers (`SpaceMarker`) say
/// where the cards and their headers are, and `SpacesList` shows the machine's spaces
/// in `lane`'s order, the dragged one as its slot. The list is drawn bottom up (and is
/// upside down itself: the drag works in the window's coordinates): a lane's first space
/// is its lowest card.
@MainActor
@Observable
final class SpaceDrag {
    /// The drag's item type; only this app's own drags carry it.
    static let typeID = "pw.xff.wierdr.space"

    struct Lane: Equatable {
        var machine: String?
        /// In the workspace's order (drawn bottom up).
        var ids: [String]
    }

    /// The space being dragged over the list: its card shows as the slot.
    private(set) var dragged: String?
    /// Its machine's spaces as the list shows them meanwhile, it at its slot. After
    /// a drop, until the workspace has them in this order (or gives up, `settleAfter`).
    private(set) var lane: Lane?

    @ObservationIgnored weak var controller: WorkspaceController?
    /// The list's look, for drawing the lifted card (set by the list).
    @ObservationIgnored var theme = Theme.atomOneDark
    @ObservationIgnored var compact = false
    /// Every card's and header's marker (weakly).
    @ObservationIgnored let markers = NSHashTable<SpaceMarker.Marker>.weakObjects()
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
    private static let part = Animation.easeOut(duration: 0.16)
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
    // the screen's, up being up, while the list itself is drawn upside down)

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

/// Behind the list's content: finds the list's scroll view (its ancestor) and gives it
/// `SpaceListDragDrop`'s interactions.
struct SpaceListInteractions: UIViewRepresentable {
    var drag: SpaceDrag

    func makeCoordinator() -> SpaceListDragDrop { SpaceListDragDrop(drag: drag) }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.delegate = context.coordinator
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        context.coordinator.drag = drag
        anchor.attach()
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: SpaceListDragDrop) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var delegate: SpaceListDragDrop?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        func attach() {
            guard window != nil, let delegate else { return }
            var view = superview
            while let v = view, !(v is UIScrollView) { view = v.superview }
            guard let list = view as? UIScrollView else { return }
            delegate.attach(list: list)
        }
    }
}

/// Counts the touches that come down on the list and keeps where the last one did (it
/// never recognizes anything), so a drag can tell which header the touch that lifted it
/// came down on, wherever the finger is when the drag really starts.
final class TouchCounter: UIGestureRecognizer {
    private(set) var count = 0
    /// Where the last touch came down (in the view's coordinates).
    private(set) var downAt: CGPoint = .zero

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        // A pointer's press too (its drags start without a hold).
        allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        count += 1
        if let touch = touches.first, let view { downAt = touch.location(in: view) }
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// A see-through view over the window while the list's own space drag lasts, a
/// drop target for it wherever the list isn't (the panel's SwiftUI hosting view
/// has its own drop target, for the tab pills, which would take the drag there):
/// letting go off the list is a drop heard at once, so the card flies back straight
/// away instead of after the system's cancel animation. Over the list it isn't
/// there for hit testing, and the list takes the drag.
@MainActor
final class SpaceOffListDrop: UIView, UIDropInteractionDelegate {
    private weak var owner: SpaceListDragDrop?

    init(owner: SpaceListDragDrop) {
        self.owner = owner
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addInteraction(UIDropInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        owner?.isOffList(point, in: self) == true ? self : nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        owner?.owns(session) ?? false
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        owner?.letGoOffList()
    }
}

/// What a space drag carries: the space, for the list it's dropped on.
final class SpaceDragContext: NSObject {
    let space: String
    init(space: String) { self.space = space }
}

/// The list's drag and drop, and the headers' menu. On the list's scroll view: the
/// headers' context menu interaction (`SpaceHeaderMenu`; SwiftUI's own, with the preview
/// the upside-down list needs, wouldn't let a drag start from it) and a drag interaction
/// (so a header held shows its menu, and moved on, the card lifts: UIKit plays the two
/// together on one view), which starts a drag only for a touch that came down on a card's
/// header; a drop interaction, which reports
/// the drag to `SpaceDrag` and draws the card lifted where the finger holds it
/// (`LiftedCard`), scrolling the list while the finger is near its top or bottom.
@MainActor
final class SpaceListDragDrop: NSObject, UIDragInteractionDelegate, UIDropInteractionDelegate,
                                 UIContextMenuInteractionDelegate {
    var drag: SpaceDrag
    private(set) weak var list: UIScrollView?
    private lazy var dragInteraction = UIDragInteraction(delegate: self)
    private lazy var dropInteraction = UIDropInteraction(delegate: self)
    /// The headers' menu (`SpaceHeaderMenu`): on the list with the drag, so UIKit plays
    /// the two together (held, the menu; moved on, the card lifts).
    private lazy var menuInteraction = UIContextMenuInteraction(delegate: self)

    /// The dragged card, drawn over the window (the system's own preview is
    /// invisible), and the drag it follows, frame by frame, anywhere on the screen.
    private var card: LiftedCard?
    private var session: (any UIDragDropSession)?
    private var follower: CADisplayLink?
    /// Over the window while the card is dragged: hears it let go off the list at
    /// once (the drag itself ends only after the system's own animations).
    private lazy var offList = SpaceOffListDrop(owner: self)
    private let touches = TouchCounter()

    init(drag: SpaceDrag) {
        self.drag = drag
        super.init()
    }

    func attach(list: UIScrollView) {
        guard self.list !== list else { return }
        detach()
        self.list = list
        list.addGestureRecognizer(touches)
        list.addInteraction(dropInteraction)
        list.addInteraction(menuInteraction)
        list.addInteraction(dragInteraction)
        dragInteraction.isEnabled = true
    }

    func detach() {
        offList.removeFromSuperview()
        touches.view?.removeGestureRecognizer(touches)
        dragInteraction.view?.removeInteraction(dragInteraction)
        dropInteraction.view?.removeInteraction(dropInteraction)
        menuInteraction.view?.removeInteraction(menuInteraction)
        list = nil
    }

    // MARK: The headers' menu

    /// A header held (or right-clicked): its space's menu. Elsewhere, nothing: the rows'
    /// menus are SwiftUI's.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let list, let id = drag.header(at: location, in: list)?.space, let controller = drag.controller,
              controller.workspace.space(id) != nil else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in
            SpaceHeaderMenu.menu(space: id, controller: controller)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        headerPreview(identifier as? String)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        headerPreview(identifier as? String)
    }

    /// The header drawn afresh where it is (the list is upside down: a picture of the
    /// header itself would be too).
    private func headerPreview(_ id: String?) -> UITargetedPreview? {
        guard let id, let list, let window = list.window, let controller = drag.controller,
              let space = controller.workspace.space(id),
              let frame = drag.headerFrame(id, in: window) else { return nil }
        let closed = controller.closedSpaces.contains(id)
        let page = controller.workspace.phoneList(space: id)
        let bar = SpaceHeaderBar(space: space, hasRows: !page.isEmpty, closed: closed,
                                 bodyShown: !closed && !page.isEmpty, isActive: false, hovering: false)
            .frame(width: frame.width)
            .environment(controller)
            .environment(\.theme, drag.theme)
            .environment(\.rowGround, drag.theme.surface)
        let renderer = ImageRenderer(content: bar)
        renderer.scale = window.traitCollection.displayScale
        guard let image = renderer.uiImage else { return nil }
        let view = UIImageView(image: image)
        view.frame = CGRect(origin: .zero, size: frame.size)
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: SpaceCard.radius)
        // In the list, turned back upright (the list is drawn upside down).
        let center = list.convert(CGPoint(x: frame.midX, y: frame.midY), from: window)
        let upsideDown = list.convert(CGPoint(x: 0, y: 1), to: window).y < list.convert(CGPoint.zero, to: window).y
        return UITargetedPreview(view: view, parameters: parameters,
                                 target: UIPreviewTarget(container: list, center: center,
                                                         transform: upsideDown ? CGAffineTransform(scaleX: 1, y: -1) : .identity))
    }

    /// The space a drag carries.
    private static func space(of items: [UIDragItem]) -> String? {
        items.lazy.compactMap { ($0.localObject as? SpaceDragContext)?.space }.first
    }

    private func space(of session: any UIDropSession) -> String? {
        session.localDragSession.flatMap { Self.space(of: $0.items) }
    }

    // MARK: Drag

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
        // Held until its menu came, the drag starts where the finger has gone since:
        // what it lifts is the header the touch came down on.
        guard let list, let window = list.window, let id = drag.header(at: touches.downAt, in: list)?.space,
              let card = drag.cardFrames(in: window)[id] else { return [] }
        let p = list.convert(touches.downAt, to: window)
        drag.grab = CGPoint(x: p.x - card.minX, y: p.y - card.minY)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: SpaceDrag.typeID, visibility: .ownProcess) { done in
            done(Data(id.utf8), nil)
            return nil
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = SpaceDragContext(space: id)
        return [item]
    }

    /// Lifted, the list draws the card (`LiftedCard`): the system's preview goes where
    /// it likes (centered under the finger) and can't change as it lands.
    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                         session: any UIDragSession) -> UITargetedDragPreview? {
        guard let view = interaction.view, view.window != nil else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        parameters.shadowPath = UIBezierPath()
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        dot.alpha = 0.01
        let at = list.map { view.convert(touches.downAt, from: $0) } ?? .zero
        return UITargetedDragPreview(view: dot, parameters: parameters,
                                     target: UIDragPreviewTarget(container: view, center: at))
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForCancelling item: UIDragItem,
                         withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
        nil
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool {
        true
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: any UIDragSession) -> Bool {
        true
    }

    /// The drag started: the card lifts out of the list (over everything, so it
    /// follows the finger off the list too).
    func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
        guard let list, let window = list.window, let id = Self.space(of: session.items) else { return }
        removeCard()
        let made = makeCard(id, in: list)
        drag.begin(id, in: window)
        guard let made else { return }
        offList.frame = window.bounds
        window.addSubview(offList)
        window.addSubview(made)
        card = made
        self.session = session
        follow()
        let link = CADisplayLink(target: self, selector: #selector(follow))
        link.add(to: .main, forMode: .common)
        follower = link
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession,
                         didEndWith operation: UIDropOperation) {
        guard Self.space(of: session.items) != nil else { return }
        stopFollowing()
        if let list { flyBack(in: list) }
    }

    /// Held where the finger took it (desktop's `dragLayout` card), wherever it is; the
    /// list scrolls while the finger is near its top or bottom.
    @objc private func follow() {
        guard let session, let card, !card.landing, let window = card.superview else { return }
        let p = session.location(in: window)
        card.frame.origin = CGPoint(x: p.x - drag.grab.x, y: p.y - drag.grab.y)
        autoscroll()
        // The finger may hold still while the cards part: once they're in place, the slot
        // is decided again (`SpaceDrag.update`).
        if dropping { drag.update(at: p, in: window) }
    }

    /// Near the list's visible top or bottom (its insets: the status bar's, the
    /// header's), it scrolls that way, faster nearer the edge.
    private func autoscroll() {
        guard let list, let session, dropping else { return }
        let p = session.location(in: list)
        let inset = list.adjustedContentInset
        let top = list.bounds.minY + inset.top, bottom = list.bounds.maxY - inset.bottom
        let zone: CGFloat = 70, most: CGFloat = 14
        var step: CGFloat = 0
        if p.y < top + zone { step = -most * min(1, (top + zone - p.y) / zone) }
        if p.y > bottom - zone { step = most * min(1, (p.y - (bottom - zone)) / zone) }
        guard step != 0 else { return }
        let minY = -inset.top, maxY = max(minY, list.contentSize.height + inset.bottom - list.bounds.height)
        let y = min(max(list.contentOffset.y + step, minY), maxY)
        guard abs(y - list.contentOffset.y) > 0.1 else { return }
        list.contentOffset.y = y
    }

    /// The drag is over the list.
    private var dropping = false

    private func stopFollowing() {
        follower?.invalidate()
        follower = nil
        session = nil
        offList.removeFromSuperview()
    }

    /// Whether `point` (in `view`) is off the list.
    func isOffList(_ point: CGPoint, in view: UIView) -> Bool {
        guard let list, list.window != nil else { return false }
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
    private func makeCard(_ id: String, in list: UIScrollView) -> LiftedCard? {
        guard let controller = drag.controller, let space = controller.workspace.space(id),
              let window = list.window, let frame = drag.cardFrames(in: window)[id] else { return nil }
        func render(lifted: Bool) -> UIImage? {
            let content = SpaceDragPreview(space: space, width: frame.width, lifted: lifted)
                .environment(controller)
                .environment(PhoneRowSwipes())
                .environment(\.theme, drag.theme)
                .environment(\.isCompactLayout, drag.compact)
                .environment(\.homeFolder, controller.workspace.home)
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

    /// This list's drag, now over `session`.
    func owns(_ session: any UIDropSession) -> Bool {
        guard let mine = self.session, let theirs = session.localDragSession else { return false }
        return mine as AnyObject === theirs as AnyObject
    }

    /// Let go off the list: the card flies back at once.
    func letGoOffList() {
        stopFollowing()
        if let list { flyBack(in: list) }
    }

    /// Let go off the list (or the drag was called off): the card flies back into its
    /// slot, where it was.
    private func flyBack(in list: UIScrollView) {
        guard let card, !card.landing else { return }
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

    // MARK: Drop

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        space(of: session) != nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: any UIDropSession) {
        guard let window = list?.window, let id = space(of: session) else { return }
        dropping = true
        drag.enter(id, in: window)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        guard let window = list?.window, space(of: session) != nil else { return UIDropProposal(operation: .cancel) }
        drag.update(at: session.location(in: window), in: window)
        return UIDropProposal(operation: .move)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        guard space(of: session) != nil else { return }
        dropping = false
        drag.exit()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: any UIDropSession) {
        guard space(of: session) != nil else { return }
        dropping = false
        drag.end()
    }

    /// Let go: the space moves, and the card glides into its slot.
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        guard let window = list?.window, space(of: session) != nil else { return }
        dropping = false
        drag.drop()
        stopFollowing()
        guard let slot = drag.slotFrame(in: window) else {
            removeCard()
            return
        }
        // The card glides into its slot, turning into the card in the list on the way.
        land(in: slot) { [drag] in drag.landed() }
    }

    /// The system's (invisible) preview goes to the slot too, so the drop ends.
    func dropInteraction(_ interaction: UIDropInteraction, previewForDropping item: UIDragItem,
                         withDefault defaultPreview: UITargetedDragPreview) -> UITargetedDragPreview? {
        guard let window = list?.window, let slot = drag.slotFrame(in: window) else { return nil }
        return defaultPreview.retargetedPreview(with: UIDragPreviewTarget(container: window,
                                                                          center: CGPoint(x: slot.midX, y: slot.midY)))
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
