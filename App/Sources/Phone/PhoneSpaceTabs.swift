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
/// it settles with them. A tap selects a tab (its pages slide), lifting the pill for a
/// moment (iPhone, iOS 26); a tap on the current tab takes its list to the top. A long press
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
    /// The pill's lift and drop.
    static let liftSpring = Animation.spring(duration: 0.25, bounce: 0)
    /// A dragged tab: bigger and see-through (Telegram's).
    static let dragScale: CGFloat = 1.2
    static let dragOpacity: CGFloat = 0.9
    /// How close to the strip's ends a dragged tab scrolls it, and by how much a frame.
    static let autoScrollEdge: CGFloat = 20
    static let autoScrollStep: CGFloat = 3

    @Environment(\.theme) private var theme
    /// The width inside the border.
    @State private var lensWidth: CGFloat = 0
    @State private var position = ScrollPosition(edge: .leading)
    /// Where the strip is scrolled to, or is going (the app's scrolls are animated).
    @State private var scrolledX: CGFloat = 0
    @State private var scrollPhase: ScrollPhase = .idle
    /// The pill is lifted (glass, bigger) for a moment after a tap.
    @State private var lifted = false
    @State private var unlift: Task<Void, Never>?
    /// The strip has been scrolled to the pill once (the first time, at once).
    @State private var placed = false
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

    var body: some View {
        let tabs = shownTabs
        let layout = Self.layout(tabs, width: lensWidth)
        let pill = pillFrame(layout, tabs)
        ZStack(alignment: .topLeading) {
            ComposerGlassGroup {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height)
                    .composerGlass(Capsule(), theme: theme)
            }
            // The lifted pill: glass over the strip's (outside its group, so they don't
            // merge), outside the scrolling tabs' clip, under the titles.
            if let pill {
                Color.clear
                    .frame(width: pill.width, height: Self.itemHeight)
                    .padding(lifted ? -Self.liftInset : 0)
                    .composerGlass(Capsule(), theme: theme, interactive: false)
                    .opacity(lifted ? 1 : 0)
                    .position(x: Self.lensInset + pill.x + pill.width / 2 - scrolledX, y: Self.height / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            lens(tabs, layout, pill: pill)
                .padding(Self.lensInset)
            draggedTab(tabs, layout)
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .gesture(PhoneTabHold(isEnabled: reorder.isActive,
                              canBegin: { spaceTab(atStripX: $0) != nil },
                              began: beginDrag, moved: moveDrag, ended: endDrag, tick: autoScroll))
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Self.lensInset } action: { lensWidth = max(0, $0) }
        .onChange(of: Focus(pill: pill, layout: layout, width: lensWidth, reordering: reorder.isActive)) { old, focus in
            // Reordering moves the tabs, not the strip (but for its auto-scroll).
            guard !focus.reordering else { return }
            guard old.reordering else { return scrollToPill(focus, animated: !paging.isDragging) }
            // Done: once the strip has its badges back (a wider row it can scroll further in).
            Task { @MainActor in scrollToPill(focus, animated: true) }
        }
        .onChange(of: reorder.isActive) { _, active in
            if !active { drag = nil }
        }
        .onAppear { scrollToPill(Focus(pill: pill, layout: layout, width: lensWidth), animated: false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    /// The tabs and the resting pill, scrolling inside the border, clipped to its capsule.
    private func lens(_ tabs: [PhoneSpaceTab], _ layout: Layout, pill: (x: CGFloat, width: CGFloat)?) -> some View {
        // The current tab dragged: its pill goes with it, over the strip.
        let pillDragged = drag != nil && tabs.first { $0.scope == paging.selectedScope }?.space?.id == drag?.id
        return ScrollView(.horizontal) {
            ZStack(alignment: .leading) {
                if let pill {
                    Capsule()
                        .fill(restingFill)
                        .frame(width: pill.width, height: Self.itemHeight)
                        .offset(x: pill.x)
                        .opacity(lifted || pillDragged ? 0 : 1)
                        .accessibilityHidden(true)
                }
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
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDisabled(layout.fits)
        .scrollPosition($position)
        .onScrollPhaseChange { _, phase in scrollPhase = phase }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
            // A finger's scroll (the app's own set `scrolledX` where they go).
            if scrollPhase != .animating { scrolledX = x }
        }
        .frame(height: Self.itemHeight)
        .clipShape(Capsule())
    }

    /// A tab: its title (and badge) centered in its slot; a tap selects it, a long press shows its menu.
    private func item(_ tab: PhoneSpaceTab, index: Int, canReorder: Bool) -> some View {
        let selected = index == paging.selected
        return Menu {
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
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(selected ? "Scrolls to the top" : "")
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
        withAnimation(Self.liftSpring) { lifted = true }
        unlift?.cancel()
        unlift = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(Self.liftSpring) { lifted = false }
        }
    }

    // MARK: Pill

    /// The pill in the tabs' row: the current tab's slot (found by its scope: reordered,
    /// the tabs move before the pages know), or between it and the next one by the
    /// swipe's fraction (no neighbour that way: it stays).
    private func pillFrame(_ layout: Layout, _ tabs: [PhoneSpaceTab]) -> (x: CGFloat, width: CGFloat)? {
        let scopes = paging.scopes
        let scope = scopes.indices.contains(paging.pillIndex) ? scopes[paging.pillIndex] : nil
        let i = tabs.firstIndex { $0.scope == scope } ?? paging.pillIndex
        guard layout.slots.indices.contains(i) else { return nil }
        let current = layout.slots[i]
        // A finger moving left (negative) brings the next tab.
        let f = -paging.pillFraction
        let j = f > 0 ? i + 1 : i - 1
        guard f != 0, layout.slots.indices.contains(j) else { return current }
        let next = layout.slots[j]
        let a = min(abs(f), 1)
        return (current.x * (1 - a) + next.x * a, current.width * (1 - a) + next.width * a)
    }

    /// What the strip's scroll follows.
    private struct Focus: Equatable {
        var minX: CGFloat = 0
        var maxX: CGFloat = 0
        var content: CGFloat = 0
        var width: CGFloat = 0
        var reordering = false

        init(pill: (x: CGFloat, width: CGFloat)?, layout: Layout, width: CGFloat, reordering: Bool = false) {
            if let pill { minX = pill.x; maxX = pill.x + pill.width }
            content = layout.contentWidth
            self.width = width
            self.reordering = reordering
        }
    }

    /// Scrolls the strip to keep the pill 100 pt in from its ends: with the pages
    /// while a finger moves them, else in the pill's 0.45 s.
    private func scrollToPill(_ focus: Focus, animated: Bool) {
        guard focus.width > 0 else { return }
        var x = scrolledX
        if focus.content <= focus.width {
            x = 0
        } else {
            if focus.maxX > x + focus.width - Self.lookahead { x = focus.maxX - focus.width + Self.lookahead }
            if focus.minX < x + Self.lookahead { x = focus.minX - Self.lookahead }
            x = min(max(x, 0), focus.content - focus.width)
        }
        let animated = animated && placed
        placed = true
        guard abs(x - scrolledX) > 0.25 else { return }
        if animated {
            withAnimation(PhonePagingMotion.settle) {
                position.scrollTo(x: x)
                scrolledX = x
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                position.scrollTo(x: x)
                scrolledX = x
            }
        }
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
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            position.scrollTo(x: x)
            scrolledX = x
        }
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
