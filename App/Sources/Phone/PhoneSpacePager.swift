import SwiftUI
import UIKit
import WierdrModel

/// Telegram's folder motion (`ChatListContainerNode`, `HorizontalTabsComponent`): its
/// "spring" transition curve, a cubic bezier, for the pages and the strip's pill.
enum PhonePagingMotion {
    /// The pages and the pill settling after a swipe; the pill and the strip after a tap.
    static let settle = Animation.timingCurve(0.38, 0.7, 0.125, 1.0, duration: 0.45)
    static let settleDuration = 0.45
    /// The pages sliding after a tap on a tab.
    static let tapSlide = Animation.timingCurve(0.38, 0.7, 0.125, 1.0, duration: 0.35)
    static let tapSlideDuration = 0.35
    /// Tabs coming and going: the strip lays itself out again.
    static let relayout = Animation.easeInOut(duration: 0.2)

    /// The strips along the screen's sides where a swipe is a row's (its actions), not the pager's.
    static func edgeWidth(_ width: CGFloat) -> CGFloat { min(max(width / 6, 22), 80) }

    /// A swipe past the first or last tab: 0.4 of the finger's way at first, never past 600 pt.
    static func rubberBand(_ x: CGFloat) -> CGFloat { 0.4 * x / (1 + x / 1500) }

    /// How far along the curve the motion is at `t` (0...1 of its duration).
    static func progress(_ t: Double) -> Double {
        let (x1, y1, x2, y2) = (0.38, 0.7, 0.125, 1.0)
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        let t = min(max(t, 0), 1)
        var lo = 0.0, hi = 1.0
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            if bezier(mid, x1, x2) < t { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, y1, y2)
    }
}

/// Which tab of the iPhone's list shows, and how far a swipe or a slide has moved
/// the pages: shared by the strip (`PhoneSpaceTabs`, its pill) and the pages
/// (`PhoneSpacePager`). Telegram's folder paging: the pages and the pill follow the
/// finger, and settle on a tab when it lets go.
@MainActor
@Observable
final class PhoneSpacePaging {
    /// The tabs: "All", then the spaces.
    private(set) var scopes: [PhoneListScope] = [.all]
    /// The page in place, or the one the pages are settling on.
    private(set) var selected = 0
    /// How far the pages are off `selected`, in page widths; a finger moving right is positive.
    private(set) var fraction: CGFloat = 0
    /// The strip's pill: its tab and how far toward the next one (same sign as `fraction`).
    /// After a swipe it moves with the pages; after a tap on its own, slower.
    private(set) var pillIndex = 0
    private(set) var pillFraction: CGFloat = 0
    /// A finger is moving the pages.
    private(set) var isDragging = false
    /// A tap on a tab that isn't next to the current one: the page it left, sliding
    /// out beside the new one (none of the tabs between show).
    private(set) var leaving: Int?
    /// Bumped by a tap on the current tab: its list scrolls to the top.
    private(set) var scrollToTop: [PhoneListScope: Int] = [:]

    /// The pages' last animated move, to know where they are on screen when a finger
    /// takes them mid-way (SwiftUI doesn't tell).
    @ObservationIgnored private var motion: Motion?
    /// Where the pages were when the finger took them, in page widths.
    @ObservationIgnored private var dragStart: CGFloat = 0
    /// Counts the taps' slides, so a finished one doesn't end a later one.
    @ObservationIgnored private var slideID = 0

    private struct Motion {
        var start: CFTimeInterval
        var duration: Double
        /// `position` before and after.
        var from: CGFloat
        var to: CGFloat
    }

    /// The tab at the center of the screen, fractional while moving (page i is at (i − position) widths).
    var position: CGFloat { CGFloat(selected) - fraction }

    var selectedScope: PhoneListScope { scopes[min(selected, scopes.count - 1)] }

    /// One page on screen: the tab it shows and where it sits (its index; for a tab
    /// left by a far tap, the place beside the new one).
    struct Page: Hashable {
        var scope: PhoneListScope
        var index: Int
        var place: Int
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
        pillIndex = selected
        pillFraction = isDragging ? fraction : 0
        leaving = leavingScope.flatMap { scopes.firstIndex(of: $0) }.flatMap { $0 == selected ? nil : $0 }
        if scopes.count < 2 { fraction = 0; pillFraction = 0 }
        motion = nil
    }

    /// A tap on tab `index`: the pages slide to it (0.35 s), the pill moves (0.45 s).
    /// On the current tab: its list goes to the top.
    func select(_ index: Int) {
        guard scopes.indices.contains(index), !isDragging else { return }
        guard index != selected || fraction != 0 else {
            scrollToTop[scopes[index], default: 0] += 1
            return
        }
        withAnimation(PhonePagingMotion.settle) {
            pillIndex = index
            pillFraction = 0
        }
        let from = presentedPosition()
        if abs(index - selected) <= 1 && leaving == nil || index == selected {
            // Next to it: the pages slide side by side.
            withAnimation(PhonePagingMotion.tapSlide) {
                selected = index
                fraction = 0
            }
            motion = Motion(start: CACurrentMediaTime(), duration: PhonePagingMotion.tapSlideDuration,
                            from: from, to: CGFloat(index))
            return
        }
        // Further: the page it leaves goes beside the new one where it is on screen, then both
        // slide (a lower tab comes from the left).
        let old = selected
        let place = index + (index > old ? -1 : 1)
        let oldOffset = CGFloat(old) - from
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            leaving = old
            selected = index
            fraction = CGFloat(index) - (CGFloat(place) - oldOffset)
        }
        slideID += 1
        let id = slideID
        let start = position
        // Next turn: the new page has been placed beside the old one before they move.
        Task { @MainActor [weak self] in
            guard let self, id == self.slideID, !self.isDragging else { return }
            withAnimation(PhonePagingMotion.tapSlide, completionCriteria: .logicallyComplete) {
                self.fraction = 0
            } completion: { [weak self] in
                guard let self, id == self.slideID, !self.isDragging else { return }
                self.leaving = nil
            }
            self.motion = Motion(start: CACurrentMediaTime(), duration: PhonePagingMotion.tapSlideDuration,
                                 from: start, to: CGFloat(index))
        }
    }

    // MARK: Swipe

    /// A finger took the pages: they go on from where they are, even mid-slide.
    func dragBegan() {
        let at = presentedPosition()
        slideID += 1
        motion = nil
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            isDragging = true
            // A far tap's slide ends here: the page beside the new one is its real neighbour again.
            leaving = nil
            fraction = CGFloat(selected) - at
            pillIndex = selected
            pillFraction = fraction
        }
        dragStart = fraction
    }

    /// The finger moved `translation` points (right is positive) on pages `width` wide.
    func dragChanged(translation: CGFloat, width: CGFloat) {
        guard isDragging, width > 0 else { return }
        var x = translation
        // Past the first or last tab the pages resist.
        if selected == 0 && x > 0 { x = PhonePagingMotion.rubberBand(x) }
        if selected == scopes.count - 1 && x < 0 { x = -PhonePagingMotion.rubberBand(-x) }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            fraction = x / width + dragStart
            pillIndex = selected
            pillFraction = fraction
        }
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
        let from = position
        withAnimation(PhonePagingMotion.settle) {
            isDragging = false
            selected = target
            fraction = 0
            pillIndex = target
            pillFraction = 0
        }
        motion = Motion(start: CACurrentMediaTime(), duration: PhonePagingMotion.settleDuration,
                        from: from, to: CGFloat(target))
    }

    /// Where the pages are on screen now: mid-way through their last animated move, else where they rest.
    private func presentedPosition() -> CGFloat {
        guard let m = motion else { return position }
        let t = (CACurrentMediaTime() - m.start) / m.duration
        guard t < 1 else {
            motion = nil
            return position
        }
        return m.from + (m.to - m.from) * CGFloat(PhonePagingMotion.progress(t))
    }
}

/// The iPhone list's pages, one per tab, side by side and as wide as the screen:
/// Telegram's folder paging. Only the current page and its neighbours exist (and
/// during a far tap's slide, the page it left); page i sits (i − selected + fraction)
/// widths from the left, without parallax.
///
/// A horizontal swipe that starts in the middle of the screen (not in the edge zones,
/// which are the rows' swipe actions; not over the header, `topInset`) moves the
/// pages (`PhonePagerPan`); vertical moves are the pages' own scrolling.
struct PhoneSpacePager<Page: View>: View {
    var paging: PhoneSpacePaging
    /// The floating header's height over the pages' top: no swipes start there.
    var topInset: CGFloat
    /// Swipes page (more than one tab, the list on screen).
    var isEnabled: Bool
    /// A tab's page.
    @ViewBuilder var page: (PhoneListScope) -> Page

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(paging.pages, id: \.scope) { p in
                    page(p.scope)
                        // The page's top is the screen's: the header's room is `topInset`, not a safe area.
                        .ignoresSafeArea(.container, edges: .top)
                        .frame(width: width, height: geo.size.height)
                        .offset(x: (CGFloat(p.place) - paging.position) * width)
                        .allowsHitTesting(p.index == paging.selected)
                        .accessibilityHidden(p.index != paging.selected)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            // A neighbour doesn't show beside the pages (in landscape, in the side safe areas).
            .clipped()
        }
        .background {
            PhonePagerGesture(paging: paging, topInset: topInset, isEnabled: isEnabled && paging.scopes.count > 1)
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

/// Puts the pages' pan on the window's root view (it sees the touches on the pages'
/// scroll views, and theirs wait for it), and tells it where the pages are: a
/// zero-content view with the pager's frame.
private struct PhonePagerGesture: UIViewRepresentable {
    var paging: PhoneSpacePaging
    var topInset: CGFloat
    var isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        context.coordinator.anchor = anchor
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        let c = context.coordinator
        c.paging = paging
        c.topInset = topInset
        // Off while a drag runs: it is cancelled, the pages settle back.
        if c.pan.isEnabled != isEnabled { c.pan.isEnabled = isEnabled }
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window?.rootViewController?.view)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let pan = PhonePagerPan()
        weak var anchor: UIView?
        var paging: PhoneSpacePaging?
        var topInset: CGFloat = 0

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
                paging.dragBegan()
                paging.dragChanged(translation: pan.translationX, width: width)
            case .changed:
                paging.dragChanged(translation: pan.translationX, width: width)
            case .ended:
                paging.dragEnded(translation: pan.translationX, velocity: pan.velocity(in: pan.view).x, width: width)
            case .cancelled, .failed:
                paging.dragEnded(translation: pan.translationX, velocity: 0, width: width, cancelled: true)
            default:
                break
            }
        }

        /// Only touches that start on the pages, under the header and outside the edge zones.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let anchor, anchor.window != nil else { return false }
            let p = touch.location(in: anchor)
            let bounds = anchor.bounds
            let edge = PhonePagingMotion.edgeWidth(bounds.width)
            return bounds.contains(p) && p.y >= topInset && p.x >= edge && p.x <= bounds.width - edge
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
}
