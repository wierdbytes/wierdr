import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// Telegram's swipe actions on a chat row (ItemListRevealOptionsNode, ItemListRevealMotion,
// ItemListRevealTouchGestureRecognizer), for the rows of the iPhone's list: round 50-pt buttons
// with a label under them (Close: the row's full height, no label), revealed in the strip the
// row slides away from; the outermost one runs on a full swipe. See `PhoneListRow` for the row
// that uses them.

/// One swipe action of a row: a round button, its label under it.
struct PhoneSwipeAction: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var color: Color
    var iconColor: Color = .white
    /// The button takes the row's full height (rounded as the plate is) and has no
    /// label under it; the title stays for VoiceOver.
    var fillsRow = false
    var run: () -> Void
}

/// The side whose actions show: leading (the row slides right) or trailing (it slides left).
enum PhoneSwipeSide { case leading, trailing }

/// The list's shared row state: one row's actions show at a time (scrolling or a
/// tap elsewhere closes it), and the lit row (pressed, held after a tap, swiped),
/// whose neighbour above hides its separator, as a table cell's does.
@MainActor
@Observable
final class PhoneRowSwipes {
    /// The row whose actions show (being swiped, open, or closing).
    var openID: String?
    /// The row drawn lit.
    var litID: String?

    func closeAll() { openID = nil }
}

/// Telegram's motion numbers.
enum PhoneSwipeMotion {
    /// Open, close, the full swipe's jump (critically damped, 0.5 s).
    static let body = Spring(response: 0.5, dampingRatio: 1)
    static var bodyAnimation: Animation { .spring(response: 0.5, dampingFraction: 1) }
    /// The rounded plate the row slides on, in and out.
    static let plate = Animation.spring(response: 0.66, dampingFraction: 0.95)
    /// The buttons popping in as they're uncovered.
    static let pop = Animation.spring(response: 0.5, dampingFraction: 0.7)
}

// MARK: - Geometry

/// Where the buttons are and how far the row goes (`ItemListRevealMotionParameters`):
/// edge insets of 10, 10 between buttons; open at 20 + n·50 + (n-1)·10; the full
/// swipe arms at min(w, max(open + 20, 0.525·w)) and the row then jumps to 0.75·w;
/// past that the finger's travel is resisted (d^0.7).
struct PhoneSwipeMetrics {
    var width: CGFloat
    var count: Int
    /// Rows under 68 pt: 60 × 32 pills (Telegram's compact buttons).
    var compact: Bool

    static let spacing: CGFloat = 10
    static let edge: CGFloat = 10
    static let titleSpacing: CGFloat = 4
    static let titleHeight: CGFloat = 14

    var buttonWidth: CGFloat { compact ? 60 : 50 }
    var buttonHeight: CGFloat { compact ? 32 : 50 }
    var slotWidth: CGFloat { compact ? 70 : 60 }

    var open: CGFloat {
        count == 0 ? 0 : 2 * Self.edge + CGFloat(count) * buttonWidth + CGFloat(count - 1) * Self.spacing
    }

    var confirm: CGFloat { min(width, max(open + 20, width * 0.525)).rounded() }

    var armed: CGFloat { max(confirm, width * 0.75) }

    /// Near the far edge a fast enough swipe arms early.
    var edgeZone: CGFloat { width >= 414 ? 90 : (width == 375 ? 75 : 50) }

    func edgeFraction(velocity: CGFloat) -> CGFloat {
        min(width >= 414 ? 0.75 : 0.8, max(width >= 414 ? 0.5 : 0.66, abs(velocity) / 2500))
    }

    func resisted(_ d: CGFloat, inverse: Bool = false) -> CGFloat {
        let k: CGFloat = inverse ? 1 / 0.7 : 0.7
        if d < 0 { return -pow(-d, k) }
        if d > confirm { return confirm + pow(d - confirm, k) }
        return d
    }

    /// A button's place: its center's distance from the outer edge, width, scale, opacity.
    struct Button {
        var center: CGFloat
        var width: CGFloat
        var scale: CGFloat
        var opacity: CGFloat
    }

    /// Index 0 is the outermost (the full swipe's). Each one grows in as the strip
    /// uncovers it; past the open width the outer one stretches with the row and
    /// the others ride along its edge, fading; armed, the outer one fills the strip.
    func buttons(distance: CGFloat, expansion: CGFloat) -> [Button] {
        let d = max(0, distance)
        let e = min(1, max(0, expansion))
        return (0..<count).map { i in
            let outside = Self.edge + CGFloat(i) * (buttonWidth + Self.spacing)
            let end = outside + buttonWidth + Self.edge
            let start = end - buttonWidth + 2 * Self.spacing
            var scale = min(1, max(0, (d - start) / max(1, end - start)))
            var opacity = scale
            var width = buttonWidth
            var center = outside + width / 2
            if i == 0 {
                let stretched = width + max(0, d - open)
                let filled = max(width, d - 2 * Self.edge)
                width = stretched + (filled - stretched) * e
                center = Self.edge + width / 2
            }
            if d > open + 0.001 {
                if i == 0 {
                    scale = 1
                    opacity = 1
                } else {
                    center += d - open
                    scale = 1 - e
                    opacity = (1 - min(1, d / max(1, confirm)) * 0.7) * (1 - e)
                }
            }
            return Button(center: center, width: width, scale: scale, opacity: opacity < 0.01 ? 0 : opacity)
        }
    }
}

// MARK: - Buttons

/// The revealed strip: the side's buttons at their places, cut to the strip.
struct PhoneSwipeButtons: View {
    var actions: [PhoneSwipeAction]
    var side: PhoneSwipeSide
    var metrics: PhoneSwipeMetrics
    var distance: CGFloat
    var expansion: CGFloat
    var height: CGFloat
    var tap: (PhoneSwipeAction) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let geometry = metrics.buttons(distance: distance, expansion: expansion)
        let w = metrics.width
        let shown = max(0, distance)
        ZStack(alignment: .topLeading) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                let g = geometry[i]
                let x = side == .leading ? g.center : w - g.center
                button(action, g: g, primary: i == 0)
                    .position(x: x, y: height / 2)
            }
        }
        .frame(width: w, height: height)
        .mask(alignment: side == .leading ? .leading : .trailing) {
            Rectangle().frame(width: min(w, shown))
        }
    }

    private func button(_ action: PhoneSwipeAction, g: PhoneSwipeMetrics.Button, primary: Bool) -> some View {
        let m = metrics
        let stretched = primary && g.width > m.buttonWidth + 0.5
        // Armed, the outer button's icon goes to its inner end (the row's side).
        let e = primary ? min(1, max(0, expansion)) : 0
        let iconShift = (g.width / 2 - (m.compact ? 16 : 20)) * e * (side == .leading ? 1 : -1)
        return Button { tap(action) } label: {
            VStack(spacing: PhoneSwipeMetrics.titleSpacing) {
                let h = action.fillsRow ? height : m.buttonHeight
                RoundedRectangle(cornerRadius: min(26, h / 2), style: .continuous)
                    .fill(action.color)
                    .frame(width: g.width, height: h)
                    .overlay {
                        Image(systemName: action.symbol)
                            .font(.system(size: m.compact ? 17 : 22, weight: .semibold))
                            .foregroundStyle(action.iconColor)
                            .offset(x: iconShift)
                    }
                if !action.fillsRow {
                    Text(action.title)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: PhoneSwipeMetrics.titleHeight)
                        .opacity(1 - e)
                }
            }
            .frame(width: stretched ? g.width : m.slotWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(PhoneSwipeButtonStyle())
        .scaleEffect(g.scale)
        .opacity(g.opacity)
        .animation(PhoneSwipeMotion.pop, value: g.scale)
        .accessibilityLabel(action.title)
    }
}

/// Pressed, a button darkens a little (Telegram: its color at 0.9 brightness, in 0.08 s, out 0.18 s).
private struct PhoneSwipeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: configuration.isPressed ? 0.08 : 0.18), value: configuration.isPressed)
    }
}

// MARK: - The pan

/// A row's horizontal swipe as a UIKit recognizer, so it works with the list's
/// scrolling (and the pager's pan) as Telegram's does:
/// - it starts after 25 pt of mostly horizontal travel and fails as soon as the
///   finger goes more than 10 pt up or down (more than sideways): the list's
///   scrolling waits for that (`shouldBeRequiredToFailBy` its pan);
/// - with `edgeOnly` (the pager pages through tabs) it takes only touches that
///   start in the edge zones, x < e or x > width − e with e = clamp(width/6, 22, 80);
///   the pager's pan takes the ones in between, so the two never compete;
/// - an open row takes horizontal swipes anywhere on it (they close it), and pans
///   around it (the pager's) wait for it.
struct PhoneRowPan: UIGestureRecognizerRepresentable {
    var edgeOnly: Bool
    var width: CGFloat
    var isOpen: Bool
    /// Whether a swipe in this direction (+1 right, -1 left) can start.
    var canBegin: (CGFloat) -> Bool
    /// The swipe started this way (+1 right, -1 left).
    var began: (CGFloat) -> Void
    /// Translation since the start (past the 25 pt), velocity, the finger's x in the row.
    var changed: (_ translation: CGFloat, _ velocity: CGFloat, _ x: CGFloat) -> Void
    var ended: (_ translation: CGFloat, _ velocity: CGFloat, _ cancelled: Bool) -> Void

    static func edgeZone(_ width: CGFloat) -> CGFloat { min(max(width / 6, 22), 80) }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, parent: self)
    }

    func makeUIGestureRecognizer(context: Context) -> PhoneRowPanRecognizer {
        let pan = PhoneRowPanRecognizer()
        pan.delegate = context.coordinator
        pan.canBegin = { [weak coordinator = context.coordinator] direction in
            coordinator?.parent.canBegin(direction) ?? false
        }
        return pan
    }

    func updateUIGestureRecognizer(_ pan: PhoneRowPanRecognizer, context: Context) {
        context.coordinator.parent = self
    }

    func handleUIGestureRecognizerAction(_ pan: PhoneRowPanRecognizer, context: Context) {
        switch pan.state {
        case .began:
            began(pan.direction)
            changed(pan.translation, pan.velocity, context.converter.localLocation.x)
        case .changed:
            changed(pan.translation, pan.velocity, context.converter.localLocation.x)
        case .ended:
            ended(pan.translation, pan.velocity, false)
        case .cancelled:
            ended(pan.translation, pan.velocity, true)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var parent: PhoneRowPan

        init(converter: CoordinateSpaceConverter, parent: PhoneRowPan) {
            self.converter = converter
            self.parent = parent
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let p = parent
            guard p.edgeOnly, !p.isOpen, p.width > 0 else { return true }
            // SwiftUI's global space is its hosting view's (the page's, `PhoneSpacePager`), not the window's.
            let x = converter.convert(globalPoint: touch.location(in: g.view?.controllerRoot), to: .local).x
            let e = PhoneRowPan.edgeZone(p.width)
            return x < e || x > p.width - e
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let pan = other as? UIPanGestureRecognizer, other !== g else { return false }
            // The list's scrolling waits for the row's vertical rejection (else it wins before 25 pt).
            if let scroll = pan.view as? UIScrollView, scroll.panGestureRecognizer === pan { return true }
            // An open row: a horizontal swipe on it closes it, rather than paging.
            return parent.isOpen
        }
    }
}

/// Telegram's reveal recognizer, rewritten: one finger; fails on 10 pt of mostly
/// vertical travel, begins on 25 pt of mostly horizontal travel (when `canBegin`
/// allows that direction); its translation counts from there; the velocity is
/// the finger's over its last 80 ms.
final class PhoneRowPanRecognizer: UIGestureRecognizer {
    var canBegin: ((CGFloat) -> Bool)?
    private(set) var translation: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    /// +1 right, -1 left.
    private(set) var direction: CGFloat = 0
    private var touch: UITouch?
    private var origin: CGPoint = .zero
    private var current: CGPoint = .zero
    private var startX: CGFloat = 0
    private var samples: [(time: TimeInterval, x: CGFloat)] = []

    static let slop: CGFloat = 25

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let t = touches.first else {
            state = state == .began || state == .changed ? .cancelled : .failed
            return
        }
        touch = t
        origin = t.location(in: view)
        current = origin
        samples = [(t.timestamp, origin.x)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        for c in event.coalescedTouches(for: t) ?? [t] { sample(c) }
        let dx = current.x - origin.x, dy = current.y - origin.y
        switch state {
        case .possible:
            if abs(dy) > 10 && abs(dy) >= abs(dx) { state = .failed; return }
            if abs(dx) >= Self.slop && abs(dx) > abs(dy) {
                direction = dx < 0 ? -1 : 1
                if canBegin?(direction) == false { state = .failed; return }
                startX = origin.x + direction * Self.slop
                translation = current.x - startX
                state = .began
            }
        case .began, .changed:
            translation = current.x - startX
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        touch = nil
        samples.removeAll(keepingCapacity: true)
        translation = 0
        velocity = 0
    }

    override func location(in view: UIView?) -> CGPoint {
        guard let touch else { return super.location(in: view) }
        return touch.location(in: view)
    }

    private func sample(_ t: UITouch) {
        current = t.location(in: view)
        samples.append((t.timestamp, current.x))
        samples.removeAll { t.timestamp - $0.time > 0.08 }
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.004 else { return }
        velocity = (last.x - first.x) / CGFloat(last.time - first.time)
    }
}

// MARK: - The press

/// What a finger does on a row, for its highlight (Telegram's list): down and
/// still for 0.08 s, moved more than 4 pt (scrolling, swiping), lifted, or taken
/// away (the context menu, a pan). Never takes the touch from anything else.
enum PhonePress { case down, moved, up, cancelled }

struct PhoneRowPress: UIGestureRecognizerRepresentable {
    var changed: (PhonePress) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.08
        press.allowableMovement = 4
        press.cancelsTouchesInView = false
        press.delaysTouchesEnded = false
        press.delegate = context.coordinator
        return press
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        let at = context.converter.location(in: .global)
        switch press.state {
        case .began:
            context.coordinator.start = at
            changed(.down)
        case .changed:
            let s = context.coordinator.start
            if !context.coordinator.moved, hypot(at.x - s.x, at.y - s.y) > 4 {
                context.coordinator.moved = true
                changed(.moved)
            }
        case .ended:
            if !context.coordinator.moved { changed(.up) }
            context.coordinator.moved = false
        case .cancelled, .failed:
            if !context.coordinator.moved { changed(.cancelled) }
            context.coordinator.moved = false
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero
        var moved = false

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
