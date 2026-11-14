import SwiftUI
import UIKit

/// The line under a row of the iPhone's list: none (inside an agent's block),
/// inset (from the text's leading edge to 16 pt from the right), or full width
/// (under the last pinned row and the last row).
enum PhoneRowSeparator: Hashable {
    case none
    case inset(CGFloat)
    case full
}

/// Telegram's motion for the list's rows.
enum PhoneListMotion {
    /// Pin/unpin moves (Telegram's ListView 0.4 s system spring, critically damped).
    static let move = Animation.interpolatingSpring(mass: 1, stiffness: 867, damping: 58.9)
    /// Restyles: the pinned background, the separators (0.4 s bezier).
    static let restyle = Animation.timingCurve(0.38, 0.7, 0.125, 1.0, duration: 0.4)
    /// The press highlight fading after a tap.
    static let unlight = Animation.easeInOut(duration: 0.4)
}

/// A row of the iPhone's list with Telegram's chat-row chrome around its content:
/// - pinned: `hover` edge to edge over the list (the pinned chats' gray);
/// - the press highlight (`selected`): 0.08 s after the finger comes down, gone
///   when it moves more than 4 pt, held at least 0.5 s after a tap, then fading
///   out in 0.4 s;
/// - swipe actions (`PhoneRowPan`, `PhoneSwipeButtons`): the content slides on a
///   rounded plate of the highlight's color and uncovers round buttons; past the
///   full-swipe point it jumps on (a haptic) and letting go runs the outer one;
/// - its separator, which fades while it or the row under it is lit;
/// - tap (closes an open row instead), long-press menu.
struct PhoneListRow<Content: View, Menu: View>: View {
    var id: String
    var pinned: Bool
    var separator: PhoneRowSeparator
    /// The row under it (its separator hides while that one is lit).
    var nextID: String?
    /// Outermost first (the full swipe's).
    var leading: [PhoneSwipeAction] = []
    var trailing: [PhoneSwipeAction] = []
    var edgeSwipesOnly: Bool
    var tap: () -> Void
    @ViewBuilder var menu: () -> Menu
    @ViewBuilder var content: () -> Content

    @Environment(PhoneRowSwipes.self) private var swipes
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var size: CGSize = .zero
    @State private var reveal = Reveal()
    /// The press highlight is on.
    @State private var pressed = false
    /// Counts presses and taps, so a stale fade doesn't put out a newer one.
    @State private var pressGeneration = 0
    @State private var heldAfterTap = false

    /// The swipe as it goes (Telegram's `ItemListRevealMotion`, in SwiftUI animations).
    struct Reveal {
        var side: PhoneSwipeSide?
        /// How far the content went toward `side` (negative: a little past closed).
        var distance: CGFloat = 0
        var armed = false
        var dragging = false
        /// Where the finger's travel starts from (`distance` before resistance).
        var initial: CGFloat = 0
        /// The early arming near the far edge moves the finger's zero.
        var adjust: CGFloat = 0
        /// Animated moves for the rest of the touch (once armed, or grabbed mid-settle).
        var springing = false
        var settling = false
        /// The plate under the content: its opacity and how round it is.
        var plate: CGFloat = 0
        var round: CGFloat = 0

        var offset: CGFloat { side == .trailing ? -distance : (side == .leading ? distance : 0) }
    }

    private var actions: [PhoneSwipeAction] {
        switch reveal.side {
        case .leading: return leading
        case .trailing: return trailing
        case nil: return []
        }
    }

    private var metrics: PhoneSwipeMetrics {
        PhoneSwipeMetrics(width: size.width, count: actions.count, compact: size.height < 68)
    }

    private var isOpen: Bool { reveal.side != nil && (reveal.distance > 0.5 || reveal.dragging) }

    var body: some View {
        let px = 1 / max(1, displayScale)
        let separatorHidden = pressed || swipes.litID == id || reveal.plate > 0.01
            || (nextID != nil && swipes.litID == nextID)
        content()
            // VoiceOver: the swipe actions as the row's actions.
            .accessibilityActions {
                ForEach(leading + trailing) { action in
                    Button(action.title) { action.run() }
                }
            }
            .accessibilityAddTraits(.isButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { plate }
            .offset(x: reveal.offset)
            .background {
                if let side = reveal.side, !actions.isEmpty {
                    PhoneSwipeButtons(actions: actions, side: side, metrics: metrics, distance: reveal.distance,
                                      expansion: reveal.armed ? 1 : 0, height: size.height) { action in
                        run(action)
                    }
                }
            }
            .background {
                // Opaque: a row moving past others (a pin, an unpin) covers them instead of mixing with them.
                ZStack {
                    theme.chrome
                    theme.hover.opacity(pinned ? 1 : 0)
                        .animation(PhoneListMotion.restyle, value: pinned)
                }
            }
            .overlay(alignment: .bottom) {
                separatorLine(px: px)
                    .opacity(separatorHidden ? 0 : 1)
                    .animation(PhoneListMotion.restyle, value: separator)
            }
            .contentShape(.contextMenuPreview, Rectangle())
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onTapGesture { tapped() }
            .contextMenu { menu() }
            .gesture(PhoneRowPan(
                edgeOnly: edgeSwipesOnly, width: size.width, isOpen: isOpen,
                canBegin: { direction in
                    if isOpen || reveal.settling { return true }
                    return !(direction > 0 ? leading : trailing).isEmpty
                },
                began: { panBegan(direction: $0) },
                changed: { t, v, x in panChanged(translation: t, velocity: v, x: x) },
                ended: { t, v, cancelled in panEnded(translation: t, velocity: v, cancelled: cancelled) }))
            .gesture(PhoneRowPress { press($0) })
            .onChange(of: swipes.openID) { _, open in
                if open != id, reveal.side != nil, !reveal.dragging { settle(open: false) }
            }
            .onChange(of: leading.map(\.id) + trailing.map(\.id)) { _, _ in
                // Its actions changed under it (pinned elsewhere, a new status): close.
                if reveal.side != nil, !reveal.dragging { settle(open: false) }
            }
            .onChange(of: size.width) { _, _ in
                if reveal.side != nil, !reveal.dragging { settle(open: false) }
            }
    }

    // MARK: Drawing

    /// The highlight and, while swiping, the plate the content slides on (Telegram's
    /// surface: the highlight's color, rounding to 26 pt).
    private var plate: some View {
        let radius = min(26, size.height / 2) * reveal.round
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(theme.selected)
            .opacity(max(pressed ? 1 : 0, reveal.plate))
    }

    @ViewBuilder
    private func separatorLine(px: CGFloat) -> some View {
        switch separator {
        case .none:
            EmptyView()
        case .inset(let leading):
            Rectangle().fill(theme.border).frame(height: px)
                .padding(.leading, leading)
                .padding(.trailing, PhoneRowMetrics.inset)
        case .full:
            Rectangle().fill(theme.border).frame(height: px)
        }
    }

    // MARK: Tap and highlight

    private func tapped() {
        if swipes.openID != nil {
            unlight(animated: false)
            withAnimation(PhoneSwipeMotion.bodyAnimation) { swipes.closeAll() }
            return
        }
        // Lit at once on a quick tap, held 0.5 s, then fading (under the pushed pane).
        pressGeneration += 1
        let generation = pressGeneration
        pressed = true
        heldAfterTap = true
        swipes.litID = id
        tap()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard pressGeneration == generation else { return }
            heldAfterTap = false
            unlight(animated: true)
        }
    }

    private func press(_ press: PhonePress) {
        switch press {
        case .down:
            guard swipes.openID == nil, reveal.side == nil else { return }
            pressGeneration += 1
            heldAfterTap = false
            pressed = true
            swipes.litID = id
        case .moved, .cancelled:
            if !heldAfterTap { unlight(animated: false) }
        case .up:
            // A tap holds it (`tapped`); anything else that took the touch (a badge's button) lets go.
            let generation = pressGeneration
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard pressGeneration == generation, !heldAfterTap else { return }
                unlight(animated: true)
            }
        }
    }

    private func unlight(animated: Bool) {
        guard pressed || swipes.litID == id else { return }
        var t = Transaction(animation: animated ? PhoneListMotion.unlight : nil)
        t.disablesAnimations = !animated
        withTransaction(t) {
            pressed = false
            if swipes.litID == id, reveal.plate < 0.01 { swipes.litID = nil }
        }
    }

    // MARK: Swipe

    private func panBegan(direction: CGFloat) {
        pressGeneration += 1
        heldAfterTap = false
        let wasLit = pressed
        unlight(animated: false)
        if !isOpen && !reveal.settling {
            reveal.side = direction > 0 ? .leading : .trailing
            reveal.distance = 0
        }
        reveal.dragging = true
        reveal.springing = reveal.settling
        reveal.armed = false
        reveal.adjust = 0
        reveal.initial = metricsFor(reveal.side).resisted(reveal.distance, inverse: true)
        swipes.openID = id
        if wasLit { reveal.plate = 1 }
        withAnimation(PhoneSwipeMotion.plate) {
            reveal.plate = 1
            reveal.round = 1
            swipes.litID = id
        }
    }

    private func metricsFor(_ side: PhoneSwipeSide?) -> PhoneSwipeMetrics {
        let count = side == .leading ? leading.count : (side == .trailing ? trailing.count : 0)
        return PhoneSwipeMetrics(width: size.width, count: count, compact: size.height < 68)
    }

    private func panChanged(translation: CGFloat, velocity: CGFloat, x: CGFloat) {
        guard reveal.dragging else { return }
        let m = metricsFor(reveal.side)
        let sign: CGFloat = reveal.side == .leading ? 1 : -1
        let t = translation * sign, v = velocity * sign
        var proposed = reveal.initial + t + reveal.adjust
        var armed = m.count > 0 && proposed >= m.confirm
        let fromEdge = reveal.side == .leading ? size.width - x : x
        if m.count > 0, !armed, proposed > m.confirm * m.edgeFraction(velocity: v), fromEdge < m.edgeZone {
            armed = true
            if reveal.adjust == 0 {
                reveal.adjust = m.confirm - proposed
                proposed = m.confirm
            }
        }
        let target = m.resisted(proposed) + (armed ? m.armed - m.confirm : 0)
        if armed != reveal.armed {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            reveal.springing = true
        }
        if armed || reveal.springing {
            withAnimation(PhoneSwipeMotion.bodyAnimation) {
                reveal.armed = armed
                reveal.distance = target
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { reveal.distance = target }
        }
    }

    private func panEnded(translation: CGFloat, velocity: CGFloat, cancelled: Bool) {
        guard reveal.dragging else { return }
        reveal.dragging = false
        let m = metricsFor(reveal.side)
        let sign: CGFloat = reveal.side == .leading ? 1 : -1
        let t = translation * sign, v = velocity * sign
        let commit = !cancelled && reveal.armed
        let open = !commit && m.count > 0 && (abs(v) > 50 ? v > 50 : reveal.initial + t > m.open / 2)
        let primary = actions.first
        settle(open: open, velocity: v)
        // The full swipe runs the outer action (then the row is closed, as Telegram's Read/Unread).
        if commit, let primary { DispatchQueue.main.async { primary.run() } }
    }

    /// Open (the buttons' width) or closed, with Telegram's critically damped spring
    /// carrying on the finger's speed.
    private func settle(open: Bool, velocity: CGFloat = 0) {
        let m = metricsFor(reveal.side)
        let target = open ? m.open : 0
        let remaining = target - reveal.distance
        let v = abs(remaining) > 0.5 ? min(100, max(0, velocity / remaining)) : 0
        reveal.springing = false
        reveal.dragging = false
        reveal.settling = true
        withAnimation(.interpolatingSpring(PhoneSwipeMotion.body, initialVelocity: v)) {
            reveal.distance = target
            reveal.armed = false
        } completion: {
            guard !reveal.dragging else { return }
            reveal.settling = false
            if reveal.distance == 0 { reveal.side = nil }
        }
        withAnimation(PhoneSwipeMotion.plate) {
            reveal.plate = open ? 1 : 0
            reveal.round = open ? 1 : 0
            if open {
                swipes.litID = id
            } else if swipes.litID == id {
                swipes.litID = nil
            }
        }
        if open {
            swipes.openID = id
        } else if swipes.openID == id {
            swipes.openID = nil
        }
    }

    /// A button: close, then its action (its own change animates on its own).
    private func run(_ action: PhoneSwipeAction) {
        settle(open: false)
        DispatchQueue.main.async { action.run() }
    }
}
