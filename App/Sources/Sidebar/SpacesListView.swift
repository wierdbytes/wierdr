import QuartzCore
import SwiftUI
import UIKit
import WierdrModel

// The sidebar's list, built the way Telegram builds its `ListView` (ListView.swift,
// ListViewScroller.swift): a plain `UIScrollView` is only the physics, hidden, its pan moved
// onto the list's own view, so UIKit's deceleration, rubber band, bounce and the finger's
// catch are used as they are; the content isn't in it. Each block (a space's card, a
// machine's header, a note) is a SwiftUI view in its own hosting controller, built as it
// comes near the screen and measured before it shows, placed by the list from the scroller's
// offset. The scroller's content height is the blocks' exact sum when both ends are built,
// else an end out of reach (Telegram's rule), never an estimate that changes under a fling,
// as SwiftUI's lazy stack's did (a card's height guessed from the others').

// MARK: - SwiftUI side

/// What the list tells its SwiftUI owner (`SpacesList`).
struct SpacesListEvents {
    /// How far the list is pulled past its start (up past its bottom), every time it moves.
    var overscroll: (CGFloat) -> Void = { _ in }
    /// A finger took the list (true) or let it go (false).
    var dragging: (Bool) -> Void = { _ in }
    /// A tap on the list off its rows' own taps.
    var tapped: () -> Void = {}
}

/// Commands from SwiftUI to the list (`SpacesListController`), which registers itself here.
@MainActor
final class SpacesListHandle {
    fileprivate weak var list: SpacesListController?

    /// Brings block `id` into view (the least scroll that shows it, its bottom first when
    /// it's taller than the list), easing out over `duration`.
    func reveal(_ id: String, duration: Double) {
        list?.reveal(id, duration: duration)
    }
}

/// The list's UIKit side in SwiftUI (`SpacesList` gives it its blocks and insets).
struct SpacesListContent: UIViewControllerRepresentable {
    /// From the content's start (the screen's bottom) up.
    var blocks: [SpacesListBlock]
    var topInset: CGFloat
    var bottomInset: CGFloat
    var drag: SpaceDrag
    var swipes: PhoneRowSwipes
    var handle: SpacesListHandle
    var events: SpacesListEvents

    @Environment(WorkspaceController.self) private var controller
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(LiveConnector.self) private var connector: LiveConnector?

    func makeUIViewController(context: Context) -> SpacesListController {
        let host = PhoneHostContext(context.environment, controller: controller, app: app, connector: connector)
        let list = SpacesListController(host: host, drag: drag, swipes: swipes)
        handle.list = list
        return list
    }

    func updateUIViewController(_ list: SpacesListController, context: Context) {
        handle.list = list
        list.host.update(context.environment)
        list.events = events
        list.dark = context.environment.theme.isDark
        let t = context.transaction
        list.update(blocks: blocks, top: topInset, bottom: bottomInset,
                    animation: t.disablesAnimations ? nil : t.animation)
    }

    static func dismantleUIViewController(_ list: SpacesListController, coordinator: ()) {
        list.teardown()
    }
}

// MARK: - The scroller

/// The list's physics (Telegram's `ListViewScroller`): never shown, its pan on the list's
/// view; the list places its content from its offset.
final class SpacesListScroller: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        panGestureRecognizer.cancelsTouchesInView = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// The status bar's tap for the list (the scroller, hidden, isn't one UIKit offers it to):
/// an empty scroll view as big as the list, behind its blocks, that never takes a touch
/// (`hitTest`), which UIKit picks for the tap; it hands it to the list (back to its start,
/// the screen's bottom, as the old inverted scroll view went to its top) and doesn't
/// scroll itself.
final class SpacesListStatusBarTarget: UIScrollView, UIScrollViewDelegate {
    var tapped: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        scrollsToTop = true
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Scrolled a point down, so UIKit has somewhere to take it.
        let size = CGSize(width: bounds.width, height: bounds.height + 1)
        if contentSize != size { contentSize = size; contentOffset = CGPoint(x: 0, y: 1) }
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        tapped()
        return false
    }
}

/// The list's blocks, in one view that a scroll step moves (`SpacesListController`); a touch
/// off them goes on to the list.
final class SpacesListBlocksView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

extension UIGestureRecognizer {
    /// A scroll view's own pan, wherever it is: the sidebar's list moves its scroller's onto
    /// its own view (`SpacesListScroller`), so its `view` is no scroll view. The pan's
    /// delegate stays its scroll view.
    var isScrollViewPan: Bool {
        (delegate as? UIScrollView)?.panGestureRecognizer === self
    }
}

/// The list's view (Telegram's `ListViewBackingView`): the blocks' hosts, the hidden
/// scroller (its pan is here), the scroll indicator; VoiceOver reads the blocks on screen
/// top to bottom.
final class SpacesListView: UIView {
    fileprivate weak var list: SpacesListController?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A finger on the list stops the list's own scroll (a reveal), as Telegram's.
        if bounds.contains(point), event?.type == .touches { list?.stopScrollAnimation() }
        return super.hitTest(point, with: event)
    }

    override var accessibilityElements: [Any]? {
        get { list?.accessibleHosts() }
        set {}
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        list?.scrollPage(direction) ?? false
    }

    /// The visible part of the list under its insets (the status bar's, the header's), in its coordinates.
    var contentArea: CGRect { list?.contentArea ?? bounds }

    /// Scrolls the list by `step` points: positive brings the content down (what's over the
    /// list's top comes into view), within its ends.
    func scroll(by step: CGFloat) { list?.scroll(by: step) }
}

// MARK: - The list

/// The sidebar's list (`SpacesList`'s blocks), Telegram's way (see the top of this file).
///
/// Only the blocks on screen and half a screen round it are built (realized: a host each,
/// measured as it comes, always before it shows); the others are just their places in the
/// order. The realized ones are a run of the blocks, stacked up from the lowest one, whose
/// bottom is where the list put it (`anchor`, in the list's coordinates); a finger moves
/// that, the scroller's offset only giving the step (Telegram's `ListView`). The scroller's
/// size and offset follow from what's known (`updateScroller`, Telegram's rule): with the
/// first block (the content's start, the screen's bottom) and the last one both built, the
/// exact sum of the heights; with one end only, 2 × 10000, the offset kept from that end, so
/// the other is out of reach until it's built; with neither, 2 × 10000 recentred as it
/// drifts. So the scroller never has an estimate that changes under a fling, and its own
/// rubber band and bounce happen at the real ends.
///
/// A scroll step moves the blocks' container (`content`) by its layer alone, not each host:
/// UIKit tells a hosting view of every move of it or its ancestors, and SwiftUI updates the
/// whole block for it (its transform), and the hosts' controllers their safe area: every block
/// on screen and round it, every frame, about two thirds of the main thread's time in a fling
/// (measured on the iPhone 13 Pro Max). UIKit hears where the container is once the list is at
/// rest (`announceContentOrigin`). While a finger scrolls it and as it decelerates, a display
/// link asks for the display's top rate (`boost`), as Telegram's list does (its auxiliary
/// display link): else the hidden scroller decelerates at 80 Hz, then 60 and 48. At rest the
/// blocks within two screens are built ahead, one a run-loop turn (`schedulePrefetch`), so a
/// fling over them builds none (a card takes up to 14 ms); they're let go past three.
///
/// Whatever grows, comes or goes keeps the bottom of the built run where it is (what's under
/// stays, what's over moves), as the old inverted stack did. A block that changes its own
/// height animates it in SwiftUI inside its host (a card's fold, `SpaceCard.fold`); its host
/// is upside down (its content flipped back), so the block grows and shrinks from its bottom,
/// and an empty view behind it (`DrawnHeight`) reports its height as SwiftUI draws it, frame
/// by frame: the blocks over it move in the same frame. Blocks that come, go or move among
/// the others (a machine's fold, a card dragged) are the list's own animation, on the
/// change's curve (`ListCurve`).
@MainActor
final class SpacesListController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let host: PhoneHostContext
    let drag: SpaceDrag
    let swipes: PhoneRowSwipes
    var events = SpacesListEvents()
    /// The theme is dark (the scroll indicator's ink).
    var dark = true {
        didSet { if dark != oldValue { indicator.backgroundColor = Self.indicatorColor(dark: dark) } }
    }

    private let scroller = SpacesListScroller()
    private let statusBarTarget = SpacesListStatusBarTarget()
    /// The blocks' hosts, moved as one (`moveContent`).
    private let content = SpacesListBlocksView()
    private let indicator = UIView()
    private lazy var interactions = SpaceListDragDrop(drag: drag)
    private var listView: SpacesListView { view as! SpacesListView }

    /// Every block from the content's start up, those going out included until they're gone.
    private var items: [Item] = []
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0
    /// The lowest built block's bottom, laid out (its move's shift aside), in the list.
    private var anchor: CGFloat = 0
    /// Where the hosts are in their container: a block's bottom less `anchor`, plus this,
    /// which changes with `anchor` when the lowest built block does, so they stay put while
    /// the list scrolls (the container moves, to this less `anchor`).
    private var contentShift: CGFloat = 0
    /// The container's origin UIKit last heard of (`announceContentOrigin`).
    private var heardOrigin: CGFloat = 0
    /// The scroller's offset last seen: a finger's step is the change.
    private var lastOffset: CGFloat = 0
    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var ignoreScrolling = false
    private var laying = false
    private var link: CADisplayLink?
    /// While a finger scrolls the list and as it decelerates: asks for the display's top rate.
    private var boost: CADisplayLink?
    private var prefetchScheduled = false
    private var scrollAnimation: ScrollAnimation?
    private var indicatorHide: DispatchWorkItem?

    /// Over the top block (the content's end).
    static let endGap: CGFloat = SpacesList.gap
    /// Telegram's `infiniteScrollSize`: an unknown end is this far.
    static let infinite: CGFloat = 10_000
    /// What a block never built is taken to be (the indicator, a scroll to it).
    static let estimate: CGFloat = 120
    /// Blocks are built within this many screens of the screen: as they come (moving), and
    /// ahead (at rest); let go past `release`.
    static let reach: CGFloat = 0.5
    static let prefetch: CGFloat = 2
    static let release: CGFloat = 3

    init(host: PhoneHostContext, drag: SpaceDrag, swipes: PhoneRowSwipes) {
        self.host = host
        self.drag = drag
        self.swipes = swipes
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = SpacesListView()
        view.list = self
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.isAccessibilityElement = false
        view.accessibilityContainerType = .list
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroller.delegate = self
        view.addSubview(scroller)
        statusBarTarget.tapped = { [weak self] in self?.scrollToStart() }
        view.insertSubview(statusBarTarget, at: 0)
        view.insertSubview(content, aboveSubview: statusBarTarget)
        // Telegram's: the scroller's pan on the list's view, where the touches are.
        view.addGestureRecognizer(scroller.panGestureRecognizer)
        // A tap off the blocks (under short content, over the top one) closes an open row.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedEmpty))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        indicator.isUserInteractionEnabled = false
        indicator.alpha = 0
        indicator.layer.cornerRadius = 1.5
        indicator.layer.cornerCurve = .continuous
        indicator.backgroundColor = Self.indicatorColor(dark: dark)
        view.addSubview(indicator)
        interactions.attach(list: listView)
    }

    func teardown() {
        link?.invalidate()
        link = nil
        boost?.invalidate()
        boost = nil
        interactions.detach()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A new height (a rotation, the keyboard): the content keeps its distance from the bottom.
        let dh = view.bounds.height - height
        height = view.bounds.height
        if width > 0 { anchor += dh }
        let w = view.bounds.width
        if w != width, w > 0 {
            let first = width == 0
            width = w
            // Heights depend on the width: the built blocks measured again, the others' guesses dropped.
            for item in items {
                if item.host != nil { item.measure(width: w) } else { item.known = false }
            }
            // The first layout: the list starts at its start.
            if first, realized == nil { anchor = view.bounds.height - bottomInset }
        }
        relayout()
    }

    // MARK: Blocks

    /// The built run: the first and last built blocks' indices.
    private var realized: (lo: Int, hi: Int)? {
        guard let lo = items.firstIndex(where: { $0.host != nil }),
              let hi = items.lastIndex(where: { $0.host != nil }) else { return nil }
        return (lo, hi)
    }

    /// The blocks (from the start up) and the insets, with the change's animation (nil: at once).
    func update(blocks: [SpacesListBlock], top: CGFloat, bottom: CGFloat, animation: Animation?) {
        // The header's room changed: the content keeps its distance from it.
        anchor -= bottom - bottomInset
        topInset = top
        bottomInset = bottom
        let now = CACurrentMediaTime()
        advance(now)
        let curve = width > 0 ? ListCurve(animation) : nil
        let old = realized
        let startKnown = old?.lo == 0, endKnown = old.map { $0.hi == items.count - 1 } ?? false
        // Where each built block is drawn now.
        var drawnBefore: [String: CGFloat] = [:]
        if old != nil { for (item, bottom) in layout() { drawnBefore[item.id] = bottom + item.shift.value } }

        var byID: [String: Item] = [:]
        for item in items { byID[item.id] = item }
        var next: [Item] = []
        var seen = Set<String>()
        for block in blocks {
            seen.insert(block.id)
            if let item = byID[block.id] {
                item.set(block)
                if item.leaving {
                    // Back before it was gone: it comes again from where it is.
                    item.leaving = false
                    item.presence.retarget(to: 1, curve: curve, now: now)
                }
                next.append(item)
            } else {
                let item = Item(block: block, list: self)
                if curve != nil { item.presence = Tweened(value: 0) }
                item.isNew = true
                next.append(item)
            }
        }
        // What went: at once, or (built) fading in its place while the others close over it.
        for (index, item) in items.enumerated() where !seen.contains(item.id) {
            guard let curve, item.host != nil else {
                unrealize(item)
                continue
            }
            if !item.leaving {
                item.leaving = true
                item.presence.retarget(to: 0, curve: curve, now: now)
            }
            insertLeaving(item, oldIndex: index, into: &next)
        }
        items = next

        // The built run stays a run: from the lowest built block that's still here to the
        // highest, what came between them built too; a known end stays known.
        if width > 0, !items.isEmpty {
            var lo = items.firstIndex { $0.host != nil }
            var hi = items.lastIndex { $0.host != nil }
            if lo == nil, let old {
                // All of the run went at once: the block now in its place.
                lo = min(old.lo, items.count - 1)
                hi = lo
            }
            if startKnown { lo = 0 }
            if endKnown { hi = items.count - 1 }
            if let lo, let hi, lo <= hi {
                for item in items[lo...hi] where item.host == nil { realize(item) }
            }
        }
        // New ones come in (growing from nothing), on the change's curve.
        for item in items where item.isNew {
            item.isNew = false
            if item.host != nil, let curve { item.presence.retarget(to: 1, curve: curve, now: now) } else { item.presence = Tweened(value: 1) }
        }
        // Blocks that moved among the others (a dragged card's lane) glide from where they were.
        for (item, bottom) in layout() where !item.leaving {
            guard let was = drawnBefore[item.id], abs(was - (bottom + item.shift.value)) > 0.5 else { continue }
            item.shift = Tweened(value: was - bottom)
            item.shift.retarget(to: 0, curve: curve, now: now)
        }
        orderSubviews()
        relayout()
        startLinkIfNeeded()
    }

    /// A block going out keeps its place among the others: over the one that was under it.
    private func insertLeaving(_ item: Item, oldIndex: Int, into next: inout [Item]) {
        var at = 0
        var i = oldIndex - 1
        while i >= 0 {
            if let found = next.firstIndex(where: { $0 === items[i] }) {
                at = found + 1
                break
            }
            i -= 1
        }
        next.insert(item, at: min(at, next.count))
    }

    /// Builds a block's host and measures it.
    private func realize(_ item: Item) {
        guard item.host == nil else { return }
        let host = item.makeHost()
        addChild(host)
        content.addSubview(host.view)
        host.didMove(toParent: self)
        item.measure(width: width)
    }

    private func unrealize(_ item: Item) {
        guard let host = item.host else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        item.host = nil
    }

    /// Later blocks (higher up) over earlier ones, those going out under all.
    private func orderSubviews() {
        for item in items where !item.leaving { if let v = item.host?.view { content.addSubview(v) } }
        for item in items where item.leaving { if let v = item.host?.view { content.insertSubview(v, at: 0) } }
    }

    /// A block's height as SwiftUI draws it (mid-animation, frame by frame).
    fileprivate func drawn(_ item: Item, _ height: CGFloat) {
        guard item.host != nil, abs(item.apparent - height) > 0.01 else { return }
        // Wholly under the screen (scrolled away from), it changes downward, so what's on screen
        // stays: else an agent's row coming or going down there moved the cards in view (and
        // as they're kept within the list's end only when it shrinks, they crept on).
        if let bottom = layout().first(where: { $0.0 === item })?.1,
           bottom + item.shift.value - item.drawnHeight >= view.bounds.height {
            let step = (height - item.apparent) * item.presence.value
            anchor += step
            contentShift += step
        }
        item.apparent = height
        relayout(reporting: item)
    }

    /// A block's height once its change is laid out (its host's size).
    fileprivate func measured(_ item: Item, _ height: CGFloat) {
        guard item.host != nil, abs(item.height - height) > 0.01 else { return }
        item.height = height
        item.known = true
        relayout(reporting: item)
    }

    // MARK: Layout

    /// The built blocks and their bottoms laid out, stacked up from `anchor`.
    private func layout() -> [(Item, CGFloat)] {
        guard let (lo, hi) = realized else { return [] }
        var out: [(Item, CGFloat)] = []
        var y = anchor
        for item in items[lo...hi] {
            out.append((item, y))
            y -= item.drawnHeight
        }
        return out
    }

    /// The content's start (the first block's bottom) in the list, when it's built.
    private var startEdge: CGFloat? {
        guard let r = realized, r.lo == 0 else { return nil }
        return anchor
    }

    /// The content's end (over the last block, its gap) in the list, when it's built.
    private var endEdge: CGFloat? {
        guard let (lo, hi) = realized, hi == items.count - 1 else { return nil }
        return items[lo...hi].reduce(anchor) { $0 - $1.drawnHeight } - Self.endGap
    }

    /// The visible part of the list under its insets.
    var contentArea: CGRect {
        let b = view.bounds
        return CGRect(x: 0, y: topInset, width: b.width, height: max(0, b.height - topInset - bottomInset))
    }

    private var interacting: Bool { scroller.isTracking || scroller.isDecelerating }

    /// Nothing moves the list: no finger, no deceleration, none of its own animations.
    private var atRest: Bool { !interacting && scrollAnimation == nil && link == nil }

    /// Everything in its place: the list's own scroll's step, the ends kept at rest, the
    /// blocks built and let go round the screen, the scroller's size and offset, each host's
    /// frame (Telegram's `updateScrollViewDidScroll`, `updateScroller`, its items' frames).
    ///
    /// `reporting`: the block whose host is in the middle of its update (its height came from
    /// there): it stays built meanwhile.
    private func relayout(reporting: Item? = nil) {
        guard isViewLoaded, !laying, width > 0 else { return }
        laying = true
        defer { laying = false }
        let h = view.bounds.height
        if var animation = scrollAnimation {
            let step = animation.step(at: CACurrentMediaTime()) { [unowned self] in self.revealNeed($0) }
            scrollAnimation = step.done ? nil : animation
            anchor += step.value
        }
        if realized == nil, let first = items.first {
            // Nothing built (the first layout): the start at the screen's bottom.
            realize(first)
            anchor = h - bottomInset
        }
        for _ in 0..<100 {
            if !interacting, scrollAnimation == nil { keepWithinEnds() }
            if !fill(keeping: reporting) { break }
        }
        updateScroller()
        let scale = max(1, view.traitCollection.displayScale)
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        for (item, bottom) in layout() {
            item.place(bottom: px(bottom + item.shift.value - anchor + contentShift), width: width)
        }
        moveContent(to: px(contentShift - anchor))
        if !interacting, scrollAnimation == nil { announceContentOrigin() }
        placeIndicator()
        events.overscroll(startEdge.map { max(0, (h - bottomInset) - $0) } ?? 0)
        if atRest { schedulePrefetch() }
    }

    /// Moves the blocks' container to `origin` (its bounds' top), by its layer: UIKit doesn't
    /// hear of it, so the hosts and their controllers don't either (see the class's notes).
    private func moveContent(to origin: CGFloat) {
        let b = view.bounds
        let center = CGPoint(x: b.midX, y: b.midY)
        if content.bounds.size != b.size || content.center != center {
            content.center = center
            content.bounds = CGRect(x: 0, y: origin, width: b.width, height: b.height)
            heardOrigin = origin
        } else if content.layer.bounds.minY != origin {
            content.layer.bounds.origin.y = origin
        }
    }

    /// At rest UIKit hears where the container is, from where it last heard (so it notices):
    /// SwiftUI in the hosts knows again where they are on screen, the controllers their
    /// safe area. Once a scroll, for the blocks built.
    private func announceContentOrigin() {
        let origin = content.layer.bounds.minY
        guard origin != heardOrigin else { return }
        content.layer.bounds.origin.y = heardOrigin
        UIView.performWithoutAnimation { content.bounds.origin.y = origin }
        heardOrigin = origin
    }

    /// At rest, builds the next blocks within `prefetch` screens, one a run-loop turn.
    private func schedulePrefetch() {
        guard !prefetchScheduled, view.window != nil else { return }
        prefetchScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prefetchScheduled = false
            guard self.atRest, self.width > 0,
                  self.fill(keeping: nil, reach: self.view.bounds.height * Self.prefetch) else { return }
            // The next one, next turn.
            self.relayout()
        }
    }

    /// At rest the content stays within its known ends: its start not over the header's
    /// room, its end not under the status bar's (a short list at its start).
    private func keepWithinEnds() {
        let h = view.bounds.height
        if let start = startEdge {
            var s = start - (h - bottomInset)
            if let end = endEdge {
                let content = start - end
                s = min(s, max(0, topInset + content + bottomInset - h))
            }
            s = max(0, s)
            anchor += s - (start - (h - bottomInset))
        } else if let end = endEdge, end > topInset {
            anchor -= end - topInset
        }
    }

    /// Builds a block coming within `reach` of the screen (half a screen; ahead at rest, two),
    /// or lets go one past three (not while it moves); true when something changed.
    private func fill(keeping busy: Item?, reach: CGFloat? = nil) -> Bool {
        guard let (lo, hi) = realized else { return false }
        let h = view.bounds.height
        let near = reach ?? h * Self.reach, far = h * Self.release
        // Under: the lowest built one's bottom over the screen's bottom (and `near`). The hosts
        // stay where they are in their container (`contentShift` follows `anchor`).
        if lo > 0, anchor < h + near {
            let item = items[lo - 1]
            realize(item)
            anchor += item.drawnHeight
            contentShift += item.drawnHeight
            orderSubviews()
            return true
        }
        let top = items[lo...hi].reduce(anchor) { $0 - $1.drawnHeight }
        if hi < items.count - 1, top > -near {
            realize(items[hi + 1])
            orderSubviews()
            return true
        }
        // Let go: wholly `far` past the bottom or the top.
        if lo < hi, anchor - items[lo].drawnHeight > h + far, !items[lo].moving, items[lo] !== busy {
            anchor -= items[lo].drawnHeight
            contentShift -= items[lo].drawnHeight
            unrealize(items[lo])
            return true
        }
        if lo < hi, top + items[hi].drawnHeight < -far, !items[hi].moving, items[hi] !== busy {
            unrealize(items[hi])
            return true
        }
        return false
    }

    /// The scroller's size and offset from what's known (Telegram's `updateScroller`), its
    /// scroll events ignored meanwhile.
    private func updateScroller() {
        let b = view.bounds
        let h = b.height
        let infinite = Self.infinite
        ignoreScrolling = true
        defer {
            lastOffset = scroller.contentOffset.y
            ignoreScrolling = false
        }
        if scroller.frame != b { scroller.frame = b }
        if statusBarTarget.frame != b { statusBarTarget.frame = b }
        var size = CGSize(width: b.width, height: 2 * infinite)
        var offset: CGFloat
        if let start = startEdge, let end = endEdge {
            size.height = max(h, topInset + (start - end) + bottomInset)
            offset = size.height - h - (start - (h - bottomInset))
        } else if let start = startEdge {
            offset = size.height - h - (start - (h - bottomInset))
        } else if let end = endEdge {
            offset = topInset - end
        } else {
            offset = scroller.contentOffset.y
            if abs(offset - infinite) > infinite / 2 { offset = infinite }
        }
        if scroller.contentSize != size { scroller.contentSize = size }
        if abs(scroller.contentOffset.y - offset) > 0.001 { scroller.contentOffset = CGPoint(x: 0, y: offset) }
    }

    // MARK: Animation

    /// Brings the moves to `now`, drops the blocks that went.
    private func advance(_ now: CFTimeInterval) {
        var gone: [Item] = []
        for item in items {
            item.presence.advance(now)
            item.shift.advance(now)
            if item.leaving, !item.presence.moving { gone.append(item) }
        }
        guard !gone.isEmpty else { return }
        // The lowest built one going: the next takes its bottom (it had shrunk to nothing).
        for item in gone { unrealize(item) }
        items.removeAll { item in gone.contains { $0 === item } }
    }

    private var animating: Bool {
        scrollAnimation != nil || items.contains { $0.moving }
    }

    private func startLinkIfNeeded() {
        guard animating, link == nil else { return }
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick))
        link.preferredFrameRateRange = PhoneMotion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick() {
        advance(CACurrentMediaTime())
        relayout()
        if !animating {
            link?.invalidate()
            link = nil
            relayout()
            if !interacting { scheduleIndicatorHide() }
        }
    }

    /// The display's top rate while a finger scrolls the list and as it decelerates (Telegram's
    /// auxiliary display link, without its dot: asking is enough). UIKit decelerates the hidden
    /// scroller at 80 Hz else, 60 and 48 as it slows (measured: a fling had 6 of 70 frames at
    /// 120 Hz; with this, 74 of 96, the rest its last slow points at 60).
    private func boostFrameRate() {
        guard boost == nil else { return }
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.boostTick))
        link.preferredFrameRateRange = PhoneMotion.frameRate
        link.add(to: .main, forMode: .common)
        boost = link
    }

    /// Stops asking once the list stops, whatever stopped it (a finger that caught it and let
    /// go unmoved tells the delegate nothing): it's at rest, laid out as such.
    fileprivate func boostTick() {
        guard !interacting else { return }
        boost?.invalidate()
        boost = nil
        scrollEnded()
    }

    private final class LinkTarget: NSObject {
        weak var list: SpacesListController?
        init(_ list: SpacesListController) { self.list = list }
        @objc func tick() { MainActor.assumeIsolated { list?.tick() } }
        @objc func boostTick() { MainActor.assumeIsolated { list?.boostTick() } }
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !ignoreScrolling else { return }
        let delta = scrollView.contentOffset.y - lastOffset
        lastOffset = scrollView.contentOffset.y
        anchor -= delta
        relayout()
        showIndicator()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        boostFrameRate()
        stopScrollAnimation()
        // Scrolling closes an open row (Telegram: as the list's drag begins).
        if swipes.openID != nil { swipes.closeAll() }
        events.dragging(true)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        events.dragging(false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollEnded()
    }

    private func scrollEnded() {
        relayout()
        scheduleIndicatorHide()
    }

    /// The list's own scroll (`reveal`) stops where it is.
    func stopScrollAnimation() {
        guard scrollAnimation != nil else { return }
        scrollAnimation = nil
        scrollEnded()
    }

    /// Scrolls by `step` points (positive: the content comes down), within its ends; a
    /// card's drag near the list's top or bottom.
    func scroll(by step: CGFloat) {
        guard abs(step) > 0.1 else { return }
        anchor += step
        // `relayout` keeps it within the known ends (no finger is on the scroller meanwhile).
        relayout()
        showIndicator()
        scheduleIndicatorHide()
    }

    /// Brings block `id` into view (see `SpacesListHandle.reveal`).
    func reveal(_ id: String, duration: Double) {
        guard !scroller.isTracking, items.contains(where: { $0.id == id }) else { return }
        scroll(to: id, duration: duration)
    }

    /// Back to the content's start (the screen's bottom): the status bar's tap.
    func scrollToStart() {
        guard !scroller.isTracking, !items.isEmpty else { return }
        scroll(to: nil, duration: 0.35)
    }

    /// The list's own scroll, to block `id` or (nil) to the start.
    private func scroll(to id: String?, duration: Double) {
        // UIKit's deceleration stops where it is (Telegram's `stopScrolling`).
        ignoreScrolling = true
        scroller.setContentOffset(scroller.contentOffset, animated: false)
        ignoreScrolling = false
        // Far off (more than two screens, not built): Telegram's way, the list is laid out
        // afresh a screen short of it, and scrolls the last screen.
        let h = view.bounds.height
        let (need, exact) = revealNeed(id)
        if !exact, abs(need) > 2 * h, let k = id.map({ id in items.firstIndex { $0.id == id } }) ?? 0 {
            jump(to: k, from: need > 0 ? -h : h, top: need > 0 && id != nil)
        }
        scrollAnimation = ScrollAnimation(id: id, startTime: CACurrentMediaTime(), duration: duration)
        showIndicator()
        startLinkIfNeeded()
        relayout()
    }

    /// Builds block `k` alone where it would show (its top at the list's top, or its bottom at
    /// the bottom), moved by `offset`; the blocks round it come with the next layout.
    private func jump(to k: Int, from offset: CGFloat, top: Bool) {
        let item = items[k]
        for other in items where other !== item && other.host != nil && !other.leaving { unrealize(other) }
        if items.contains(where: { $0.leaving && $0.host != nil }) {
            // Blocks going out stay out of the run: gone at once.
            for other in items where other.leaving { unrealize(other) }
            items.removeAll { $0.leaving }
        }
        realize(item)
        let area = contentArea
        let bottom = top ? area.minY + item.height : area.maxY
        anchor = bottom + offset
        orderSubviews()
    }

    /// How far the content has to come down (negative: go up) for block `id` to show whole
    /// (its bottom, when it's taller than the list): the least, within the known ends, with
    /// the heights as they'll be; a block not built is guessed at from the built ones' edge.
    private func revealNeed(_ id: String?) -> (CGFloat, exact: Bool) {
        guard let (lo, hi) = realized else { return (0, true) }
        func final(_ i: Item) -> CGFloat { i.leaving ? 0 : (i.host != nil || i.known ? i.height : Self.estimate) }
        guard let id else {
            // The start: exact once the first block is built, else guessed from the built ones.
            let start = items[0..<lo].reduce(anchor) { $0 + final($1) }
            return (contentArea.maxY - start, lo == 0)
        }
        guard let k = items.firstIndex(where: { $0.id == id }) else { return (0, true) }
        let exact = items[k].host != nil
        // Its bottom, laid out with the heights as they'll be.
        var y = anchor
        if k < lo {
            for i in k..<lo { y += final(items[i]) }
        } else {
            for i in lo..<k { y -= final(items[i]) }
        }
        let bottom = y, height = final(items[k])
        let area = contentArea
        var need: CGFloat = 0
        if height > area.height || bottom > area.maxY {
            need = area.maxY - bottom
        } else if bottom - height < area.minY {
            need = area.minY - (bottom - height)
        }
        // Not past the known ends (as they'll be).
        if lo == 0 {
            need = max(need, area.maxY - anchor)
        }
        if hi == items.count - 1 {
            let end = items[lo...hi].reduce(anchor) { $0 - final($1) } - Self.endGap
            if lo == 0, anchor - end < area.height { return (area.maxY - anchor, exact) }
            need = min(need, area.minY - end)
        }
        return (need, exact)
    }

    // MARK: Scroll indicator

    private static func indicatorColor(dark: Bool) -> UIColor {
        dark ? UIColor(white: 1, alpha: 0.35) : UIColor(white: 0, alpha: 0.35)
    }

    /// UIKit's look: 3 pt wide, 3 pt from the edge, between the insets, shrinking pulled
    /// past an end. Where the blocks aren't built, their last heights (or a guess) stand in.
    private func placeIndicator() {
        let b = view.bounds
        let area = contentArea
        let track = CGRect(x: b.width - 6, y: area.minY + 3, width: 3, height: max(0, area.height - 6))
        guard let (lo, _) = realized else { return indicator.isHidden = true }
        func guess(_ i: Item) -> CGFloat { i.host != nil ? i.drawnHeight : (i.known ? i.height : Self.estimate) }
        let content = items.reduce(Self.endGap) { $0 + guess($1) }
        let range = content - area.height
        guard range > 0.5, track.height > 0 else { return indicator.isHidden = true }
        indicator.isHidden = false
        // How far it's scrolled from its start.
        let s = items[0..<lo].reduce(anchor - area.maxY) { $0 + guess($1) }
        var height = max(36, track.height * area.height / content)
        let over = s < 0 ? -s : max(0, s - range)
        height = max(7, height - over)
        let f = min(max(s / range, 0), 1)
        let bottom = track.maxY - f * (track.height - height)
        indicator.frame = CGRect(x: track.minX, y: bottom - height, width: 3, height: height)
    }

    private func showIndicator() {
        indicatorHide?.cancel()
        indicatorHide = nil
        guard indicator.alpha < 1 else { return }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.indicator.alpha = 1
        }
    }

    private func scheduleIndicatorHide() {
        indicatorHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.interacting, self.scrollAnimation == nil else { return }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.indicator.alpha = 0
            }
        }
        indicatorHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Taps

    @objc private func tappedEmpty() {
        events.tapped()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === view
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: VoiceOver

    /// The blocks on screen, top to bottom (Telegram's reading order).
    fileprivate func accessibleHosts() -> [Any] {
        let area = view.bounds
        return items
            .compactMap { $0.leaving ? nil : $0.host?.view }
            .filter { content.convert($0.frame, to: view).intersects(area) }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    /// Three fingers: a page at a time.
    fileprivate func scrollPage(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let page = contentArea.height * 0.8
        let before = anchor
        switch direction {
        case .up: scroll(by: page)
        case .down: scroll(by: -page)
        default: return false
        }
        guard abs(anchor - before) > 0.5 else { return false }
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }

    // MARK: An item

    /// A block, and its host while it's built.
    fileprivate final class Item {
        let id: String
        private(set) var block: SpacesListBlock
        var host: UIHostingController<PhoneHosted<SpacesListBlockRoot>>?
        /// Its height laid out (its host's), and as drawn now (mid-animation); `known`: measured
        /// at this width (else a guess for a block not built).
        var height: CGFloat = 0
        var apparent: CGFloat = 0
        var known = false
        /// Coming in (0 → 1) or going out (→ 0): its share of the height, its opacity.
        var presence = Tweened(value: 1)
        /// A move among the others: from where it was drawn to its place (→ 0).
        var shift = Tweened(value: 0)
        var leaving = false
        /// Came in this update.
        var isNew = false
        private weak var list: SpacesListController?

        init(block: SpacesListBlock, list: SpacesListController) {
            id = block.id
            self.block = block
            self.list = list
        }

        /// Its share of the stack now.
        var drawnHeight: CGFloat { apparent * presence.value }
        var moving: Bool { presence.moving || shift.moving || leaving }

        func makeHost() -> UIHostingController<PhoneHosted<SpacesListBlockRoot>> {
            let list = list!
            let host = UIHostingController.moving(PhoneHosted(context: list.host, content: root(block, list: list), edges: []))
            host.view.clipsToBounds = false
            host.view.isOpaque = false
            // Upside down, its content flipped back: SwiftUI's origin is the block's bottom, so
            // it grows and shrinks from there.
            host.view.transform = CGAffineTransform(scaleX: 1, y: -1)
            self.host = host
            return host
        }

        private func root(_ block: SpacesListBlock, list: SpacesListController) -> SpacesListBlockRoot {
            SpacesListBlockRoot(
                block: block, drag: list.drag, swipes: list.swipes,
                drawn: { [weak list, weak self] h in
                    guard let list, let self else { return }
                    MainActor.assumeIsolated { list.drawn(self, h) }
                },
                measured: { [weak list, weak self] h in
                    guard let list, let self else { return }
                    MainActor.assumeIsolated { list.measured(self, h) }
                },
                tapped: { [weak list] in MainActor.assumeIsolated { list?.events.tapped() } })
        }

        /// A new block value: its host gets it when it changed (a machine's fold flag aside,
        /// which the header reads itself, so its change keeps its animation).
        func set(_ block: SpacesListBlock) {
            defer { self.block = block }
            guard !block.kind.sameContent(as: self.block.kind), let list, let host else { return }
            host.rootView = PhoneHosted(context: list.host, content: root(block, list: list), edges: [])
        }

        func measure(width: CGFloat) {
            guard let host else { return }
            let fit = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            height = fit.height
            apparent = fit.height
            known = true
        }

        /// Its bottom at `bottom` in the list.
        func place(bottom: CGFloat, width: CGFloat) {
            guard let v = host?.view else { return }
            let size = CGSize(width: width, height: max(0, height))
            if v.bounds.size != size { v.bounds = CGRect(origin: .zero, size: size) }
            let center = CGPoint(x: width / 2, y: bottom - size.height / 2)
            if v.center != center { v.center = center }
            let alpha = presence.value
            if v.alpha != alpha { v.alpha = alpha }
        }
    }
}

// MARK: - A block in its host

/// A block of the list as its host shows it: the list's environment (its drag, its rows'
/// swipes, its own menus), upside down and flipped back (see `SpacesListController`), its
/// height reported as it's drawn and as it's laid out.
struct SpacesListBlockRoot: View {
    var block: SpacesListBlock
    var drag: SpaceDrag
    var swipes: PhoneRowSwipes
    var drawn: (CGFloat) -> Void
    var measured: (CGFloat) -> Void
    var tapped: () -> Void

    var body: some View {
        SpacesListTopLayout {
            SpacesListBlockView(block: block)
                .background(DrawnHeight(changed: drawn))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
                // A tap off the rows' own taps closes an open row.
                .contentShape(Rectangle())
                .onTapGesture { tapped() }
                .flippedUp()
        }
        .environment(swipes)
        .environment(drag)
        .environment(\.invertedList, true)
    }
}

/// A block's view with the room `SpacesList` gives it.
struct SpacesListBlockView: View {
    var block: SpacesListBlock
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        switch block.kind {
        case .machine(let machine, _):
            // Read here, not from the block: its change keeps its transaction (the fold's spring).
            MachineHeader(machine: machine, folded: controller.foldedMachines.contains(machine.id))
                .padding(.horizontal, SpacesList.side)
                .padding(.top, -2)
                .padding(.bottom, 10)
        case .note(let text, let icon, let machine):
            NoteRow(text: text, icon: icon) {
                if let machine { controller.newSpace(machine: .some(machine)) }
            }
            .padding(.horizontal, SpacesList.side)
            .padding(.bottom, SpacesList.gap)
        case .card(let space):
            SpaceCard(space: space)
                .padding(.horizontal, SpacesList.side)
                .padding(.bottom, SpacesList.gap)
        }
    }
}

/// Its one child at its top, as tall as it wants to be (the host's height is the list's
/// business): measured unbounded, the child's own height.
struct SpacesListTopLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fit = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        let width = proposal.width ?? fit.width
        guard let h = proposal.height, h.isFinite, h < 1_000_000 else { return CGSize(width: width, height: fit.height) }
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// An empty view behind a block: SwiftUI sets its frame as it draws the block, mid-animation
/// too, frame by frame, so its height is the block's as drawn.
private struct DrawnHeight: UIViewRepresentable {
    var changed: (CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.changed = changed
    }

    final class Probe: UIView {
        var changed: (CGFloat) -> Void = { _ in }

        private var last: CGFloat = -1

        // SwiftUI sets it by `frame` (seen on iOS 27), as it may by `bounds`.
        override var bounds: CGRect {
            didSet { report() }
        }

        override var frame: CGRect {
            didSet { report() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            let h = bounds.height
            guard h != last else { return }
            last = h
            changed(h)
        }
    }
}

// MARK: - Motion

/// The curve of a change's animation, played by the list on its own blocks: SwiftUI's
/// animations can't be evaluated outside SwiftUI, so the ones the list sees are known by
/// name: a card dragged among the others (`SpaceDrag.part`, ease-out 0.16 s); anything
/// else the fold's spring (`SpaceCard.fold`, critically damped 0.35 s).
struct ListCurve {
    private enum Shape {
        case spring(PhoneSpring)
        case curve(UnitCurve, duration: Double)
    }

    private let shape: Shape

    init?(_ animation: Animation?) {
        guard let animation else { return nil }
        if animation == SpaceDrag.part {
            shape = .curve(.easeOut, duration: 0.16)
        } else {
            shape = .spring(PhoneSpring(duration: 0.35, bounce: 0))
        }
    }

    init(easeOut duration: Double) {
        shape = .curve(.easeOut, duration: duration)
    }

    /// Progress 0...1 at `t` seconds, and whether it's over.
    func progress(at t: Double) -> (CGFloat, Bool) {
        switch shape {
        case .spring(let spring):
            let x = spring.state(at: max(0, t), x0: -1, v0: 0).x
            return abs(x) < 0.0005 && t > 0 ? (1, true) : (CGFloat(1 + x), false)
        case .curve(let curve, let duration):
            guard duration > 0, t < duration else { return (1, true) }
            return (CGFloat(curve.value(at: max(0, t) / duration)), false)
        }
    }
}

/// A value the list moves on a curve (Telegram's item animations, on the list's display link).
struct Tweened {
    private(set) var value: CGFloat
    private(set) var target: CGFloat
    private var from: CGFloat = 0
    private var curve: ListCurve?
    private var startTime: CFTimeInterval = 0

    init(value: CGFloat) {
        self.value = value
        target = value
    }

    var moving: Bool { curve != nil }

    /// Heads for `target` from where it is now (at once without a curve).
    mutating func retarget(to target: CGFloat, curve: ListCurve?, now: CFTimeInterval) {
        self.target = target
        guard let curve else {
            value = target
            self.curve = nil
            return
        }
        from = value
        self.curve = curve
        startTime = now
    }

    mutating func advance(_ now: CFTimeInterval) {
        guard let curve else { return }
        let (p, done) = curve.progress(at: now - startTime)
        if done {
            value = target
            self.curve = nil
        } else {
            value = from + (target - from) * p
        }
    }
}

/// The list's own scroll to a block (`reveal`): ease-out over `duration`, toward where the
/// block shows, taken afresh each frame (the block may still be unfolding, or not built yet):
/// each step is the part of what's left that the curve covers in it. Ended on a guess (the
/// block wasn't built), it goes on for what's left once it is.
private struct ScrollAnimation {
    /// The block to show; nil, the content's start.
    var id: String?
    var startTime: CFTimeInterval
    var duration: Double
    var progress: CGFloat = 0
    var legs = 1

    mutating func step(at now: CFTimeInterval, need: (String?) -> (CGFloat, exact: Bool)) -> (value: CGFloat, done: Bool) {
        let (p, done) = ListCurve(easeOut: duration).progress(at: now - startTime)
        let (left, exact) = need(id)
        if done || progress >= 1 {
            guard !exact, legs < 4 else { return (left, true) }
            legs += 1
            startTime = now
            duration = 0.2
            progress = 0
            return (left, false)
        }
        let step = left * (p - progress) / (1 - progress)
        progress = p
        return (step, false)
    }
}
