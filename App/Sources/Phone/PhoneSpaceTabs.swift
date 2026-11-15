import SwiftUI
import UIKit
import WierdrModel

/// One tab of the iPhone's list: "All" or a space.
struct PhoneSpaceTab: Identifiable, Equatable {
    var scope: PhoneListScope
    var title: String
    /// How many of its agents have the most urgent status (needs you, then done, then
    /// working; never idle): the badge; 0, none.
    var unread = 0
    /// That status: the badge's color.
    var status: AgentStatus = .done
    /// The space (its long-press menu); nil for "All".
    var space: Space?

    var id: PhoneListScope { scope }

    /// What its place in the strip depends on.
    var layoutKey: String { "\(scope)|\(title)|\(unread)" }
}

/// Telegram's glass folder strip (`HorizontalTabsComponent`) over the iPhone's list:
/// a 40-pt glass capsule, the tabs inside it 3 pt in (34 pt tall, 16 pt either side
/// of the title, system 15 medium, all in the foreground color), the current one
/// shown only by a pill behind it. When the tabs fit, they fill the strip (the
/// narrower ones grow to one width); when they don't, the strip scrolls and keeps the
/// pill 100 pt from its ends.
///
/// The pill follows the pages (`PhoneSpacePaging`): while a finger moves them it
/// slides and stretches between the current tab and the next by the same fraction;
/// it settles with them, the strip scrolling with it (both by Core Animation,
/// `PhoneStripMotion`, in the pages' transaction and along their curve). A tap selects
/// a tab (its pages slide), lifting the pill for a moment (iPhone, iOS 26); a tap on
/// the current tab takes its list to the top. A long press
/// opens the tab's menu without lifting it: the space's (Rename, New Tab, Close
/// Space), on "All" New Space; with two spaces or more, Reorder Tabs.
///
/// Reorder mode (`PhoneTabReorder`), Telegram's: the space tabs jiggle, without
/// badges, and taps and menus wait; "All" stays put. A tab held 0.2 s (moving 4 pt
/// before that scrolls the strip instead) lifts, 1.2 times bigger and 0.9 opaque, and
/// follows the finger along its machine's tabs; past a neighbour's middle they swap
/// (a tick; the others move over in 0.25 s); within 20 pt of the strip's ends it
/// scrolls the strip 3 pt a frame; let go, it settles into its place in 0.25 s.
/// VoiceOver moves a tab with the actions Move Left and Move Right.
struct PhoneSpaceTabs: View {
    var tabs: [PhoneSpaceTab]
    var paging: PhoneSpacePaging
    var reorder: PhoneTabReorder

    /// The strip's height.
    static let height: CGFloat = 40
    /// The glass border around the tabs (Telegram's lens inset).
    static let lensInset: CGFloat = 3
    static let itemHeight: CGFloat = height - 2 * lensInset
    static let itemPadding: CGFloat = 16
    /// How close the pill may come to the scrolling strip's ends.
    static let lookahead: CGFloat = 100
    /// How much bigger the pill is, every side, while lifted.
    static let liftInset: CGFloat = 6
    static let titleFont = UIFont.systemFont(ofSize: 15, weight: .medium)
    static let badgeFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    static let badgeSpacing: CGFloat = 5
    /// The pill's lift and drop: a spring this long, without bounce.
    static let liftDuration = 0.25
    /// How long the pill stays lifted after a tap.
    static let liftHold = 0.3
    /// A dragged tab: bigger and see-through (Telegram's).
    static let dragScale: CGFloat = 1.2
    static let dragOpacity: CGFloat = 0.9
    /// How close to the strip's ends a dragged tab scrolls it, and by how much a frame.
    static let autoScrollEdge: CGFloat = 20
    static let autoScrollStep: CGFloat = 3

    @Environment(\.theme) private var theme
    /// The width inside the border.
    @State private var lensWidth: CGFloat = 0
    /// The pill (resting and lifted) and the strip's scroll, moved outside SwiftUI.
    @State private var motion = PhoneStripMotion()
    /// Where the strip is scrolled to, as SwiftUI last saw it (reordering works in it; the
    /// auto-scroll sets it as it scrolls).
    @State private var scrolledX: CGFloat = 0
    /// The tab a finger drags in reorder mode.
    @State private var drag: TabDrag?

    /// A tab dragged in reorder mode: its space; its left edge in the lens and the
    /// finger's x when the finger took it, and the finger's x now (the lens's
    /// coordinates); lifted (it grows as it's taken); landing, it glides into its place.
    private struct TabDrag: Equatable {
        var id: String
        var startX: CGFloat
        var fingerStart: CGFloat
        var finger: CGFloat
        var lifted = false
        var landing = false

        /// Where the finger would have its left edge, in the lens.
        var x: CGFloat { startX + finger - fingerStart }
    }

    // The pill moves at every step of a swipe: Core Animation moves it and the strip
    // (`PhoneStripMotion`), and no SwiftUI view follows it (the tabs are menus, costly
    // to redraw).
    var body: some View {
        let tabs = shownTabs
        let layout = Self.layout(tabs, width: lensWidth)
        ZStack(alignment: .topLeading) {
            ComposerGlassGroup {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height)
                    .composerGlass(Capsule(), theme: theme)
            }
            // The lifted pill: glass over the strip's (outside its group, so they don't
            // merge), outside the scrolling tabs' clip, under the titles.
            PhoneStripLift(motion: motion, isDark: theme.isDark)
                .padding(Self.lensInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            lens(tabs, layout)
                .padding(Self.lensInset)
            draggedTab(tabs, layout)
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .gesture(PhoneTabHold(isEnabled: reorder.isActive,
                              canBegin: { spaceTab(atStripX: $0) != nil },
                              began: beginDrag, moved: moveDrag, ended: endDrag, tick: autoScroll))
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Self.lensInset } action: { lensWidth = max(0, $0) }
        .onChange(of: reorder.isActive) { _, active in
            if !active { drag = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    /// The tabs and the resting pill, scrolling inside the border, clipped to its capsule.
    private func lens(_ tabs: [PhoneSpaceTab], _ layout: Layout) -> some View {
        // The current tab dragged: its pill goes with it, over the strip.
        let pillDragged = drag != nil && tabs.first { $0.scope == paging.selectedScope }?.space?.id == drag?.id
        return PhoneStripScrollView(disabled: layout.fits, offset: { x in
            if abs(x - scrolledX) > 0.01 { scrolledX = x }
        }) {
            ZStack(alignment: .leading) {
                PhoneStripRow(motion: motion, paging: paging, scopes: tabs.map(\.scope), layout: layout,
                              width: lensWidth, fill: restingFill, hidden: pillDragged,
                              reordering: reorder.isActive)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                        // Into reorder mode and out: the same title, crossfaded (the badge goes and comes).
                        ZStack {
                            if reorder.isActive {
                                reorderItem(tab, index: i, tabs: tabs)
                                    .transition(.opacity)
                            } else {
                                item(tab, index: i, canReorder: tabs.count > 2)
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: layout.slots.indices.contains(i) ? layout.slots[i].width : 0,
                               height: Self.itemHeight)
                        .transition(.scale(scale: 0.001).combined(with: .opacity))
                    }
                }
            }
            .frame(width: layout.contentWidth, height: Self.itemHeight, alignment: .leading)
            // Tabs coming and going (or a badge): the rest move over, a new one grows in.
            // Reordering: they move over in Telegram's 0.25 s.
            .animation(reorder.isActive ? PhoneTabReorder.motion : PhonePagingMotion.relayout,
                       value: tabs.map(\.layoutKey))
        }
        .frame(height: Self.itemHeight)
        .clipShape(Capsule())
    }

    /// A tab: its title (and badge) centered in its slot; a tap selects it, a long press shows its menu.
    private func item(_ tab: PhoneSpaceTab, index: Int, canReorder: Bool) -> some View {
        Menu {
            if let space = tab.space {
                SpaceMenu(space: space)
                if canReorder { Divider() }
            } else {
                Menu {
                    PhoneNewSpaceItems()
                } label: { Label("New Space", image: "ui.plus") }
            }
            if canReorder {
                Button { reorder.begin() } label: { Label("Reorder Tabs", systemImage: "arrow.left.arrow.right") }
            }
        } label: {
            label(tab)
                .contentShape(Rectangle())
        } primaryAction: {
            tap(index)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.unread > 0 ? "\(tab.unread) \(Format.statusWord(tab.status))" : "")
        .modifier(PhoneTabSelection(paging: paging, index: index))
    }

    /// A tab's title and badge, centered in its slot.
    private func label(_ tab: PhoneSpaceTab) -> some View {
        HStack(spacing: Self.badgeSpacing) {
            Text(tab.title)
                .font(Font(Self.titleFont))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .fixedSize()
            if tab.unread > 0 {
                badge(tab)
            }
        }
        .padding(.leading, Self.itemPadding)
        // After a badge, the tab gives back 2 pt.
        .padding(.trailing, tab.unread > 0 ? Self.itemPadding - 2 : Self.itemPadding)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A tab in reorder mode: no menu and no tap; a space's jiggles (and is hidden while
    /// dragged: it's over the strip), and VoiceOver moves it among its machine's tabs.
    private func reorderItem(_ tab: PhoneSpaceTab, index: Int, tabs: [PhoneSpaceTab]) -> some View {
        let id = tab.space?.id
        let run = id == nil ? nil : Self.machineRun(tabs, index)
        return label(tab)
            .modifier(PhoneJiggle(isOn: id != nil, phase: id.flatMap { reorder.phases[$0] } ?? 0))
            .opacity(id != nil && drag?.id == id ? 0 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(tab.scope == paging.selectedScope ? .isSelected : [])
            .accessibilityActions {
                if let id, let run {
                    if index > run.lowerBound { Button("Move Left") { step(id, by: -1) } }
                    if index < run.upperBound { Button("Move Right") { step(id, by: 1) } }
                }
            }
    }

    /// Telegram's text badge: 12 pt medium on a capsule about 18 pt tall, in its status's color.
    private func badge(_ tab: PhoneSpaceTab) -> some View {
        let size = Self.badgeSize(tab.unread)
        return Text("\(tab.unread)")
            .font(Font(Self.badgeFont))
            .monospacedDigit()
            .foregroundStyle(theme.background)
            .frame(width: size.width, height: size.height)
            .background(theme.color(for: tab.status), in: Capsule())
    }

    /// The resting pill: Telegram's lens darkens what's under it, about 7 % on a light
    /// strip; on a dark one its matrix takes it to ~0.87·L − 0.07, a pill clearly darker
    /// than the glass (black 40 % here; its white 10 % fallback read as a lighter pill).
    private var restingFill: Color {
        theme.isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.07)
    }

    private func tap(_ index: Int) {
        let moves = index != paging.selected || paging.fraction != 0
        paging.select(index)
        // Telegram lifts its lens on the iPhone only, and only with the system's glass (iOS 26):
        // the drawn stand-in, lifted, would only hide the pill.
        guard moves, Device.isPhone, #available(iOS 26.0, *) else { return }
        motion.lift()
    }

    // MARK: Pill

    /// The pill in the tabs' row: tab `i`'s slot (the strip finds it by its scope:
    /// reordered, the tabs move before the pages know), or between it and its neighbour
    /// by the swipe's fraction (a finger moving left, negative, brings the next tab; no
    /// neighbour that way: it stays).
    static func pillFrame(_ layout: Layout, slot i: Int, fraction: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        guard layout.slots.indices.contains(i) else { return nil }
        let current = layout.slots[i]
        let f = -fraction
        let j = f > 0 ? i + 1 : i - 1
        guard f != 0, layout.slots.indices.contains(j) else { return current }
        let next = layout.slots[j]
        let a = min(abs(f), 1)
        return (current.x * (1 - a) + next.x * a, current.width * (1 - a) + next.width * a)
    }

    /// Where the strip scrolls from `x` to keep the pill (`minX...maxX`) 100 pt in from
    /// its ends (Telegram's lookahead); at 0 when the tabs fit.
    static func scrollX(from x: CGFloat, pill: ClosedRange<CGFloat>, content: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, content > width else { return 0 }
        var x = x
        if pill.upperBound > x + width - lookahead { x = pill.upperBound - width + lookahead }
        if pill.lowerBound < x + lookahead { x = pill.lowerBound - lookahead }
        return min(max(x, 0), content - width)
    }

    // MARK: Reordering

    /// The tabs as the strip shows them: in reorder mode, without badges.
    private var shownTabs: [PhoneSpaceTab] {
        guard reorder.isActive else { return tabs }
        return tabs.map { tab in
            var tab = tab
            tab.unread = 0
            return tab
        }
    }

    /// The tabs in reorder mode's order now (`tabs` can be a step behind it between updates).
    private func current() -> [PhoneSpaceTab] {
        let tabs = shownTabs
        var byID: [String: PhoneSpaceTab] = [:]
        for tab in tabs { if let id = tab.space?.id { byID[id] = tab } }
        return tabs.filter { $0.space == nil } + reorder.arranged(tabs.compactMap(\.space)).compactMap { byID[$0.id] }
    }

    /// The tabs of tab `i`'s machine around it, the run it moves along (a space moves
    /// only among its machine's; the workspace keeps each machine's together).
    static func machineRun(_ tabs: [PhoneSpaceTab], _ i: Int) -> ClosedRange<Int> {
        let machine = tabs[i].space?.machine
        var lo = i, hi = i
        while lo > 0, let s = tabs[lo - 1].space, s.machine == machine { lo -= 1 }
        while hi < tabs.count - 1, let s = tabs[hi + 1].space, s.machine == machine { hi += 1 }
        return lo...hi
    }

    /// The space tab at `x` in the strip, in reorder mode.
    private func spaceTab(atStripX x: CGFloat) -> Int? {
        guard reorder.isActive else { return nil }
        let tabs = current()
        let layout = Self.layout(tabs, width: lensWidth)
        let rowX = x - Self.lensInset + scrolledX
        guard let i = layout.slots.firstIndex(where: { rowX >= $0.x && rowX < $0.x + $0.width }),
              tabs.indices.contains(i), tabs[i].space != nil else { return nil }
        return i
    }

    /// The dragged tab's left edge in the tabs' row: under the finger, but not past its
    /// machine's first and last tabs.
    private func dragRowX(_ drag: TabDrag, _ layout: Layout, _ i: Int, _ run: ClosedRange<Int>) -> CGFloat {
        let lo = layout.slots[run.lowerBound].x
        let hi = layout.slots[run.upperBound].x + layout.slots[run.upperBound].width - layout.slots[i].width
        return min(max(drag.x + scrolledX, lo), hi)
    }

    /// The finger held a space tab: it lifts (a thud) and follows the finger.
    private func beginDrag(atStripX x: CGFloat) {
        let tabs = current()
        let layout = Self.layout(tabs, width: lensWidth)
        guard let i = spaceTab(atStripX: x), let id = tabs[i].space?.id else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let finger = x - Self.lensInset
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            drag = TabDrag(id: id, startX: layout.slots[i].x - scrolledX, fingerStart: finger, finger: finger)
        }
        // Over the strip in its place first, then it grows.
        Task { @MainActor in
            guard drag?.id == id else { return }
            withAnimation(PhoneTabReorder.motion) { drag?.lifted = true }
        }
    }

    private func moveDrag(toStripX x: CGFloat) {
        guard drag?.landing == false else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { drag?.finger = x - Self.lensInset }
        dragMoved()
    }

    /// The finger let go: the tab settles into its place in 0.25 s.
    private func endDrag() {
        guard let d = drag, !d.landing else { return }
        withAnimation(PhoneTabReorder.motion, completionCriteria: .logicallyComplete) {
            drag?.landing = true
        } completion: {
            if drag?.id == d.id, drag?.landing == true { drag = nil }
        }
    }

    /// The dragged tab moved (or the strip under it): its middle where the finger has
    /// it (held at its machine's ends, it's still drawn there) past a neighbour's, they
    /// swap, a tick, and the others move over in 0.25 s.
    private func dragMoved() {
        guard let drag, !drag.landing else { return }
        var tabs = current()
        guard var i = tabs.firstIndex(where: { $0.space?.id == drag.id }) else { return }
        let run = Self.machineRun(tabs, i)
        var swapped = false
        for _ in tabs.indices {
            let layout = Self.layout(tabs, width: lensWidth)
            guard layout.slots.count == tabs.count else { return }
            let mid = drag.x + scrolledX + layout.slots[i].width / 2
            func middle(_ j: Int) -> CGFloat { layout.slots[j].x + layout.slots[j].width / 2 }
            if i < run.upperBound, mid > middle(i + 1) {
                tabs.swapAt(i, i + 1)
                i += 1
            } else if i > run.lowerBound, mid < middle(i - 1) {
                tabs.swapAt(i, i - 1)
                i -= 1
            } else {
                break
            }
            swapped = true
        }
        guard swapped else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(PhoneTabReorder.motion) { reorder.reorder(tabs.compactMap { $0.space?.id }) }
    }

    /// Every frame of a drag: the finger within 20 pt of the strip's ends scrolls it
    /// 3 pt that way, while there are more of its machine's tabs that way to show.
    private func autoScroll() {
        guard let drag, drag.lifted, !drag.landing, lensWidth > 0 else { return }
        let tabs = current()
        let layout = Self.layout(tabs, width: lensWidth)
        guard !layout.fits, layout.slots.count == tabs.count,
              let i = tabs.firstIndex(where: { $0.space?.id == drag.id }) else { return }
        let finger = drag.finger + Self.lensInset
        let width = lensWidth + 2 * Self.lensInset
        let step = finger <= Self.autoScrollEdge ? -Self.autoScrollStep
            : finger >= width - Self.autoScrollEdge ? Self.autoScrollStep : 0
        guard step != 0 else { return }
        // Only toward more of its machine's tabs (its run's end out of sight that way;
        // "All" alone before them, the strip's start).
        let run = Self.machineRun(tabs, i)
        let start = run.lowerBound <= 1 ? 0 : layout.slots[run.lowerBound].x
        let end = layout.slots[run.upperBound].x + layout.slots[run.upperBound].width
        if step < 0 ? start >= scrolledX : end <= scrolledX + lensWidth { return }
        let x = min(max(scrolledX + step, 0), layout.contentWidth - lensWidth)
        guard abs(x - scrolledX) > 0.01 else { return }
        motion.scroll(to: x)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { scrolledX = x }
        dragMoved()
    }

    /// VoiceOver's Move Left / Move Right: the tab swaps with its neighbour that way.
    private func step(_ id: String, by delta: Int) {
        var tabs = current()
        guard let i = tabs.firstIndex(where: { $0.space?.id == id }) else { return }
        let j = i + delta
        guard Self.machineRun(tabs, i).contains(j) else { return }
        tabs.swapAt(i, j)
        withAnimation(PhoneTabReorder.motion) { reorder.reorder(tabs.compactMap { $0.space?.id }) }
    }

    /// The dragged tab, over the tabs (out of the scrolling lens, in the strip's
    /// capsule) where the finger has it, with the pill when it's the current tab;
    /// landing, in its place.
    @ViewBuilder
    private func draggedTab(_ tabs: [PhoneSpaceTab], _ layout: Layout) -> some View {
        if let drag, let i = tabs.firstIndex(where: { $0.space?.id == drag.id }), layout.slots.indices.contains(i) {
            let slot = layout.slots[i]
            let x = drag.landing ? slot.x : dragRowX(drag, layout, i, Self.machineRun(tabs, i))
            let up = drag.lifted && !drag.landing
            ZStack {
                if tabs[i].scope == paging.selectedScope {
                    Capsule()
                        .fill(restingFill)
                        .frame(width: slot.width, height: Self.itemHeight)
                }
                label(tabs[i])
                    .scaleEffect(up ? Self.dragScale : 1)
                    .opacity(up ? Self.dragOpacity : 1)
            }
            .frame(width: slot.width, height: Self.itemHeight)
            .modifier(PhoneJiggle(isOn: true, phase: reorder.phases[drag.id] ?? 0))
            .position(x: Self.lensInset + x - scrolledX + slot.width / 2, y: Self.height / 2)
            // In the strip, as the other tabs: past its ends it goes out of sight.
            .frame(height: Self.height)
            .clipShape(Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Layout

    /// The tabs' slots in the row (x from the row's start), the row's width, and whether they fit the strip.
    struct Layout {
        var slots: [(x: CGFloat, width: CGFloat)]
        var contentWidth: CGFloat
        var fits: Bool
    }

    static func layout(_ tabs: [PhoneSpaceTab], width: CGFloat) -> Layout {
        let widths = tabs.map(itemWidth)
        if let fill = fillSlotWidths(widths, available: width, allowance: 2 * lensInset) {
            var x: CGFloat = 0
            let slots = fill.map { w -> (x: CGFloat, width: CGFloat) in
                defer { x += w }
                return (x, w)
            }
            return Layout(slots: slots, contentWidth: max(width, 0), fits: true)
        }
        var x: CGFloat = 0
        let slots = widths.map { w -> (x: CGFloat, width: CGFloat) in
            defer { x += w }
            return (x, w)
        }
        return Layout(slots: slots, contentWidth: x, fits: false)
    }

    /// A tab's own width: 16 + title + 16, and a badge 5 pt after the title, less 2.
    static func itemWidth(_ tab: PhoneSpaceTab) -> CGFloat {
        let title = (tab.title as NSString).size(withAttributes: [.font: titleFont]).width.rounded(.up)
        var width = itemPadding + title + itemPadding
        if tab.unread > 0 { width += badgeSpacing + badgeSize(tab.unread).width - 2 }
        return width
    }

    /// Telegram's text badge: the number with 1/5/2/5 pt around it, at least as wide as tall.
    static func badgeSize(_ n: Int) -> CGSize {
        let text = ("\(n)" as NSString).size(withAttributes: [.font: badgeFont])
        let height = badgeFont.lineHeight.rounded(.up) + 3
        return CGSize(width: max(text.width.rounded(.up) + 10, height), height: height)
    }

    /// Telegram's `.fill` layout: when the tabs fit (up to `allowance` over, every tab
    /// giving up the same part of its padding), the widest keep their width and the rest
    /// grow to one common width filling the row; slot edges rounded as they add up.
    /// Nil when they don't fit: the row scrolls, every tab at its own width.
    static func fillSlotWidths(_ widths: [CGFloat], available: CGFloat, allowance: CGFloat) -> [CGFloat]? {
        guard !widths.isEmpty, available > 0 else { return widths.isEmpty ? [] : nil }
        let total = widths.reduce(0, +)
        guard total <= available + allowance else { return nil }
        let exact: [CGFloat]
        if total > available {
            let cut = (total - available) / CGFloat(widths.count)
            exact = widths.map { $0 - cut }
        } else {
            var left = available
            var count = widths.count
            var common = available
            for w in widths.sorted(by: >) {
                common = left / CGFloat(count)
                if w <= common { break }
                left -= w
                count -= 1
            }
            exact = widths.map { max($0, common) }
        }
        var slots: [CGFloat] = []
        var exactEdge: CGFloat = 0
        var edge: CGFloat = 0
        for (i, w) in exact.enumerated() {
            exactEdge += w
            let next = i == exact.count - 1 ? available : exactEdge.rounded()
            slots.append(next - edge)
            edge = next
        }
        return slots
    }
}

/// The strip's scroll view. The app scrolls it through the UIKit scroll view under it
/// (`PhoneStripMotion`); `offset` reports where it is.
private struct PhoneStripScrollView<Content: View>: View {
    var disabled: Bool
    var offset: (CGFloat) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) { content }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDisabled(disabled)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset(x) }
    }
}

/// A tab's selected trait and hint for VoiceOver: its own modifier, so a new tab
/// redraws only these, not the strip's menus.
private struct PhoneTabSelection: ViewModifier {
    var paging: PhoneSpacePaging
    var index: Int

    func body(content: Content) -> some View {
        let selected = index == paging.selected
        content
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(selected ? "Scrolls to the top" : "")
    }
}

// MARK: - The pill

/// The resting pill's place: a UIKit view in the tabs' row, under the titles, where
/// `PhoneStripMotion` draws the pill and moves it, and the strip's scroll with it.
private struct PhoneStripRow: UIViewRepresentable {
    var motion: PhoneStripMotion
    var paging: PhoneSpacePaging
    /// The tabs' scopes, in the strip's order.
    var scopes: [PhoneListScope]
    var layout: PhoneSpaceTabs.Layout
    /// The lens's width (the scroll view's).
    var width: CGFloat
    var fill: Color
    /// The current tab is dragged in reorder mode: its pill goes with it, over the strip.
    var hidden: Bool
    var reordering: Bool

    func makeUIView(context: Context) -> UIView {
        let row = motion.row
        motion.attach(to: paging)
        return row
    }

    func updateUIView(_ view: UIView, context: Context) {
        let t = context.transaction
        motion.update(scopes: scopes, layout: layout, width: width, fill: UIColor(fill), hidden: hidden,
                      reordering: reordering, animation: t.disablesAnimations ? nil : t.animation)
    }
}

/// The lifted pill's place: over the strip, as big as the lens and not clipped by it,
/// under the titles; `PhoneStripMotion` scrolls it with the strip.
private struct PhoneStripLift: UIViewRepresentable {
    var motion: PhoneStripMotion
    var isDark: Bool

    func makeUIView(context: Context) -> UIView { motion.liftView }

    func updateUIView(_ view: UIView, context: Context) { motion.setDark(isDark) }
}

/// The strip's pill and scroll on Core Animation, as the pages (`PhonePagerController`):
/// a finger's step sets them at once, and the settling moves are animations the render
/// server plays, added in the pages' transaction along their curve, so the pill and the
/// strip move with the pages whatever the main thread is doing. The only pill there is:
/// the resting one in the tabs' row (`PhoneStripRow`), and after a tap the lifted glass
/// one over the strip (`PhoneStripLift`), outside the lens's clip, moved with it.
///
/// Every move is an additive animation (`PhoneTrack`): where the pill and the strip are
/// drawn is solved here, a frame ahead (`PhoneMotion.shownTime`), so a move taken over
/// goes on from there; the tabs' new places (a badge, reordering) retarget a move under
/// way, keeping its pace.
///
/// The strip's scroll is the UIKit scroll view SwiftUI's `ScrollView` draws with, the one
/// around the row (its offset and bounds are moved here; nothing in the strip may depend
/// on SwiftUI seeing the offset mid-move). The strip follows the pill while the pages move
/// it; a finger on the strip stops a move where it's drawn and the strip stays where the
/// finger leaves it until the pages move again. While the tabs are reordered the strip
/// doesn't follow the pill (only the auto-scroll moves it).
@MainActor
final class PhoneStripMotion: NSObject, PhoneStripSurface {
    // The views are made when first shown: the strip's state makes a motion at every
    // update of its body, and keeps only the first.
    /// The tabs' row: the resting pill's place.
    private(set) lazy var row: Row = {
        let row = Row()
        row.motion = self
        row.backgroundColor = .clear
        row.isUserInteractionEnabled = false
        row.addSubview(pill)
        return row
    }()
    /// Over the strip: the lifted pill's place.
    private(set) lazy var liftView = LiftView()
    private lazy var pill: UIView = {
        let pill = UIView()
        pill.layer.cornerRadius = PhoneSpaceTabs.itemHeight / 2
        pill.isUserInteractionEnabled = false
        return pill
    }()
    /// The lifted pill: the system's glass (iPhone, iOS 26); none before.
    private lazy var glass: UIVisualEffectView? = {
        guard Device.isPhone, #available(iOS 26.0, *) else { return nil }
        let glass = UIVisualEffectView(effect: Self.glassEffect(dark: isDark))
        glass.cornerConfiguration = .capsule()
        glass.isUserInteractionEnabled = false
        glass.alpha = 0
        liftView.space.addSubview(glass)
        return glass
    }()
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []

    private var pillState = PhoneStripPill(scope: .all, fraction: 0)
    private var scopes: [PhoneListScope] = []
    private var layout = PhoneSpaceTabs.Layout(slots: [], contentWidth: 0, fits: true)
    private var width: CGFloat = 0
    private var reordering = false
    /// The resting pill is hidden (the current tab dragged).
    private var hidden = false
    private var lifted = false
    private var unlift: DispatchWorkItem?
    private var isDark = true
    /// The pill has been placed once (the first time, at once).
    private var placed = false
    /// The strip keeps the pill in sight: the pages moved it last, not a finger on the strip.
    private var following = true
    /// Where the strip is to scroll once its row is wide enough: a row that grows (a
    /// badge, reordering done) is laid out after the pill has moved, and the scroll view
    /// keeps its offset within the row it has.
    private var pendingX: CGFloat?
    private var placing = false

    /// The pill's left edge and width in the row, and the strip's offset.
    private var pillX = PhoneTrack(0)
    private var pillWidth = PhoneTrack(0)
    private var offset = PhoneTrack(0)

    private static let key = "strip."
    private static let liftKey = "lift."
    private var serial = 0

    func attach(to paging: PhoneSpacePaging) {
        // The lifted pill moves with the resting one from the start.
        _ = glass
        paging.strip = self
    }

    /// The representable's inputs: the tabs' new places move the pill (and the strip,
    /// while it follows the pill and no finger is on it) along SwiftUI's animation of
    /// them, or on with a move under way.
    func update(scopes: [PhoneListScope], layout: PhoneSpaceTabs.Layout, width: CGFloat, fill: UIColor,
                hidden: Bool, reordering: Bool, animation: Animation?) {
        if pill.backgroundColor != fill { pill.backgroundColor = fill }
        let timing = animation.map(Self.timing)
        if hidden != self.hidden {
            self.hidden = hidden
            fadePill(timing.map { .curve($0.duration, $0.curve) } ?? .now)
        }
        let reorderEnded = self.reordering && !reordering
        let changed = scopes != self.scopes || width != self.width || !Self.same(layout, self.layout)
        self.scopes = scopes
        self.layout = layout
        self.width = width
        self.reordering = reordering
        // Done reordering: the strip goes back to the pill (it stayed put meanwhile).
        if reorderEnded { following = true }
        guard changed || reorderEnded || !placed else { return }
        guard placed else { return place(.jump, scroll: true) }
        let scroll = following && !reordering && scrollView.map { !$0.isTracking && !$0.isDecelerating } ?? false
        let now = CACurrentMediaTime()
        if let timing {
            place(.retarget(timing.duration, timing.curve), scroll: scroll)
        } else if let end = [pillX, pillWidth, offset].compactMap({ $0.end(after: now) }).max() {
            place(.retarget(end - now, PhoneMotion.telegram), scroll: scroll)
        } else {
            place(.jump, scroll: scroll)
        }
    }

    func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        if #available(iOS 26.0, *), let glass { glass.effect = Self.glassEffect(dark: dark) }
    }

    // MARK: PhoneStripSurface

    func follow(_ pill: PhoneStripPill, _ move: PhoneStripMove) {
        pillState = pill
        following = true
        switch move {
        case .jump: place(.jump, scroll: !reordering, fromPages: true)
        case .track: place(.track, scroll: !reordering, fromPages: true)
        case .settle(let duration):
            place(.fresh(duration, PhoneMotion.telegram), scroll: !reordering, fromPages: true)
        }
    }

    /// The reorder's auto-scroll: the strip at x, at once.
    func scroll(to x: CGFloat) {
        guard let scrollView else { return }
        stopScroll(scrollView)
        offset.set(x)
        setOffset(scrollView, x, stopFling: false)
    }

    /// A tap took the pill to a tab: it lifts (glass, bigger) for a moment, and drops.
    func lift() {
        guard glass != nil else { return }
        setLifted(true)
        unlift?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setLifted(false) }
        unlift = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PhoneSpaceTabs.liftHold, execute: work)
    }

    // MARK: Moving

    private enum Move {
        /// At once.
        case jump
        /// A finger's step: at once, the strip no faster than the pill moves (taken
        /// mid-settle, the strip isn't yet where the pill wants it, and doesn't jump there).
        case track
        /// From where they're drawn, along a new curve (as the pages).
        case fresh(Double, PhoneCurve)
        /// The moves under way going on, toward the new place.
        case retarget(Double, PhoneCurve)
    }

    /// The pill where `pillState` has it in the tabs' row, and the strip (when `scroll`)
    /// scrolled to keep it 100 pt in from its ends. From the pages (`fromPages`), a fling
    /// of the strip stops.
    private func place(_ move: Move, scroll follows: Bool, fromPages: Bool = false) {
        guard width > 0, let i = scopes.firstIndex(of: pillState.scope),
              let slot = PhoneSpaceTabs.pillFrame(layout, slot: i, fraction: pillState.fraction) else { return }
        let now = CACurrentMediaTime()
        let shown = PhoneMotion.shownTime(row)
        let scroll = follows ? scrollView : nil
        let drawnX = pillX.value(at: shown), drawnWidth = pillWidth.value(at: shown)
        let drawnOffset = offset.value(at: shown)
        var x: CGFloat?
        if let scroll {
            let content = max(0, layout.contentWidth - width)
            var to = PhoneSpaceTabs.scrollX(from: drawnOffset, pill: slot.x...(slot.x + slot.width),
                                            content: layout.contentWidth, width: width)
            if case .track = move {
                let step = max(abs(slot.x - drawnX), abs(slot.x + slot.width - drawnX - drawnWidth))
                to = min(max(to, drawnOffset - step), drawnOffset + step)
            }
            // Within the row (not where a bounce has it).
            to = min(max(to, 0), content)
            let reach = Self.maxOffset(scroll)
            pendingX = to > reach + 0.5 ? to : nil
            x = min(to, reach)
        }
        placed = true
        placing = true
        CATransaction.begin()
        switch move {
        case .jump, .track:
            stopPill()
            pillX.set(slot.x)
            pillWidth.set(slot.width)
            if let scroll, let x {
                stopScroll(scroll)
                offset.set(x)
                setOffset(scroll, x, stopFling: fromPages)
            }
        case .fresh(let duration, let curve):
            stopPill()
            pillX.set(drawnX)
            pillWidth.set(drawnWidth)
            movePill(to: slot, at: now, duration: duration, curve: curve)
            if let scroll, let x {
                stopScroll(scroll)
                offset.set(drawnOffset)
                moveScroll(scroll, to: x, at: now, duration: duration, curve: curve, stopFling: fromPages)
            }
        case .retarget(let duration, let curve):
            movePill(to: slot, at: now, duration: duration, curve: curve)
            if let scroll, let x {
                moveScroll(scroll, to: x, at: now, duration: duration, curve: curve, stopFling: fromPages)
            }
        }
        frames()
        CATransaction.commit()
        placing = false
        contentSized()
    }

    /// The pill to `slot` along `curve`: an additive move on the resting pill and the lifted one.
    private func movePill(to slot: (x: CGFloat, width: CGFloat), at now: CFTimeInterval,
                          duration: Double, curve: PhoneCurve) {
        let dx = pillX.move(to: slot.x, at: now, duration: duration, curve: curve)
        let dw = pillWidth.move(to: slot.width, at: now, duration: duration, curve: curve)
        guard abs(dx) > 0.01 || abs(dw) > 0.01 else { return }
        for layer in [pill.layer, glass?.layer].compactMap({ $0 }) {
            additive(layer, "position", NSValue(cgPoint: CGPoint(x: dx + dw / 2, y: 0)),
                     NSValue(cgPoint: .zero), duration, curve)
            additive(layer, "bounds.size", NSValue(cgSize: CGSize(width: dw, height: 0)),
                     NSValue(cgSize: .zero), duration, curve)
        }
    }

    /// The strip to `x` along `curve`, and the lifted pill's place with it.
    private func moveScroll(_ scroll: UIScrollView, to x: CGFloat, at now: CFTimeInterval,
                            duration: Double, curve: PhoneCurve, stopFling: Bool) {
        let dx = offset.move(to: x, at: now, duration: duration, curve: curve)
        setOffset(scroll, x, stopFling: stopFling)
        guard abs(dx) > 0.01 else { return }
        for layer in [scroll.layer, liftView.space.layer] {
            additive(layer, "bounds.origin", NSValue(cgPoint: CGPoint(x: dx, y: 0)),
                     NSValue(cgPoint: .zero), duration, curve)
        }
    }

    /// The pills' frames where they're going (their moves are additive on top).
    private func frames() {
        let frame = CGRect(x: pillX.model, y: 0, width: pillWidth.model, height: PhoneSpaceTabs.itemHeight)
        let lift = lifted ? -PhoneSpaceTabs.liftInset : 0
        UIView.performWithoutAnimation {
            pill.frame = frame
            glass?.frame = frame.insetBy(dx: lift, dy: lift)
        }
    }

    private func setOffset(_ scroll: UIScrollView, _ x: CGFloat, stopFling: Bool) {
        if scroll.contentOffset.x != x || stopFling && scroll.isDecelerating {
            scroll.setContentOffset(CGPoint(x: x, y: scroll.contentOffset.y), animated: false)
        }
        if liftView.space.bounds.origin.x != x {
            UIView.performWithoutAnimation { liftView.space.bounds.origin.x = x }
        }
    }

    /// The row grew: the scroll that waited for it, the strip's move under way going on
    /// (or a whole settle).
    private func contentSized() {
        guard !placing, following, let want = pendingX, let scroll = scrollView else { return }
        let reach = Self.maxOffset(scroll)
        let x = min(want, reach)
        if x >= want - 0.5 { pendingX = nil }
        guard abs(x - offset.model) > 0.25 else { return }
        let now = CACurrentMediaTime()
        let end = [pillX, pillWidth, offset].compactMap { $0.end(after: now) }.max()
        let duration = end.map { max($0 - now, 0.2) } ?? PhonePagingMotion.settleDuration
        CATransaction.begin()
        moveScroll(scroll, to: x, at: now, duration: duration, curve: PhoneMotion.telegram, stopFling: false)
        CATransaction.commit()
    }

    /// The strip's offset changed: by us, or by a finger or SwiftUI (keeping it within
    /// its row), and then it's there, at once. The lifted pill's place goes with it.
    private func offsetChanged() {
        guard let scroll = scrollView else { return }
        let x = scroll.contentOffset.x
        if abs(x - offset.model) > 0.5 {
            stopScroll(scroll)
            offset.set(x)
        }
        if liftView.space.bounds.origin.x != x {
            UIView.performWithoutAnimation { liftView.space.bounds.origin.x = x }
        }
    }

    /// A finger came down on the strip: its move stops where it's drawn (the scroll view
    /// takes it from there, not from where it was going), and it stops following the pill.
    private func touched() {
        following = false
        pendingX = nil
        guard let scroll = scrollView, offset.end(after: CACurrentMediaTime()) != nil else { return }
        let x = offset.value(at: CACurrentMediaTime())
        stopScroll(scroll)
        offset.set(x)
        setOffset(scroll, x, stopFling: false)
    }

    // MARK: Lift and fade

    private enum Fade {
        case now
        case curve(Double, PhoneCurve)
        /// The lift's spring.
        case spring
    }

    private func setLifted(_ on: Bool) {
        guard on != lifted, let glass else { return }
        lifted = on
        let grow = 2 * PhoneSpaceTabs.liftInset * (on ? 1 : -1)
        CATransaction.begin()
        frames()
        let spring = Self.spring("bounds.size")
        spring.isAdditive = true
        spring.fromValue = NSValue(cgSize: CGSize(width: -grow, height: -grow))
        spring.toValue = NSValue(cgSize: .zero)
        serial += 1
        glass.layer.add(spring, forKey: Self.liftKey + "\(serial)")
        fade(glass, to: on ? 1 : 0, .spring)
        fadePill(.spring)
        CATransaction.commit()
    }

    /// The resting pill shown or hidden (lifted, or its tab dragged).
    private func fadePill(_ how: Fade) {
        fade(pill, to: hidden || lifted ? 0 : 1, how)
    }

    private func fade(_ view: UIView, to alpha: CGFloat, _ how: Fade) {
        let from = (view.layer.presentation() ?? view.layer).opacity
        view.layer.removeAnimation(forKey: Self.liftKey + "opacity")
        UIView.performWithoutAnimation { view.alpha = alpha }
        let a: CABasicAnimation
        switch how {
        case .now: return
        case .curve(let duration, let curve):
            a = CABasicAnimation(keyPath: "opacity")
            a.duration = duration
            a.timingFunction = curve.function
        case .spring:
            a = Self.spring("opacity")
        }
        a.fromValue = from
        a.toValue = Float(alpha)
        view.layer.add(a, forKey: Self.liftKey + "opacity")
    }

    private static func spring(_ keyPath: String) -> CASpringAnimation {
        let a = CASpringAnimation(perceptualDuration: PhoneSpaceTabs.liftDuration, bounce: 0)
        a.keyPath = keyPath
        a.duration = a.settlingDuration
        a.preferredFrameRateRange = PhoneMotion.frameRate
        return a
    }

    @available(iOS 26.0, *)
    private static func glassEffect(dark: Bool) -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        effect.tintColor = .white.withAlphaComponent(dark ? 0.025 : 0.1)
        return effect
    }

    // MARK: Helpers

    private func additive(_ layer: CALayer, _ keyPath: String, _ from: Any, _ to: Any,
                          _ duration: Double, _ curve: PhoneCurve) {
        let a = CABasicAnimation(keyPath: keyPath)
        a.isAdditive = true
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = curve.function
        a.preferredFrameRateRange = PhoneMotion.frameRate
        serial += 1
        layer.add(a, forKey: Self.key + "\(serial)")
    }

    /// The pills' moves off (not the lift's).
    private func stopPill() {
        for layer in [pill.layer, glass?.layer].compactMap({ $0 }) { Self.remove(layer, Self.key) }
    }

    /// The strip's moves off (ours, and UIKit's on its bounds), and the lifted pill's place's.
    private func stopScroll(_ scroll: UIScrollView) {
        Self.remove(scroll.layer, Self.key, "bounds")
        Self.remove(liftView.space.layer, Self.key)
    }

    private static func remove(_ layer: CALayer, _ prefixes: String...) {
        for key in layer.animationKeys() ?? [] where prefixes.contains(where: key.hasPrefix) {
            layer.removeAnimation(forKey: key)
        }
    }

    private static func maxOffset(_ scroll: UIScrollView) -> CGFloat {
        let inset = scroll.adjustedContentInset
        return max(-inset.left, scroll.contentSize.width + inset.right - scroll.bounds.width)
    }

    /// SwiftUI's animation of the tabs' places, on Core Animation.
    private static func timing(_ animation: Animation) -> (duration: Double, curve: PhoneCurve) {
        if animation == PhonePagingMotion.settle { return (PhonePagingMotion.settleDuration, PhoneMotion.telegram) }
        if animation == PhoneTabReorder.motion { return (PhoneTabReorder.motionDuration, PhoneMotion.easeInOut) }
        return (PhonePagingMotion.relayoutDuration, PhoneMotion.easeInOut)
    }

    private static func same(_ a: PhoneSpaceTabs.Layout, _ b: PhoneSpaceTabs.Layout) -> Bool {
        a.contentWidth == b.contentWidth && a.fits == b.fits && a.slots.count == b.slots.count
            && zip(a.slots, b.slots).allSatisfy { $0.x == $1.x && $0.width == $1.width }
    }

    // MARK: Views

    /// Finds the scroll view around the row, and watches it: its row's size, its offset,
    /// a finger coming down.
    fileprivate func rowMoved() {
        guard row.window != nil else { return }
        var view = row.superview
        while let v = view, !(v is UIScrollView) { view = v.superview }
        let found = view as? UIScrollView
        assert(found != nil, "The strip's row isn't in a scroll view: the strip won't follow the pill")
        guard let found, found !== scrollView else { return }
        scrollView = found
        observations = [
            found.observe(\.contentSize, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.contentSized() }
            },
            found.observe(\.contentOffset, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.offsetChanged() }
            },
        ]
        let touch = TouchDown { [weak self] in self?.touched() }
        found.addGestureRecognizer(touch)
        offset.set(found.contentOffset.x)
        place(.jump, scroll: !reordering)
    }

    /// The tabs' row (SwiftUI lays it out as wide as the row).
    final class Row: UIView {
        fileprivate weak var motion: PhoneStripMotion?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            motion?.rowMoved()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The row grew (its scroll view's content with it, or about to).
            motion?.contentSized()
        }
    }

    /// The lifted pill's place: `space` scrolls with the strip (its bounds' origin is the
    /// strip's offset), not clipped.
    final class LiftView: UIView {
        let space = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            space.frame = bounds
            space.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(space)
        }

        required init?(coder: NSCoder) { fatalError() }
    }

    /// Tells when a finger comes down on the strip, and fails: the strip's own scrolling
    /// and the tabs' taps go on as if it weren't there.
    private final class TouchDown: UIGestureRecognizer {
        private let down: () -> Void

        init(_ down: @escaping () -> Void) {
            self.down = down
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            down()
            state = .failed
        }
    }
}
