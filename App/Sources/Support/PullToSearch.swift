import SwiftUI
import UIKit

/// Go to by pulling a list past its end (`edge`): the iPhone list's pages up past their
/// bottom (they're drawn bottom up, for a thumb), the iPad's sidebar down past its top;
/// as Things' Quick Find or Telegram's archive. A finger pulls; a fling's bounce at
/// the end shows nothing. Its stages, by how far the list is pulled past its end
/// (`distance`):
/// - a circle with the magnifier grows in the gap past the end row, as big as
///   the gap lets it, in the gap's middle, fading in;
/// - whole, it stretches into the search field's capsule, "Pull to search" in it;
/// - at `threshold` it arms: a medium haptic, the accent fills it out of the
///   magnifier (which bounces, the capsule a little too), "Release to search";
///   pulled back under the threshold (less `hysteresis`) it disarms: a light haptic,
///   and it empties again;
/// - let go armed, Go to opens (`phaseChanged` says so); the field stays whole and
///   fades as the list settles. Let go before, it goes back the way it came.
///
/// Only `PullToSearchField` reads it: a step of the finger redraws the field, not the list.
@MainActor @Observable
final class PullToSearch {
    /// How far the list is pulled past its end, while a finger pulls it (and as it settles after); else 0.
    private(set) var distance: CGFloat = 0
    /// Past the threshold, the finger still on: letting go opens Go to.
    private(set) var armed = false
    /// How many times it armed (the bounce's trigger).
    private(set) var arms = 0
    /// Let go armed: Go to opens, the field fades.
    private(set) var committed = false

    @ObservationIgnored let threshold: CGFloat
    /// The list's end it's pulled past: `.top` (pulled down), `.bottom` (pulled up).
    @ObservationIgnored let edge: VerticalEdge
    /// A finger is on the list (its scroll phase is interacting).
    @ObservationIgnored private var dragging = false
    /// A finger took the list past its end; until it's back at its end.
    @ObservationIgnored private var pulling = false
    @ObservationIgnored private let armFeedback = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private let disarmFeedback = UIImpactFeedbackGenerator(style: .light)

    /// Pulled back this much under the threshold, it disarms (no flicker at the line).
    static let hysteresis: CGFloat = 8

    init(threshold: CGFloat, edge: VerticalEdge = .top) {
        self.threshold = threshold
        self.edge = edge
    }

    /// How far a scroll view is pulled past its top (0 at rest or scrolled down).
    nonisolated static func overscroll(_ g: ScrollGeometry) -> CGFloat {
        max(0, -(g.contentOffset.y + g.contentInsets.top))
    }

    /// How far a scroll view is pulled past its bottom (0 at rest or scrolled up), given
    /// its height under its insets (`viewport`) and its top inset, measured by the list: the
    /// geometry's `containerSize` already goes without the insets (seen on iOS 18.4).
    nonisolated static func overscrollBottom(_ g: ScrollGeometry, viewport: CGFloat, top: CGFloat) -> CGFloat {
        let end = max(-top, g.contentSize.height - viewport - top)
        return max(0, g.contentOffset.y - end)
    }

    /// The list moved: `d` is `overscroll` of its geometry.
    func scrolled(_ d: CGFloat) {
        guard d > 0.5 else { reset(); return }
        if dragging, !pulling {
            pulling = true
            armFeedback.prepare()
        }
        guard pulling else { return }
        distance = d
        guard dragging, !committed else { return }
        if !armed, d >= threshold {
            armed = true
            arms += 1
            armFeedback.impactOccurred()
            disarmFeedback.prepare()
        } else if armed, d < threshold - Self.hysteresis {
            armed = false
            disarmFeedback.impactOccurred(intensity: 0.8)
            armFeedback.prepare()
        }
    }

    /// The list's scroll phase changed; true when Go to should open (let go armed).
    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) -> Bool {
        if new == .interacting {
            dragging = true
            return false
        }
        guard old == .interacting else { return false }
        dragging = false
        guard armed, !committed else { return false }
        committed = true
        return true
    }

    private func reset() {
        pulling = false
        // Only what changed: at rest and scrolling the list, nothing here is written.
        if distance != 0 { distance = 0 }
        if armed { armed = false }
        if committed { committed = false }
    }
}

/// How the pulled field looks: the iPhone's, the search field of Go to in the
/// message field's glass; the sidebar's, a card's surface and border.
struct PullToSearchStyle {
    var height: CGFloat
    /// nil: a capsule.
    var cornerRadius: CGFloat?
    var sideInset: CGFloat
    var iconSize: CGFloat
    /// The icon's leading edge once stretched (a circle has it in its middle).
    var iconLeading: CGFloat
    var spacing: CGFloat
    var fontSize: CGFloat
    var system: Bool
    var glass: Bool
    var threshold: CGFloat

    /// Go to's field: 44 pt, 16 pt from the sides, armed 72 pt past the end (a finger's 150 pt or so).
    static let phone = PullToSearchStyle(height: 44, cornerRadius: nil, sideInset: 16, iconSize: 18, iconLeading: 14,
                                         spacing: 8, fontSize: 17, system: true, glass: true, threshold: 72)
    /// The sidebar's: a card's surface, 30 pt, the cards' 8-pt inset, armed 56 pt past the top.
    static let sidebar = PullToSearchStyle(height: 30, cornerRadius: 8, sideInset: 8, iconSize: 14, iconLeading: 8,
                                           spacing: 7, fontSize: 13, system: false, glass: false, threshold: 56)

    var font: Font { system ? .system(size: fontSize) : .ui(fontSize) }
    var uiFont: UIFont {
        system ? .systemFont(ofSize: fontSize) : AppFont.uiFont(family: AppFont.uiFamily, size: fontSize, weight: UIWeight.regular.rawValue)
    }
}

/// The field a pull brings out (`PullToSearch`), over the list in the gap past its
/// end row (over the first row pulled down, under the last pulled up): an overlay on
/// the list, the list's size; it takes no touches.
struct PullToSearchField: View {
    var pull: PullToSearch
    var style: PullToSearchStyle
    /// Where the list's content ends at rest, from this view's edge at the pull's end
    /// (its inset there).
    var inset: CGFloat
    /// The content's own room past its end row (its margin there): part of the gap.
    var lead: CGFloat = 0

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room between the field and the gap's ends while it grows.
    private static let margin: CGFloat = 3

    var body: some View {
        let d = pull.distance
        GeometryReader { geo in
            if d > 0 {
                let gap = lead + d
                let h = style.height
                let full = max(h, geo.size.width - 2 * style.sideInset)
                // As big as the gap lets it (a circle), then stretched to the field's width.
                let grow = pull.committed ? 1 : Self.clamp((gap - 2 * Self.margin) / h)
                // It starts stretching three quarters grown: one motion, not two.
                let stretchStart = 0.75 * h + 2 * Self.margin
                let stretch = pull.committed ? 1 : Self.clamp((gap - stretchStart) / max(1, pull.threshold + lead - stretchStart))
                let width = h + (full - h) * Self.easeOut(stretch)
                if grow > 0.12 {
                    let y = pull.edge == .top ? inset + gap / 2 : geo.size.height - inset - gap / 2
                    capsule(width: width, stretch: stretch, textOpacity: Self.clamp((stretch - 0.45) / 0.45))
                        .scaleEffect(grow)
                        .opacity(pull.committed ? 0 : Self.clamp((d - 4) / 24))
                        .animation(.easeOut(duration: 0.25), value: pull.committed)
                        .position(x: geo.size.width / 2, y: y)
                }
            }
        }
        // Only in the gap: not over the header nor the rows as they come back.
        .mask(alignment: pull.edge == .top ? .top : .bottom) {
            Rectangle()
                .frame(height: max(0, lead + d))
                .padding(pull.edge == .top ? .top : .bottom, inset)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var shape: AnyShape {
        if let r = style.cornerRadius { AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous)) } else { AnyShape(Capsule()) }
    }

    private func capsule(width: CGFloat, stretch: CGFloat, textOpacity: Double) -> some View {
        let armed = pull.armed
        let h = style.height
        // From the circle's middle to its place in the stretched field.
        let leading = (h - style.iconSize) / 2 + (style.iconLeading - (h - style.iconSize) / 2) * stretch
        let iconCenter = leading + style.iconSize / 2
        let ink = armed ? theme.accentForeground : (style.glass ? theme.foreground.opacity(theme.isDark ? 0.48 : 0.40) : theme.muted)
        return ZStack(alignment: .leading) {
            // The accent fills it out of the magnifier (Reduce Motion: fades in).
            Circle()
                .fill(theme.accent)
                .frame(width: 2 * width + h, height: 2 * width + h)
                .scaleEffect(armed || reduceMotion ? 1 : 0.01)
                .opacity(armed ? 1 : 0)
                .position(x: iconCenter, y: h / 2)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.1), value: armed)
            HStack(spacing: style.spacing) {
                Icon("search", size: style.iconSize, color: armed ? theme.accentForeground : theme.muted)
                    .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : pull.arms) { icon, scale in
                        icon.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.28, duration: 0.12, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.4, spring: .bouncy(duration: 0.4, extraBounce: 0.15))
                    }
                ZStack(alignment: .leading) {
                    Text("Pull to search").opacity(armed ? 0 : 1)
                    Text("Release to search").opacity(armed ? 1 : 0)
                }
                .font(style.font)
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .opacity(textOpacity)
            }
            .padding(.leading, leading)
            .animation(.easeOut(duration: 0.2), value: armed)
        }
        .frame(width: width, height: h, alignment: .leading)
        .clipShape(shape)
        .background { surface }
        .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : pull.arms) { field, scale in
            field.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(1.035, duration: 0.1, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy(duration: 0.35))
        }
    }

    @ViewBuilder
    private var surface: some View {
        if style.glass {
            Color.clear.composerGlass(Capsule(), theme: theme, interactive: false)
        } else {
            shape.fill(theme.surface)
                .overlay(shape.stroke(theme.border, lineWidth: 1))
        }
    }

    private static func clamp(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
    private static func easeOut(_ x: CGFloat) -> CGFloat { 1 - (1 - x) * (1 - x) }
}

/// Go to for VoiceOver and Voice Control, now that a pull opens it: an element only
/// they see (it draws nothing and takes no touches), where the search button was.
struct GoToAccessibilityButton: View {
    /// What VoiceOver adds: how a finger opens it there.
    var hint = "Or pull the list down."
    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("Go to")
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { controller.showSwitcher = true }
    }
}
