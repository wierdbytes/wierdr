import SwiftUI
import UIKit
import WierdrModel

/// Telegram's folder motion (`ChatListContainerNode`, `HorizontalTabsComponent`): its
/// "spring" transition curve, a cubic bezier (`PhoneMotion.telegramCurve`), for the
/// pages and the strip's pill.
enum PhonePagingMotion {
    /// The pages and the pill settling after a swipe; the pill and the strip after a tap.
    static let settle = Animation.timingCurve(0.38, 0.7, 0.125, 1.0, duration: 0.45)
    static let settleDuration = 0.45
    /// The pages sliding after a tap on a tab.
    static let tapSlideDuration = 0.35
    /// Tabs coming and going: the strip lays itself out again.
    static let relayout = Animation.easeInOut(duration: relayoutDuration)
    static let relayoutDuration = 0.2

    /// The strips along the screen's sides where a swipe is a row's (its actions), not the pager's.
    static func edgeWidth(_ width: CGFloat) -> CGFloat { min(max(width / 6, 22), 80) }

    /// A swipe past the first or last tab: 0.4 of the finger's way at first, never past 600 pt.
    static func rubberBand(_ x: CGFloat) -> CGFloat { 0.4 * x / (1 + x / 1500) }
}

/// What moves the pages on screen (`PhonePagerController`): Core Animation, outside SwiftUI.
@MainActor
protocol PhonePagerSurface: AnyObject {
    /// Where the pages are drawn now (mid-slide too): page i is (i − position) widths from the left.
    var drawnPosition: CGFloat { get }
    /// The pages for `PhoneSpacePaging.pages` in their places at its position, at once (a slide
    /// stops): the ones missing are made, the others let go.
    func place()
    /// The current page's neighbours made, if missing, the pages going on as they move
    /// (making a page takes a while: a finger takes them after that, where they are then).
    func makeNeighbours()
    /// The finger: the pages at `position`, at once.
    func track(_ position: CGFloat)
    /// From where the pages are drawn to `position` along Telegram's curve; `done` when it
    /// gets there (not when something else took the pages first).
    func slide(to position: CGFloat, duration: Double, done: @escaping () -> Void)
}

/// What moves the strip's pill and scroll (`PhoneStripMotion`): Core Animation too, so they
/// move with the pages, in the same transaction and along the same curve, whatever the
/// main thread is doing.
@MainActor
protocol PhoneStripSurface: AnyObject {
    /// The pill to `pill` and the strip scrolled to keep it in sight, from where they're drawn.
    func follow(_ pill: PhoneStripPill, _ move: PhoneStripMove)
}

/// Where the strip's pill is: on a tab, and how far toward its neighbour (as
/// `PhoneSpacePaging.fraction`: a finger moving left, negative, brings the next tab).
struct PhoneStripPill: Equatable {
    var scope: PhoneListScope
    var fraction: CGFloat
}

enum PhoneStripMove {
    /// At once (the tabs changed).
    case jump
    /// A finger's step: at once, but the strip no faster than the pill.
    case track
    /// Along Telegram's curve, in this many seconds.
    case settle(Double)
}

/// Which tab of the iPhone's list shows, and how far a swipe or a slide has moved
/// the pages: shared by the strip (`PhoneSpaceTabs`, its pill) and the pages
/// (`PhoneSpacePager`). Telegram's folder paging: the pages and the pill follow the
/// finger, and settle on a tab when it lets go.
///
/// The pages, the strip's pill and its scroll move by Core Animation
/// (`PhonePagerSurface`, `PhoneStripSurface`), told here as they move: none of it is
/// observed, so a finger's step updates no SwiftUI view.
@MainActor
@Observable
final class PhoneSpacePaging {
    /// The tabs: "All", then the spaces.
    private(set) var scopes: [PhoneListScope] = [.all]
    /// The page in place, or the one the pages are settling on.
    private(set) var selected = 0
    /// A finger is moving the pages.
    @ObservationIgnored private(set) var isDragging = false
    /// Bumped by a tap on the current tab: its list scrolls to its bottom (the newest).
    private(set) var scrollToNewest: [PhoneListScope: Int] = [:]

    /// How far the pages are off `selected`, in page widths; a finger moving right is positive.
    @ObservationIgnored private(set) var fraction: CGFloat = 0
    /// A tap on a tab that isn't next to the current one: the page it left, sliding
    /// out beside the new one (none of the tabs between show).
    @ObservationIgnored private(set) var leaving: Int?
    @ObservationIgnored weak var surface: PhonePagerSurface?
    /// The strip (a new one is told where the pill is).
    @ObservationIgnored weak var strip: PhoneStripSurface? {
        didSet { strip?.follow(stripPill, .jump) }
    }
    /// Where the strip's pill is: after a swipe it moves with the pages; after a tap on
    /// its own, slower.
    @ObservationIgnored private(set) var stripPill = PhoneStripPill(scope: .all, fraction: 0)
    /// Where the pages were when the finger took them, in page widths.
    @ObservationIgnored private var dragStart: CGFloat = 0
    /// Counts the slides, so a finished one doesn't end a later one.
    @ObservationIgnored private var slideID = 0

    /// The tab at the center of the screen, fractional while moving (page i is at (i − position) widths).
    var position: CGFloat { CGFloat(selected) - fraction }

    var selectedScope: PhoneListScope { scopes[min(selected, scopes.count - 1)] }

    /// The tab to keep when the tabs change: the one last chosen (a swipe or a tap, even
    /// before the pages are at rest), else the one last shown before launch.
    var preferredScope: PhoneListScope { chosen ?? savedScope }
    @ObservationIgnored private var chosen: PhoneListScope?

    /// The tab last shown, kept across launches (`phone.tab`: "all" or a space's id). In
    /// UserDefaults, not SwiftUI's `@AppStorage` (a new tab would redraw the whole list),
    /// and written once the pages are at rest: any write redraws every `@AppStorage`
    /// view (the limits under the list).
    private var savedScope: PhoneListScope {
        let id = UserDefaults.standard.string(forKey: Self.savedKey) ?? "all"
        return id == "all" || id.isEmpty ? .all : .space(id)
    }

    private static let savedKey = "phone.tab"

    private func saveTab() {
        let id: String
        switch selectedScope {
        case .all: id = "all"
        case .space(let space): id = space
        }
        if UserDefaults.standard.string(forKey: Self.savedKey) != id { UserDefaults.standard.set(id, forKey: Self.savedKey) }
    }

    /// One page on screen: the tab it shows and where it sits (its index; for a tab
    /// left by a far tap, the place beside the new one).
    struct Page: Hashable {
        var scope: PhoneListScope
        var index: Int
        var place: Int
    }

    /// The strip's pill to tab `index`, `fraction` of the way to its neighbour. At once
    /// and where it is already: nothing (the strip follows the tabs' new places itself).
    private func moveStrip(_ index: Int, fraction: CGFloat, _ move: PhoneStripMove) {
        let pill = PhoneStripPill(scope: scopes[min(max(index, 0), scopes.count - 1)], fraction: fraction)
        if case .jump = move, pill == stripPill { return }
        stripPill = pill
        strip?.follow(pill, move)
    }

    /// The pages that exist: the current one and its neighbours, or during a far tap's
    /// slide the page it left and the new one.
    var pages: [Page] {
        if let leaving, leaving < scopes.count {
            return [Page(scope: scopes[leaving], index: leaving, place: selected + (leaving < selected ? -1 : 1)),
                    Page(scope: scopes[selected], index: selected, place: selected)]
        }
        return (max(0, selected - 1)...min(scopes.count - 1, selected + 1)).map {
            Page(scope: scopes[$0], index: $0, place: $0)
        }
    }

    // MARK: Tabs

    /// The tabs changed (spaces came or went), or the first time: keeps the current tab
    /// where it went; gone, its nearest neighbour that's still there (the next one first),
    /// else "All".
    func update(scopes new: [PhoneListScope], keeping wanted: PhoneListScope) {
        let old = scopes
        guard new != old || selectedScope != wanted else { return }
        let index: Int
        if let i = new.firstIndex(of: wanted) {
            index = i
        } else if let i = new.firstIndex(of: selectedScope) {
            index = i
        } else {
            let at = min(selected, old.count - 1)
            let neighbour = old[(at + 1)...].first(where: new.contains) ?? old[..<at].last(where: new.contains)
            index = neighbour.flatMap { new.firstIndex(of: $0) } ?? 0
        }
        let leavingScope = leaving.map { old[$0] }
        scopes = new.isEmpty ? [.all] : new
        selected = min(index, scopes.count - 1)
        leaving = leavingScope.flatMap { scopes.firstIndex(of: $0) }.flatMap { $0 == selected ? nil : $0 }
        if scopes.count < 2 { fraction = 0 }
        slideID += 1
        surface?.place()
        moveStrip(selected, fraction: isDragging ? fraction : 0, .jump)
        saveTab()
    }

    /// A tap on tab `index`: the pages slide to it (0.35 s), the pill moves (0.45 s).
    /// On the current tab: its list goes to its bottom (the newest).
    func select(_ index: Int) {
        guard scopes.indices.contains(index), !isDragging else { return }
        guard index != selected || fraction != 0 else {
            scrollToNewest[scopes[index], default: 0] += 1
            return
        }
        moveStrip(index, fraction: 0, .settle(PhonePagingMotion.settleDuration))
        chosen = scopes[index]
        slideID += 1
        let id = slideID
        if abs(index - selected) <= 1 && leaving == nil || index == selected {
            // Next to it: the pages slide side by side.
            selected = index
            fraction = 0
            surface?.slide(to: CGFloat(index), duration: PhonePagingMotion.tapSlideDuration) { [weak self] in
                guard let self, id == self.slideID else { return }
                self.surface?.place()
                self.saveTab()
            }
            return
        }
        // Further: the page it leaves goes beside the new one where it is on screen, then both
        // slide (a lower tab comes from the left).
        let from = surface?.drawnPosition ?? position
        let old = selected
        let place = index + (index > old ? -1 : 1)
        let oldOffset = CGFloat(old) - from
        leaving = old
        selected = index
        fraction = CGFloat(index) - (CGFloat(place) - oldOffset)
        surface?.place()
        fraction = 0
        surface?.slide(to: CGFloat(index), duration: PhonePagingMotion.tapSlideDuration) { [weak self] in
            guard let self, id == self.slideID else { return }
            self.leaving = nil
            self.surface?.place()
            self.saveTab()
        }
    }

    // MARK: Swipe

    /// A finger took the pages: they go on from where they are, even mid-slide.
    func dragBegan() {
        // Its neighbours (made after the last slide, or now if it's still on its way), before
        // the pages and the pill are taken where they're drawn.
        surface?.makeNeighbours()
        let at = surface?.drawnPosition ?? position
        slideID += 1
        // A far tap's slide ends here: the page beside the new one is its real neighbour again.
        leaving = nil
        fraction = CGFloat(selected) - at
        dragStart = fraction
        surface?.place()
        moveStrip(selected, fraction: fraction, .track)
        isDragging = true
    }

    /// The finger moved `translation` points (right is positive) on pages `width` wide.
    func dragChanged(translation: CGFloat, width: CGFloat) {
        guard isDragging, width > 0 else { return }
        var x = translation
        // Past the first or last tab the pages resist.
        if selected == 0 && x > 0 { x = PhonePagingMotion.rubberBand(x) }
        if selected == scopes.count - 1 && x < 0 { x = -PhonePagingMotion.rubberBand(-x) }
        fraction = x / width + dragStart
        surface?.track(position)
        moveStrip(selected, fraction: fraction, .track)
    }

    /// The finger let go: fast, one tab its way (or back, against the swipe); slow,
    /// to the next tab past half the width. Pages and pill settle in 0.45 s.
    func dragEnded(translation: CGFloat, velocity: CGFloat, width: CGFloat, cancelled: Bool = false) {
        guard isDragging else { return }
        var target = selected
        if !cancelled {
            if abs(velocity) > 10 {
                if translation < 0 && velocity < 0 { target += 1 } else if translation > 0 && velocity > 0 { target -= 1 }
            } else if abs(translation) > width / 2 {
                target += translation < 0 ? 1 : -1
            }
        }
        target = min(max(target, 0), scopes.count - 1)
        chosen = scopes[target]
        slideID += 1
        let id = slideID
        // The pages' slide first, sent to the render server before SwiftUI redraws what the
        // new tab changes (the header, the tabs' traits): no frame waits for that.
        surface?.slide(to: CGFloat(target), duration: PhonePagingMotion.settleDuration) { [weak self] in
            guard let self, id == self.slideID else { return }
            // At rest: the new tab's neighbours are made now, not while the pages move.
            self.surface?.place()
            self.saveTab()
        }
        // The pill and the strip's scroll with them, in the same transaction.
        moveStrip(target, fraction: 0, .settle(PhonePagingMotion.settleDuration))
        CATransaction.flush()
        fraction = 0
        isDragging = false
        withAnimation(PhonePagingMotion.settle) { selected = target }
    }
}

// MARK: - The pages

/// The iPhone list's pages, one per tab, side by side and as wide as the screen:
/// Telegram's folder paging. Only the current page and its neighbours exist (and
/// during a far tap's slide, the page it left); page i sits (i − position) widths
/// from the left, without parallax.
///
/// The pages are UIKit views (`PhonePagerController`), each a hosting controller with
/// its tab's list, on one layer that a finger moves and Core Animation settles: no
/// SwiftUI update per frame, and the slide plays on at the display's rate whatever the
/// main thread does. A new tab's neighbour is made once the pages are at rest.
///
/// A horizontal swipe that starts in the middle of the screen (not in the edge zones,
/// which are the rows' swipe actions; not over the header, `bottomInset`) moves the
/// pages (`PhonePagerPan`); vertical moves are the pages' own scrolling.
struct PhoneSpacePager<Page: View>: UIViewControllerRepresentable {
    var paging: PhoneSpacePaging
    /// The floating header's height over the pages' bottom: no swipes start there.
    var bottomInset: CGFloat
    /// Swipes page (more than one tab, the list on screen).
    var isEnabled: Bool
    /// What the pages are made from besides their tab: the pages there are made again
    /// only when it changes.
    var pageInputs: AnyHashable
    /// A tab's page.
    @ViewBuilder var page: (PhoneListScope) -> Page

    @Environment(WorkspaceController.self) private var controller
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(LiveConnector.self) private var connector: LiveConnector?

    func makeUIViewController(context: Context) -> PhonePagerController {
        let host = PhoneHostContext(context.environment, controller: controller, app: app, connector: connector)
        let pager = PhonePagerController(paging: paging, host: host)
        paging.surface = pager
        return pager
    }

    func updateUIViewController(_ pager: PhonePagerController, context: Context) {
        pager.host.update(context.environment)
        pager.gesture.bottomInset = bottomInset
        let enabled = isEnabled && paging.scopes.count > 1
        // Off while a drag runs: it is cancelled, the pages settle back.
        if pager.gesture.pan.isEnabled != enabled { pager.gesture.pan.isEnabled = enabled }
        let page = self.page
        pager.makePage = { scope in AnyView(page(scope).ignoresSafeArea(.container, edges: .top)) }
        pager.refresh(inputs: pageInputs)
    }

    static func dismantleUIViewController(_ pager: PhonePagerController, coordinator: ()) {
        pager.gesture.detach()
    }
}

/// The pages' container: a clipping view with one moving layer (`canvas`), the pages on
/// it at their places (page i at i widths), the layer at −position widths.
final class PhonePagerController: UIViewController, PhonePagerSurface {
    let paging: PhoneSpacePaging
    let host: PhoneHostContext
    let gesture = PhonePagerGesture()
    /// A tab's page (its list), set by the representable.
    var makePage: ((PhoneListScope) -> AnyView)?

    private let canvas = Canvas()
    private var hosts: [PhoneListScope: UIHostingController<PhoneHosted<AnyView>>] = [:]
    private var size: CGSize = .zero
    private var pageInputs: AnyHashable?
    /// The slide under way (its id), nil at rest.
    private var sliding: Int?
    private var slideCount = 0
    /// The slide's move (the layer's offset, positive to the left, in points), to solve
    /// where it's drawn (`PhoneMotion.shownTime`).
    private var slideMove: (id: Int, from: CGFloat, to: CGFloat, begin: CFTimeInterval, duration: Double)?
    private static let slideKey = "slide"

    init(paging: PhoneSpacePaging, host: PhoneHostContext) {
        self.paging = paging
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = PagerView()
        view.pager = self
        view.clipsToBounds = true // a neighbour doesn't show beside the pages (in landscape, in the side safe areas)
        view.backgroundColor = .clear
        canvas.backgroundColor = .clear
        view.addSubview(canvas)
        self.view = view
        gesture.paging = paging
        gesture.anchor = view
    }

    /// The representable updated: the pages there are made again if what they're made
    /// from changed; pages are made or let go only at rest.
    func refresh(inputs: AnyHashable) {
        if inputs != pageInputs {
            pageInputs = inputs
            for (scope, host) in hosts {
                if let page = makePage?(scope) { host.rootView = PhoneHosted(context: self.host, content: page) }
            }
        }
        if sliding == nil { place() }
    }

    fileprivate func laidOut() {
        guard view.bounds.size != size else { return }
        size = view.bounds.size
        canvas.bounds = CGRect(origin: .zero, size: size)
        canvas.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        // A new size (rotation): every page and the layer where they belong, at once.
        place()
    }

    // MARK: PhonePagerSurface

    var drawnPosition: CGFloat {
        let w = view.bounds.width
        guard w > 0 else { return paging.position }
        return drawnOffset() / w
    }

    /// Where the layer is drawn when a change made now shows (mid-slide, solved on its curve).
    private func drawnOffset() -> CGFloat {
        if let m = slideMove, m.id == sliding {
            let t = (PhoneMotion.shownTime(view) - m.begin) / m.duration
            return m.from + (m.to - m.from) * CGFloat(PhoneMotion.telegram.value(t))
        }
        return -canvas.transform.tx
    }

    func place() {
        let size = view.bounds.size
        guard size.width > 0 else { return }
        if sliding != nil {
            canvas.layer.removeAnimation(forKey: Self.slideKey)
            sliding = nil
        }
        canvas.transform = CGAffineTransform(translationX: -paging.position * size.width, y: 0)
        let pages = paging.pages
        let wanted = Set(pages.map(\.scope))
        for (scope, host) in hosts where !wanted.contains(scope) {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            hosts[scope] = nil
        }
        for p in pages {
            guard let host = hosts[p.scope] ?? makeHost(p.scope) else { continue }
            host.view.frame = CGRect(x: CGFloat(p.place) * size.width, y: 0, width: size.width, height: size.height)
            let current = p.index == paging.selected
            host.view.isUserInteractionEnabled = current
            host.view.accessibilityElementsHidden = !current
        }
    }

    func makeNeighbours() {
        let size = view.bounds.size
        guard size.width > 0 else { return }
        let i = paging.selected, scopes = paging.scopes
        for j in [i - 1, i + 1] where scopes.indices.contains(j) && hosts[scopes[j]] == nil {
            guard let host = makeHost(scopes[j]) else { continue }
            // Where `place` puts it (a far tap's page beside the new one is let go there).
            host.view.frame = CGRect(x: CGFloat(j) * size.width, y: 0, width: size.width, height: size.height)
            host.view.isUserInteractionEnabled = false
            host.view.accessibilityElementsHidden = true
        }
    }

    private func makeHost(_ scope: PhoneListScope) -> UIHostingController<PhoneHosted<AnyView>>? {
        guard let page = makePage?(scope) else { return nil }
        let host = UIHostingController.moving(PhoneHosted(context: self.host, content: page))
        addChild(host)
        canvas.addSubview(host.view)
        host.didMove(toParent: self)
        hosts[scope] = host
        return host
    }

    func track(_ position: CGFloat) {
        if sliding != nil {
            canvas.layer.removeAnimation(forKey: Self.slideKey)
            sliding = nil
        }
        canvas.transform = CGAffineTransform(translationX: -position * view.bounds.width, y: 0)
    }

    func slide(to position: CGFloat, duration: Double, done: @escaping () -> Void) {
        let w = view.bounds.width
        let from = drawnOffset()
        let to = position * w
        canvas.layer.removeAnimation(forKey: Self.slideKey)
        canvas.transform = CGAffineTransform(translationX: -to, y: 0)
        slideCount += 1
        let id = slideCount
        sliding = id
        guard w > 0, abs(from - to) > 0.25 else {
            // Already there: done on the next turn (the caller sets the tab after this).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sliding == id else { return }
                self.sliding = nil
                done()
            }
            return
        }
        let a = CABasicAnimation(keyPath: PhoneMotion.translationX)
        a.fromValue = -from
        a.toValue = -to
        a.duration = duration
        a.timingFunction = PhoneMotion.telegramCurve
        a.preferredFrameRateRange = PhoneMotion.frameRate
        a.delegate = PhoneAnimationEnd { [weak self] finished in
            guard finished, let self, self.sliding == id else { return }
            self.sliding = nil
            done()
        }
        canvas.layer.add(a, forKey: Self.slideKey)
        slideMove = (id, from, to, CACurrentMediaTime(), duration)
    }

    /// The moving layer: as big as one page, its pages at their places beside it, so it
    /// looks for touches in them, not in its own bounds.
    private final class Canvas: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            for page in subviews.reversed() where page.isUserInteractionEnabled && !page.isHidden {
                if let hit = page.hitTest(page.convert(point, from: self), with: event) { return hit }
            }
            return nil
        }
    }

    /// Lays the pages out with its size, and puts the pan on the window.
    private final class PagerView: UIView {
        weak var pager: PhonePagerController?

        override func layoutSubviews() {
            super.layoutSubviews()
            pager?.laidOut()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            pager?.gesture.attach(to: window?.rootViewController?.view)
        }
    }
}

// MARK: - The swipe

/// Telegram's `InteractiveTransitionGestureRecognizer` for the pages: one finger; it
/// begins once the finger has moved more than 2 pt sideways and less than half that
/// up or down, fails once it has moved more than 2 pt up or down and less than half
/// that sideways, and after 10 pt the larger of the two decides. Before it begins it
/// keeps the moves from the pan's own tracking (which would begin by itself).
/// Touches that start in the edge zones or over the header never reach it (its delegate).
final class PhonePagerPan: UIPanGestureRecognizer {
    private var start: CGPoint = .zero
    private var last: CGPoint = .zero
    private var validated = false

    /// How far the finger moved sideways since it touched down.
    var translationX: CGFloat { last.x - start.x }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
        delaysTouchesBegan = false
        cancelsTouchesInView = true
    }

    override func reset() {
        super.reset()
        validated = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        start = touch.location(in: view)
        last = start
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: view)
        var fireBegan = false
        if !validated {
            let dx = abs(location.x - start.x), dy = abs(location.y - start.y)
            if (dx * dx + dy * dy).squareRoot() > 10 {
                guard dx >= dy else { state = .failed; return }
                validated = true
                fireBegan = true
            } else if dy > 2 && dy > dx * 2 {
                state = .failed
                return
            } else if dx > 2 && dy * 2 < dx {
                validated = true
                fireBegan = true
            }
        }
        guard validated else { return }
        last = location
        super.touchesMoved(touches, with: event)
        if fireBegan && state == .possible { state = .began }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, validated { last = touch.location(in: view) }
        super.touchesEnded(touches, with: event)
    }
}

/// The pages' pan, on the window's root view (it sees the touches on the pages' scroll
/// views, and theirs wait for it); `anchor` is the pages' view, where swipes may start.
@MainActor
final class PhonePagerGesture: NSObject, UIGestureRecognizerDelegate {
    let pan = PhonePagerPan()
    weak var anchor: UIView?
    weak var paging: PhoneSpacePaging?
    /// The header's room at the pages' bottom.
    var bottomInset: CGFloat = 0
    private let boost = PhoneFrameRateBoost()

    override init() {
        super.init()
        pan.delegate = self
        pan.addTarget(self, action: #selector(handle(_:)))
    }

    func attach(to view: UIView?) {
        guard let view, pan.view !== view else { return }
        detach()
        view.addGestureRecognizer(pan)
    }

    func detach() {
        pan.view?.removeGestureRecognizer(pan)
    }

    @objc private func handle(_ pan: PhonePagerPan) {
        guard let paging, let anchor else { return }
        let width = anchor.bounds.width
        switch pan.state {
        case .began:
            boost.start()
            paging.dragBegan()
            paging.dragChanged(translation: pan.translationX, width: width)
        case .changed:
            paging.dragChanged(translation: pan.translationX, width: width)
        case .ended:
            boost.stop()
            paging.dragEnded(translation: pan.translationX, velocity: pan.velocity(in: pan.view).x, width: width)
        case .cancelled, .failed:
            boost.stop()
            paging.dragEnded(translation: pan.translationX, velocity: 0, width: width, cancelled: true)
        default:
            break
        }
    }

    /// Only touches that start on the pages, over the header and outside the edge zones.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let anchor, anchor.window != nil else { return false }
        let p = touch.location(in: anchor)
        let bounds = anchor.bounds
        let edge = PhonePagingMotion.edgeWidth(bounds.width)
        return bounds.contains(p) && p.y <= bounds.height - bottomInset && p.x >= edge && p.x <= bounds.width - edge
    }

    // Every other pan (the pages' scrolling first) waits for it: it fails within
    // about 2 pt of an up or down move, so scrolling still starts at once.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && !(other is PhonePagerPan)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
