import SwiftUI
import UIKit
import WierdrModel

/// One tab of the iPhone's list: "All" or a space.
struct PhoneSpaceTab: Identifiable, Equatable {
    var scope: PhoneListScope
    var title: String
    /// Its agents waiting for you (done or needing you): the badge; 0, none.
    var unread = 0
    /// One of them needs you: the badge is red, else green.
    var urgent = false
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
/// Space), on "All" New Space.
struct PhoneSpaceTabs: View {
    var tabs: [PhoneSpaceTab]
    var paging: PhoneSpacePaging

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

    var body: some View {
        let layout = Self.layout(tabs, width: lensWidth)
        let pill = pillFrame(layout)
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
            lens(layout, pill: pill)
                .padding(Self.lensInset)
        }
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Self.lensInset } action: { lensWidth = max(0, $0) }
        .onChange(of: Focus(pill: pill, layout: layout, width: lensWidth)) { _, focus in
            scrollToPill(focus, animated: !paging.isDragging)
        }
        .onAppear { scrollToPill(Focus(pill: pill, layout: layout, width: lensWidth), animated: false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
    }

    /// The tabs and the resting pill, scrolling inside the border, clipped to its capsule.
    private func lens(_ layout: Layout, pill: (x: CGFloat, width: CGFloat)?) -> some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .leading) {
                if let pill {
                    Capsule()
                        .fill(restingFill)
                        .frame(width: pill.width, height: Self.itemHeight)
                        .offset(x: pill.x)
                        .opacity(lifted ? 0 : 1)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                        item(tab, index: i)
                            .frame(width: layout.slots.indices.contains(i) ? layout.slots[i].width : 0,
                                   height: Self.itemHeight)
                            .transition(.scale(scale: 0.001).combined(with: .opacity))
                    }
                }
            }
            .frame(width: layout.contentWidth, height: Self.itemHeight, alignment: .leading)
            // Tabs coming and going (or a badge): the rest move over, a new one grows in.
            .animation(PhonePagingMotion.relayout, value: tabs.map(\.layoutKey))
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
    private func item(_ tab: PhoneSpaceTab, index: Int) -> some View {
        let selected = index == paging.selected
        return Menu {
            if let space = tab.space {
                SpaceMenu(space: space)
            } else {
                Menu {
                    PhoneNewSpaceItems()
                } label: { Label("New Space", image: "ui.plus") }
            }
        } label: {
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
            .contentShape(Rectangle())
        } primaryAction: {
            tap(index)
        }
        .menuOrder(.fixed)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.unread > 0 ? "\(tab.unread) waiting" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(selected ? "Scrolls to the top" : "")
    }

    /// Telegram's text badge: 12 pt medium on a capsule about 18 pt tall, red while one needs you.
    private func badge(_ tab: PhoneSpaceTab) -> some View {
        let size = Self.badgeSize(tab.unread)
        return Text("\(tab.unread)")
            .font(Font(Self.badgeFont))
            .monospacedDigit()
            .foregroundStyle(theme.background)
            .frame(width: size.width, height: size.height)
            .background(tab.urgent ? theme.blocked : theme.done, in: Capsule())
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

    /// The pill in the tabs' row: the current tab's slot, or between it and the next
    /// one by the swipe's fraction (no neighbour that way: it stays).
    private func pillFrame(_ layout: Layout) -> (x: CGFloat, width: CGFloat)? {
        let i = paging.pillIndex
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

        init(pill: (x: CGFloat, width: CGFloat)?, layout: Layout, width: CGFloat) {
            if let pill { minX = pill.x; maxX = pill.x + pill.width }
            content = layout.contentWidth
            self.width = width
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
