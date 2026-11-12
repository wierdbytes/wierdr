import SwiftUI
import UIKit
import WierdrModel

/// Dragging a space card to reorder it, as on the desktop (`wierd-agents`): the
/// card lifts and follows the finger, and where it would land the other cards of
/// its machine part around an empty slot (a dashed outline as tall as the card).
/// Let go over the list, it glides into the slot and the space moves there
/// (`space.move`); taken out of the list, it goes back where it was.
///
/// The drag is the list's own (its collection view's, `SpaceListDragDrop`): a
/// finger holds a header and moves (as with the header's menu, which the system
/// gives way), a pointer presses and moves. The card rows' markers
/// (`SpaceRowMarker`) say where the cards are, and `SpacesList` shows the
/// machine's spaces in `lane`'s order, the dragged one as its slot.
@MainActor
@Observable
final class SpaceDrag {
    /// The drag's item type; only this app's own drags carry it.
    static let typeID = "pw.xff.wierdr.space"

    struct Lane: Equatable {
        var machine: String?
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
    /// Every card row's marker (weakly).
    @ObservationIgnored let markers = NSHashTable<SpaceRowMarker.Marker>.weakObjects()
    /// Where the finger holds the card, from its top left corner, and the card's
    /// height (the slot's).
    @ObservationIgnored var grab = CGPoint(x: 0, y: 17)
    @ObservationIgnored private var height: CGFloat = 0
    @ObservationIgnored private var dropped = false
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
        // Spaces that came meanwhile stay after the others, in their own order.
        return spaces.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// The workspace's spaces changed: once they're in the dropped order, the list
    /// follows them again.
    func settle() {
        guard dragged == nil, let lane, let ws = controller?.workspace else { return }
        if ws.spaces(on: lane.machine).map(\.id) == lane.ids { self.lane = nil }
    }

    // MARK: The list's drag events (`list`: the collection view, its content coordinates)

    /// A drag of space `id` came over the list (at the start, or back).
    func enter(_ id: String, at p: CGPoint, in list: UIView) {
        guard let ws = controller?.workspace, let space = ws.space(id) else { return }
        settling?.cancel()
        dropped = false
        let ids = arranged(ws.spaces(on: space.machine), machine: space.machine).map(\.id)
        if let card = cardFrames(in: list)[id] { height = card.height }
        withAnimation(Self.part) {
            dragged = id
            lane = Lane(machine: space.machine, ids: ids)
        }
    }

    /// The finger moved (or the list scrolled under it): the slot goes where the
    /// card would land, the slot whose top is nearest the card's top, counted as if
    /// the card weren't in the list (desktop's `dragLayout`).
    func update(at p: CGPoint, in list: UIView) {
        guard let id = dragged, let lane, let at = lane.ids.firstIndex(of: id) else { return }
        let others = lane.ids.filter { $0 != id }
        guard !others.isEmpty else { return }
        let frames = cardFrames(in: list)
        // The list hasn't laid out the last move yet: wait for it.
        let shown = lane.ids.filter { frames[$0] != nil }
        guard shown == shown.sorted(by: { frames[$0]!.minY < frames[$1]!.minY }) else { return }
        if let card = frames[id], card.height > height { height = card.height }
        let top = p.y - grab.y
        // Slot k is before others[k] (k == count: after the last). Cards off screen
        // (not laid out) have no place; they're far from the finger anyway.
        var best: (k: Int, d: CGFloat)?
        for k in 0...others.count {
            let below = k < others.count
            let card = below ? others[k] : others[k - 1]
            guard let f = frames[card] else { continue }
            let after = (below ? k : k - 1) >= at  // shown after the slot: up by its height without it
            let y = (below ? f.minY : f.maxY) - (after ? height : 0)
            let d = abs(y - top)
            if best == nil || d < best!.d { best = (k, d) }
        }
        guard let k = best?.k, k != at else { return }
        var ids = others
        ids.insert(id, at: k)
        withAnimation(Self.part) { self.lane = Lane(machine: lane.machine, ids: ids) }
    }

    /// The drag left the list: the card goes back where it was.
    func exit() {
        guard dragged != nil, !dropped else { return }
        withAnimation(Self.part) {
            dragged = nil
            lane = nil
        }
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

    /// The drag is over, dropped or not.
    func end() {
        if dropped { landed() } else { exit() }
        dropped = false
    }

    // MARK: Cards

    /// Each card's frame in `list` (its rows on screen, or about to be).
    func cardFrames(in list: UIView) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for m in markers.allObjects {
            guard let id = m.space, m.isShown(in: list) else { continue }
            let f = m.convert(m.bounds, to: list)
            out[id] = out[id].map { $0.union(f) } ?? f
        }
        return out
    }

    /// The marker inside `cell` (a row of the list).
    func marker(in cell: UIView) -> SpaceRowMarker.Marker? {
        markers.allObjects.first { $0.isDescendant(of: cell) }
    }
}

// MARK: - Row markers

/// An empty view behind each row of a space card, so the drag can ask UIKit which
/// card a row of the list is and where the card is now (its frame is current
/// while the list scrolls or rows move). `header`: the card's header, which the
/// card is dragged by.
struct SpaceRowMarker: UIViewRepresentable {
    var space: String
    var header = false
    var markers: NSHashTable<Marker>?

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Marker, context: Context) {
        view.space = space
        view.header = header
        markers?.add(view)
    }

    final class Marker: UIView {
        var space: String?
        var header = false

        /// In `list`'s window, and not in a cell it keeps hidden for reuse.
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

/// Finds the `List`'s collection view (from a view behind the list) and makes
/// `SpaceListDragDrop` its drag and drop delegate.
struct SpaceDropTarget: UIViewRepresentable {
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
        anchor.findList()
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: SpaceListDragDrop) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var delegate: SpaceListDragDrop?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            findList()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            findList()
        }

        /// Takes over the list's drags once the list is in the window (again after
        /// SwiftUI replaced the list, or set its own delegates again).
        func findList() {
            guard window != nil, let delegate else { return }
            if let list = delegate.list, list.window != nil {
                delegate.attach(to: list)
                // SwiftUI sets the list's own delegates as it updates it, maybe after this.
                DispatchQueue.main.async { [weak delegate, weak list] in
                    if let delegate, let list { delegate.attach(to: list) }
                }
                return
            }
            DispatchQueue.main.async { [weak self] in self?.search() }
        }

        private func search() {
            guard window != nil, let delegate, delegate.list?.window == nil else { return }
            let mine = convert(bounds, to: nil)
            guard mine.width > 0, mine.height > 0 else { return }
            var node = superview
            for _ in 0..<8 {
                guard let n = node else { return }
                if let list = Self.list(in: n, covering: mine) {
                    delegate.attach(to: list)
                    return
                }
                node = n.superview
            }
        }

        /// The collection view laid out where this view is (the list it's behind).
        private static func list(in root: UIView, covering frame: CGRect) -> UICollectionView? {
            var queue = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let cv = view as? UICollectionView {
                    let f = cv.convert(cv.bounds, to: nil).intersection(frame)
                    if !f.isNull, f.width * f.height > 0.8 * frame.width * frame.height { return cv }
                    continue  // its cells hold no list of ours
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }
}

/// Counts the touches that come down on the list (it never recognizes anything),
/// so a drag can tell whether it's still the touch that lifted a header.
final class TouchCounter: UIGestureRecognizer {
    private(set) var count = 0
    var down: (() -> Void)?

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
        down?()
        state = .failed
    }
}

/// What a space drag carries: the space, for the list it's dropped on.
final class SpaceDragContext: NSObject {
    let space: String
    init(space: String) { self.space = space }
}

/// The list's drag and drop delegate while it shows space cards. A card's header
/// starts a drag of its space (its item knows which, wherever the finger is when
/// the drag really starts), shown as the whole card lifted; a space drag over
/// the list is reported to `SpaceDrag`. Being the collection view's own drag, it plays along with the
/// header's menu and scrolls the list at its top and bottom by itself. Anything
/// else goes to SwiftUI's own delegates, when it set them.
@MainActor
final class SpaceListDragDrop: NSObject, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    var drag: SpaceDrag
    private(set) weak var list: UICollectionView?
    /// SwiftUI's delegates, which it keeps alive.
    private weak var swiftUIDrag: (any UICollectionViewDragDelegate)?
    private weak var swiftUIDrop: (any UICollectionViewDropDelegate)?

    /// The lifted look over the dragged card's preview (it fades as the card lands).
    private weak var liftedLook: UIView?
    /// How long the card takes to glide into its slot (the drop animation's spring
    /// settles long after that, while the card already lies there).
    private let glide: TimeInterval = 0.35

    /// The header the touch now down lifted (nil: it lifted something else).
    private var lifted: (space: String?, touch: Int)?
    private let touches = TouchCounter()

    init(drag: SpaceDrag) {
        self.drag = drag
        super.init()
        // SwiftUI sets its own delegates again as it updates the list: before a
        // touch can lift anything, they're ours again.
        touches.down = { [weak self] in
            guard let self, let list = self.list else { return }
            self.attach(to: list)
        }
    }

    func attach(to list: UICollectionView) {
        if self.list !== list {
            detach()
            self.list = list
            list.addGestureRecognizer(touches)
        }
        if list.dragDelegate !== self {
            swiftUIDrag = list.dragDelegate
            list.dragDelegate = self
        }
        if list.dropDelegate !== self {
            swiftUIDrop = list.dropDelegate
            list.dropDelegate = self
        }
        if !list.dragInteractionEnabled {
            list.dragInteractionEnabled = true
        }
    }

    func detach() {
        guard let list else { return }
        list.removeGestureRecognizer(touches)
        if list.dragDelegate === self { list.dragDelegate = swiftUIDrag }
        if list.dropDelegate === self { list.dropDelegate = swiftUIDrop }
        self.list = nil
    }

    /// The space a drag carries (a collection view keeps a drag's `localContext` for itself).
    private static func space(of items: [UIDragItem]) -> String? {
        items.lazy.compactMap { ($0.localObject as? SpaceDragContext)?.space }.first
    }

    private func space(of session: any UIDropSession) -> String? {
        session.localDragSession.flatMap { Self.space(of: $0.items) }
    }

    // Anything else SwiftUI's delegates answer goes to them.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (swiftUIDrag?.responds(to: selector) ?? false)
            || (swiftUIDrop?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if swiftUIDrag?.responds(to: selector) == true { return swiftUIDrag }
        if swiftUIDrop?.responds(to: selector) == true { return swiftUIDrop }
        return nil
    }

    // MARK: Drag

    func collectionView(_ cv: UICollectionView, itemsForBeginning session: any UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        // Held until its menu came, the drag starts where the finger has gone since,
        // and the list asks for the row there: it's still what the touch lifted.
        if let lifted, lifted.touch == touches.count {
            return lifted.space.map { [item($0, in: cv)] } ?? []
        }
        guard let cell = cv.cellForItem(at: indexPath), let marker = drag.marker(in: cell),
              marker.header, let id = marker.space else {
            lifted = (nil, touches.count)
            return swiftUIDrag?.collectionView(cv, itemsForBeginning: session, at: indexPath) ?? []
        }
        lifted = (id, touches.count)
        let card = drag.cardFrames(in: cv)[id] ?? cell.frame
        let p = session.location(in: cv)
        drag.grab = CGPoint(x: p.x - card.minX, y: p.y - card.minY)
        return [item(id, in: cv)]
    }

    private func item(_ id: String, in cv: UICollectionView) -> UIDragItem {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: SpaceDrag.typeID, visibility: .ownProcess) { done in
            done(Data(id.utf8), nil)
            return nil
        }
        let item = UIDragItem(itemProvider: provider)
        item.localObject = SpaceDragContext(space: id)
        // Lifted, the whole card follows the finger (the lift itself is its header's).
        item.previewProvider = { [weak self, weak cv] in
            guard let self, let cv else { return nil }
            return self.cardPreview(id, in: cv)
        }
        return item
    }

    /// The card lifted: drawn afresh (its cells on screen are dimmed by the lift),
    /// as wide as it is in the list.
    private func cardPreview(_ id: String, in cv: UICollectionView) -> UIDragPreview? {
        guard let controller = drag.controller, let space = controller.workspace.space(id),
              let card = drag.cardFrames(in: cv)[id] else { return nil }
        func render(lifted: Bool) -> UIImage? {
            let content = SpaceDragPreview(space: space, width: card.width, lifted: lifted)
                .environment(controller)
                .environment(\.theme, drag.theme)
                .environment(\.isCompactLayout, drag.compact)
                .environment(\.homeFolder, controller.workspace.home)
            let renderer = ImageRenderer(content: content)
            renderer.scale = cv.traitCollection.displayScale
            return renderer.uiImage
        }
        // The card as it lies in the list, and over it as lifted: that fades as it lands.
        guard let image = render(lifted: false), let up = render(lifted: true) else { return nil }
        // The system centers a preview under the finger: around the card, room enough
        // for the finger to hold it where it held the header.
        let size = image.size
        let g = CGPoint(x: min(max(drag.grab.x, 0), size.width), y: min(max(drag.grab.y, 0), size.height))
        let box = CGSize(width: 2 * max(g.x, size.width - g.x), height: 2 * max(g.y, size.height - g.y))
        let view = UIView(frame: CGRect(origin: .zero, size: box))
        let shot = UIImageView(image: image)
        shot.frame.origin = CGPoint(x: box.width / 2 - g.x, y: box.height / 2 - g.y)
        view.addSubview(shot)
        let liftedShot = UIImageView(image: up)
        liftedShot.frame = shot.frame
        view.addSubview(liftedShot)
        liftedLook = liftedShot
        // The whole box is the preview (the system centers what's visible under the
        // finger), the card casts the shadow.
        let parameters = UIDragPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(rect: view.bounds)
        parameters.shadowPath = UIBezierPath(roundedRect: shot.frame, cornerRadius: 10)
        return UIDragPreview(view: view, parameters: parameters)
    }

    /// The lifted header: its piece of the card.
    func collectionView(_ cv: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        guard let cell = cv.cellForItem(at: indexPath), let marker = drag.marker(in: cell), marker.header else {
            return swiftUIDrag?.collectionView?(cv, dragPreviewParametersForItemAt: indexPath)
        }
        let parameters = UIDragPreviewParameters()
        let rect = marker.convert(marker.bounds, to: cell)
        parameters.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: 10)
        return parameters
    }

    func collectionView(_ cv: UICollectionView, dragSessionDidEnd session: any UIDragSession) {
        if Self.space(of: session.items) != nil { lifted = nil }
        swiftUIDrag?.collectionView?(cv, dragSessionDidEnd: session)
    }

    func collectionView(_ cv: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool {
        if Self.space(of: session.items) != nil { return true }
        return swiftUIDrag?.collectionView?(cv, dragSessionIsRestrictedToDraggingApplication: session) ?? false
    }

    func collectionView(_ cv: UICollectionView, dragSessionAllowsMoveOperation session: any UIDragSession) -> Bool {
        if Self.space(of: session.items) != nil { return true }
        return swiftUIDrag?.collectionView?(cv, dragSessionAllowsMoveOperation: session) ?? true
    }

    // MARK: Drop

    func collectionView(_ cv: UICollectionView, canHandle session: any UIDropSession) -> Bool {
        if space(of: session) != nil { return true }
        return swiftUIDrop?.collectionView?(cv, canHandle: session) ?? false
    }

    func collectionView(_ cv: UICollectionView, dropSessionDidEnter session: any UIDropSession) {
        guard let id = space(of: session) else { return swiftUIDrop?.collectionView?(cv, dropSessionDidEnter: session) ?? () }
        drag.enter(id, at: session.location(in: cv), in: cv)
    }

    func collectionView(_ cv: UICollectionView, dropSessionDidUpdate session: any UIDropSession,
                        withDestinationIndexPath indexPath: IndexPath?) -> UICollectionViewDropProposal {
        guard space(of: session) != nil else {
            return swiftUIDrop?.collectionView?(cv, dropSessionDidUpdate: session, withDestinationIndexPath: indexPath)
                ?? UICollectionViewDropProposal(operation: .cancel)
        }
        drag.update(at: session.location(in: cv), in: cv)
        // The list's own insertion gap stays shut: the slot is the card's own rows.
        return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
    }

    func collectionView(_ cv: UICollectionView, dropSessionDidExit session: any UIDropSession) {
        guard space(of: session) != nil else { return swiftUIDrop?.collectionView?(cv, dropSessionDidExit: session) ?? () }
        drag.exit()
    }

    func collectionView(_ cv: UICollectionView, dropSessionDidEnd session: any UIDropSession) {
        guard space(of: session) != nil else { return swiftUIDrop?.collectionView?(cv, dropSessionDidEnd: session) ?? () }
        drag.end()
    }

    /// Let go: the space moves, and the card glides into its slot.
    func collectionView(_ cv: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
        guard space(of: coordinator.session) != nil else {
            swiftUIDrop?.collectionView(cv, performDropWith: coordinator)
            return
        }
        drag.drop()
        guard let slot = drag.slotFrame(in: cv) else { return }
        for item in coordinator.items {
            // The preview's box is centered where the finger holds the card.
            let center = CGPoint(x: slot.minX + drag.grab.x, y: slot.minY + drag.grab.y)
            let animator = coordinator.drop(item.dragItem, to: UIDragPreviewTarget(container: cv, center: center))
            animator.addAnimations { [weak self] in self?.liftedLook?.alpha = 0 }
            animator.addCompletion { [drag] _ in drag.landed() }
        }
        // Once it lies in its slot, the card itself is there under it.
        DispatchQueue.main.asyncAfter(deadline: .now() + glide) { [drag] in drag.landed() }
    }
}

/// The lifted card a space drag shows under the finger: its header and (unless
/// hidden) its rows on a raised card with an accent edge, as on the desktop.
struct SpaceDragPreview: View {
    var space: Space
    var width: CGFloat
    /// Lifted: raised, with an accent edge; else as it lies in the list.
    var lifted = true

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let rows = controller.workspace.sidebarRows(for: space)
        let closed = controller.closedSpaces.contains(space.id)
        let bodyShown = !closed && !rows.isEmpty
        let shape = RoundedRectangle(cornerRadius: 10)
        VStack(spacing: 0) {
            // Without the room after the card.
            SpaceHeader(space: space, rows: rows, closed: closed, bodyShown: bodyShown)
                .padding(.bottom, bodyShown ? 0 : -6)
            if bodyShown {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    SidebarRowView(row: row, space: space, bracket: Bracket.position(rows, i))
                        .padding(.horizontal, 5)
                        .padding(.top, 4)
                }
                Color.clear.frame(height: 5)
            }
        }
        .frame(width: width)
        .background(lifted ? theme.raised : theme.surface, in: shape)
        .overlay(shape.strokeBorder(lifted ? theme.accent.opacity(0.6) : theme.border, lineWidth: 1))
        .clipShape(shape)
    }
}
