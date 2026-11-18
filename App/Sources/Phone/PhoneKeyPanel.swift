import SwiftUI
import UIKit
import WierdrModel

/// The key panel, at the right of the terminal: a swipe to the left on the
/// terminal slides out a narrow column of large keys over it, within the
/// thumb's reach, with or without the keyboard (then above it); see
/// `KeyPanelLayer`. The column has no backing: only its keys cover the
/// terminal, each a pill in the message field's glass (`composerGlass`, one
/// glass container as the bars'), ⏎ with the send button's accent pill inside
/// it. Each time it opens, ⏎ comes to the height the swipe began (with the
/// keyboard up, to the column's bottom), where the keys an agent asks for are
/// (⏎, space, esc, arrows, tab, 1 2 3, y n), with ctrl keys and Paste above (and Hide
/// over Paste while a keyboard is up). A scroll past either end comes back to
/// where the end key shows whole and the next one half: ⏎ at the column's top
/// with half of space, or the first key at its bottom with half of the next one
/// (`restRange`). Less room for the column (the keyboard, a taller message
/// field) moves the keys only when that breaks these limits, to the nearest
/// place that keeps them, animated; more room leaves them where they are.
/// Keys don't close it, so ↓ ↓ ⏎ is three taps; a swipe to the right does.
/// The message field is under the terminal (`ComposerBar`, attachments there
/// too); a double tap on the terminal brings its own keyboard, with its key bar.
struct PhoneKeyPanel: View {
    var address: String
    /// On screen (even partly): each time it comes out, ⏎ comes to `restY`.
    var shown: Bool
    /// Where ⏎ comes out, in global coordinates: under the thumb, where the
    /// swipe began (0: unknown, the column's middle). With the keyboard up, at
    /// the column's bottom instead.
    var restY: CGFloat

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @State private var pressed = 0
    /// The column's top and height in the window: its limits, where ⏎ comes out.
    @State private var frame: CGRect = .zero
    /// The keys' height, Hide's place too: where ⏎ is in the column's content.
    @State private var keysHeight: CGFloat = 0
    /// Where the column is scrolled to and what moves it, as it goes (not state:
    /// it changes every frame, and the scroll target behavior reads it as it's asked).
    @State private var scroll = KeyColumnScroll()
    /// The app's own scrolls of the column, always to an offset: one to a key and
    /// an anchor the scroll view did again when it changed size (the keys jumped
    /// as the keyboard came, after a spring back); an offset done again stays put.
    @State private var position = ScrollPosition()
    /// Out before the column's or the keys' height was known: placed once it is.
    @State private var unplaced = false

    static let width: CGFloat = 96
    fileprivate static let keyHeight: CGFloat = 52
    /// Between the keys of a group.
    private static let spacing: CGFloat = 6
    /// Between groups.
    private static let groupSpacing: CGFloat = 14
    /// Under ⏎: the margin it keeps from the column's bottom.
    private static let bottomMargin: CGFloat = 12
    /// Empty room above and below the keys, more than any screen is tall. The
    /// content never changes size (Hide's place is kept while it's away), so the
    /// scroll view never has to move it back into range when it grows or shrinks.
    private static let room: CGFloat = 1600
    /// Back to a limit (a finger let go past it, or the column got shorter): quick,
    /// no overshoot, as a scroll view's own bounce.
    private static let springBack = Animation.spring(duration: 0.3, bounce: 0)

    var body: some View {
        let session = services.terminalSession(address)
        let typing = session?.hasKeyboardFocus == true || composing
        ScrollView(.vertical, showsIndicators: false) {
            // One glass container, as the bars': the keys' glass renders together.
            ComposerGlassGroup { keys(session, typing: typing) }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { keysHeight = $0 }
                .padding(.horizontal, 7)
                .padding(.vertical, Self.room)
        }
        .scrollPosition($position)
        // A finger's scroll comes to rest within the limits.
        .scrollTargetBehavior(KeyColumnStops(range: restRange(typing: typing), scroll: scroll))
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { [scroll] _, y in scroll.y = y }
        .onScrollPhaseChange { _, new, context in
            scroll.phase = new
            // Come to rest past a limit (a finger let go of it there, see
            // `KeyColumnStops`, or however else): back, in one spring.
            if new == .idle, shown { settle(context.geometry.contentOffset.y, typing: typing) }
        }
        // Made while out too (another pane's terminal got the keys): placed at once.
        .onChange(of: shown, initial: true) { _, shown in if shown { place(typing: typing) } }
        .onChange(of: frame.height) { before, after in
            if unplaced { return place(typing: typing) }
            // Less room: back within the limits if it broke them (not under a
            // finger: its scroll's end has them). More room: the keys stay.
            if after < before, shown, scroll.phase != .interacting, scroll.phase != .decelerating {
                settle(scroll.y, typing: typing)
            }
        }
        .onChange(of: keysHeight) { if unplaced { place(typing: typing) } }
        // Only the top and height (not x, which the back swipe moves every frame).
        .onGeometryChange(for: CGRect.self) { p in
            let f = p.frame(in: .global)
            return CGRect(x: 0, y: f.minY, width: 0, height: f.height)
        } action: { frame = $0 }
        .frame(width: Self.width)
        // No backing: only the keys cover the terminal, the gaps between them leave it in view.
        .sensoryFeedback(.impact(weight: .light), trigger: pressed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key Panel")
    }

    /// The keys, top to bottom: Hide while a keyboard is up (its place kept
    /// empty otherwise, so nothing moves when it comes), Paste, ctrl keys,
    /// ! @ /, n y 3 2 1, ⇧tab tab, the arrows, esc, space and ⏎.
    private func keys(_ session: TerminalSession?, typing: Bool) -> some View {
        VStack(spacing: Self.groupSpacing) {
            group {
                if typing {
                    PanelButton(icon: "keyboard.chevron.compact.down", caption: "Hide", a11y: "Hide the Keyboard") {
                        if composing { return controller.closeCompose() }
                        UIView.performWithoutAnimation { session?.releaseKeyboard() }
                    }
                } else {
                    Color.clear.frame(height: Self.keyHeight)
                        .accessibilityHidden(true)
                }
                PanelButton(icon: "doc.on.clipboard", caption: "Paste", a11y: "Paste Text") { pasteText(session) }
            }
            group {
                key("^R", .control(0x12), a11y: "Control R")
                key("^L", .control(0x0c), a11y: "Control L")
                key("^D", .control(0x04), a11y: "Control D")
                key("^J", .control(0x0a), a11y: "Control J")
                key("^C", .control(0x03), a11y: "Control C")
            }
            group {
                key("!", .text("!"), a11y: "Exclamation mark")
                key("@", .text("@"), a11y: "At")
                key("/", .text("/"), a11y: "Slash")
            }
            group {
                key("n", .text("n"), a11y: "n")
                key("y", .text("y"), a11y: "y")
                key("3", .text("3"), a11y: "3")
                key("2", .text("2"), a11y: "2")
                key("1", .text("1"), a11y: "1")
            }
            group {
                key("⇧tab", .backtab, a11y: "Shift Tab")
                key("tab", .tab, a11y: "Tab")
            }
            group {
                key("←", .left, symbol: "arrow.left", repeats: true, a11y: "Left")
                key("→", .right, symbol: "arrow.right", repeats: true, a11y: "Right")
                key("↑", .up, symbol: "arrow.up", repeats: true, a11y: "Up")
                key("↓", .down, symbol: "arrow.down", repeats: true, a11y: "Down")
            }
            group {
                key("esc", .escape, a11y: "Escape")
                key("␣", .text(" "), symbol: "space", a11y: "Space")
                key("⏎", .enter, symbol: "return", prominent: true, a11y: "Return")
            }
            .padding(.bottom, Self.bottomMargin)
        }
    }

    /// Where it starts each time it comes out: ⏎'s middle on the rest line (with
    /// the keyboard up, the ⏎ group's margin at the column's bottom), within the
    /// limits. Before the column's and the keys' heights are known, once they
    /// are (`unplaced`).
    private func place(typing: Bool) {
        guard frame.height > 0, keysHeight > 0 else { unplaced = true; return }
        unplaced = false
        let enter = Self.room + keysHeight - Self.bottomMargin - Self.keyHeight / 2
        let range = restRange(typing: typing)
        let y = min(max(typing ? Self.room + keysHeight - frame.height : enter - restLine, range.lowerBound), range.upperBound)
        // Known at once (the scroll's own report comes a moment later).
        scroll.y = y
        position.scrollTo(y: y)
    }

    /// Where ⏎'s middle comes out, from the column's top: `restY` (0: the middle).
    private var restLine: CGFloat {
        guard restY > 0 else { return frame.height / 2 }
        return min(max(restY - frame.minY, Self.keyHeight), frame.height - Self.keyHeight)
    }

    /// At `y` past a limit (by more than the pixel the scroll lands on): to the
    /// nearest place within them, in one spring.
    private func settle(_ y: CGFloat, typing: Bool) {
        let range = restRange(typing: typing)
        guard y < range.lowerBound - 1 || y > range.upperBound + 1 else { return }
        let to = min(max(y, range.lowerBound), range.upperBound)
        scroll.y = to
        withAnimation(Self.springBack) { position.scrollTo(y: to) }
    }

    /// The offsets the column may rest at: up to where ⏎ shows whole at its top,
    /// with half of space above it, and down to where the first key shows whole at
    /// its bottom, with half of the next one under it (with the keyboard up, Hide
    /// and Paste; without, Paste and ^R, past Hide's empty place and a group's gap).
    private func restRange(typing: Bool) -> ClosedRange<CGFloat> {
        let h = frame.height, k = Self.keyHeight
        guard h > 0, keysHeight > 0 else { return 0...(.greatestFiniteMagnitude) }
        // The middles of the second key and of the one above ⏎ (space), in the content.
        let second = Self.room + (typing ? k + Self.spacing : 2 * k + Self.spacing + Self.groupSpacing) + k / 2
        let aboveEnter = Self.room + keysHeight - Self.bottomMargin - k - Self.spacing - k / 2
        return (second - h)...max(second - h, aboveEnter)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: Self.spacing, content: content)
    }

    private func key(_ label: String, _ key: TerminalSession.Key, symbol: String? = nil,
                     repeats: Bool = false, prominent: Bool = false, a11y: String) -> some View {
        PanelButton(label: label, icon: symbol, a11y: a11y, repeats: repeats, prominent: prominent) {
            send(key)
        }
    }

    /// Why input can't go anywhere: the demo has no terminals; live, the
    /// session is not there yet (or the terminal is gone).
    private var unavailable: String {
        controller.isDemo ? "Not available in the demo" : "The terminal is not connected yet"
    }

    /// The message field has the keyboard (`ComposerBar`): pasted text goes into it.
    private var composing: Bool { controller.composing == address }

    /// Adds to the message (a space before, unless at a line's start) and gives it the
    /// keyboard again if the paste prompt took it away.
    private func addToMessage(_ s: String) {
        var text = controller.drafts[address] ?? ""
        if let last = text.last, !last.isWhitespace { text += " " }
        controller.drafts[address] = text + s
        controller.composing = address
        pressed += 1
    }

    private func live(_ session: TerminalSession?) -> TerminalSession? {
        guard let session else { controller.toast(unavailable); return nil }
        guard session.acceptsInput else { controller.toast("The terminal is not connected yet"); return nil }
        return session
    }

    private func send(_ key: TerminalSession.Key) {
        guard let session = live(services.terminalSession(address)) else { return }
        session.send(key: key)
        pressed += 1
    }

    /// The clipboard's text into the message while it is open; otherwise into
    /// the program, as a paste (bracketed when it asked), no Return.
    private func pasteText(_ session: TerminalSession?) {
        let intoMessage = composing
        guard intoMessage || live(session) != nil else { return }
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string, !text.isEmpty else {
            return controller.toast("No text on the clipboard")
        }
        if intoMessage { return addToMessage(text) }
        session?.send(text: text, submit: false)
        pressed += 1
    }
}

/// The key column's scroll as it goes, kept outside the view's state.
private final class KeyColumnScroll {
    /// Its offset.
    var y: CGFloat = 0
    /// What moves it.
    var phase: ScrollPhase = .idle
}

/// Where a finger's scroll of the key column comes to rest: within `range`.
/// The system asks at other times too: when the column changes size (the
/// keyboard, the message field: `PhoneKeyPanel` settles that itself) and every
/// frame of a scroll the app animates; those it leaves as they are.
///
/// Let go within the range, or thrown back towards it, the column slows down
/// to its natural end, cut at the limit (in the direction it goes). Let go
/// past a limit, moving on or still, it stops where it is, and the column
/// springs back from there once at rest (`PhoneKeyPanel`'s idle phase): a
/// target behind it the scroll view takes at once, a jump, and one ahead of
/// it from a standstill it reaches slowly.
private struct KeyColumnStops: ScrollTargetBehavior {
    var range: ClosedRange<CGFloat>
    var scroll: KeyColumnScroll

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Read as it's asked: the phase the view was last drawn with lags behind.
        guard scroll.phase == .interacting else { return }
        let lo = range.lowerBound, hi = range.upperBound
        let now = scroll.y, end = target.rect.origin.y
        // Past a limit (by more than the pixel it lands on) and going on, or not back far enough: stop.
        if (now < lo - 1 && end < lo) || (now > hi + 1 && end > hi) {
            target.rect.origin.y = now
        } else {
            target.rect.origin.y = min(max(end, lo), hi)
        }
    }
}

/// One key of the panel: a glass pill as wide as the column (82 pt), 52 pt tall, in
/// the message field's glass (`composerGlass`: interactive on iOS 26+, its drawn
/// stand-in before) with the bars' system font and the theme's foreground. The
/// prominent one (⏎) holds the send button's accent pill, 3 pt in. Pressed, its
/// glyph dims as the attach button's does (the accent pill sinks a little instead).
private struct PanelButton: View {
    var label: String?
    var icon: String?
    var caption: String?
    var a11y: String
    var repeats = false
    var prominent = false
    var action: () -> Void

    @Environment(\.theme) private var theme

    init(label: String? = nil, icon: String? = nil, caption: String? = nil, a11y: String,
         repeats: Bool = false, prominent: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.caption = caption
        self.a11y = a11y
        self.repeats = repeats
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: caption == nil ? 20 : 18, weight: prominent ? .semibold : .medium))
                } else if let label {
                    Text(label)
                        .font(.system(size: label.count > 2 ? 17 : 20, weight: .medium))
                }
                if let caption {
                    Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.muted)
                }
            }
            .foregroundStyle(prominent ? theme.accentForeground : theme.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: PhoneKeyPanel.keyHeight)
            .background {
                if prominent { Capsule().fill(theme.accent).padding(3) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PanelPressStyle(prominent: prominent))
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .composerGlass(Capsule(), theme: theme)
        .accessibilityLabel(a11y)
    }
}

/// The attach button's press (`AttachPressStyle`): the glyph drops to 0.4 at once on
/// touch, back over 0.2 s; the prominent key's accent pill sinks to 0.9 instead, as the
/// send button does (less: its glass stays).
private struct PanelPressStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .opacity(pressed && !prominent ? 0.4 : 1)
            .scaleEffect(pressed && prominent ? 0.9 : 1)
            .animation(pressed ? (prominent ? .easeOut(duration: 0.1) : nil) : .easeInOut(duration: 0.2), value: pressed)
    }
}

// MARK: - Gestures

/// The panel's gestures. Placed behind the terminal, it fills the terminal's
/// area (where they start) and puts its recognizers on the window's root
/// view, so they see touches over the terminal too (like the back swipe).
/// Closed, a swipe to the left anywhere on a terminal pulls the panel out at
/// the right; open, a swipe right anywhere in the area pushes it back (only
/// that: taps beside it are the terminal's). While a keyboard is up (the
/// terminal's or the message field's), a double tap on the terminal hides it
/// (beside the panel too). Otherwise taps are the terminal's own (a click for
/// the program, with a keyboard up too; a double tap brings its keyboard), as
/// are its pans (scrolling, selection, mouse), except a swipe that moves the
/// panel: they wait for it (it fails at once on a vertical move or the wrong way).
struct PhoneKeyPanelGestures: UIViewRepresentable {
    var enabled: Bool
    var isOpen: Bool
    /// A keyboard is up (the terminal's or the message field's): a double tap on the terminal hides it.
    var keyboardUp = false
    /// The finger's travel (leftward is negative) and where it is, in the terminal's area.
    var onDrag: (CGFloat, CGPoint) -> Void
    /// Where the panel would come to rest at the finger's speed (translation), and where the finger left.
    var onEnd: (CGFloat, CGPoint) -> Void
    /// A double tap on the terminal while a keyboard is up: hides it.
    var onDoubleTap: () -> Void

    /// Its pan's name: the sidebar's and the list's swipes on a terminal wait for it (it closes the open panel).
    static let panName = "wierdr.keyPanel.pan"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        context.coordinator.anchor = anchor
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.pan.isEnabled != enabled { c.pan.isEnabled = enabled }
        let doubleTapOn = enabled && keyboardUp
        if c.doubleTap.isEnabled != doubleTapOn { c.doubleTap.isEnabled = doubleTapOn }
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window?.rootViewController?.view)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PhoneKeyPanelGestures?
        weak var anchor: Anchor?
        let pan = UIPanGestureRecognizer()
        let doubleTap = UITapGestureRecognizer()
        /// The current pan may move the panel (it began where it should): others' pans wait for it.
        private var claims = false
        /// The terminal it began on (with the panel in): its pane gets the focus as the panel comes.
        private weak var swiped: WierdrTerminalView?

        override init() {
            super.init()
            pan.maximumNumberOfTouches = 1
            pan.name = PhoneKeyPanelGestures.panName
            pan.addTarget(self, action: #selector(moved(_:)))
            pan.delegate = self
            doubleTap.numberOfTapsRequired = 2
            doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
            doubleTap.delegate = self
            doubleTap.isEnabled = false
        }

        func attach(to view: UIView?) {
            guard let view, pan.view !== view else { return }
            detach()
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(doubleTap)
        }

        func detach() {
            for g in [pan, doubleTap] as [UIGestureRecognizer] { g.view?.removeGestureRecognizer(g) }
        }

        @objc private func moved(_ g: UIPanGestureRecognizer) {
            guard let parent, let view = g.view else { return }
            let x = g.translation(in: view).x
            let p = g.location(in: anchor)
            switch g.state {
            case .began:
                // Keys for the pane swiped on (iPad splits), as a tap on it would focus it.
                if !parent.isOpen { swiped?.onTap?() }
                parent.onDrag(x, p)
            case .changed: parent.onDrag(x, p)
            case .ended: parent.onEnd(x + g.velocity(in: view).x * 0.25, p)
            case .cancelled, .failed: parent.onEnd(0, p)
            default: break
            }
        }

        @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
            if g.state == .ended { parent?.onDoubleTap() }
        }

        private func onTerminal(_ touch: UITouch) -> Bool { WierdrTerminalView.under(touch) != nil }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if g === pan { claims = false; swiped = nil }
            guard let parent, let anchor, anchor.window != nil else { return false }
            // The finger in the terminal's area (which moves with the back swipe). Not
            // through `nil`: in landscape that is the screen's unrotated space on the iPad.
            let area = anchor.bounds
            let p = touch.location(in: anchor)
            // Beside the terminal's rows only (not over the top bar); to its
            // right is the edge (or, in landscape, the safe area up to it).
            guard p.y >= area.minY, p.y <= area.maxY, p.x >= area.minX else { return false }
            if g === doubleTap {
                guard onTerminal(touch) else { return false }
                // A pointer's double click (trackpad, Universal Control) is the terminal's, as on a Mac.
                if touch.type == .indirectPointer { return false }
                // Open panel: beside it (its keys take their own taps); else anywhere.
                guard parent.isOpen else { return true }
                return p.x < area.maxX - PhoneKeyPanel.width
            }
            if parent.isOpen {
                claims = true
            } else if WierdrTerminalView.swipeable(touch) {
                // Anywhere on a terminal.
                claims = true
                swiped = WierdrTerminalView.under(touch)
            }
            return claims
        }

        // Closed: only a mostly horizontal move to the left (the panel comes out
        // at the right); open: one to the right.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan, let parent, let view = g.view else { return true }
            let v = pan.velocity(in: view)
            let dx = parent.isOpen ? v.x : -v.x
            return dx > 0 && dx > abs(v.y)
        }

        // The terminal's and the panel's pans wait for the panel's (it fails
        // at once on a vertical move). Only pans: a held finger never fails a
        // pan, so a held arrow key or the terminal's long press (its menu)
        // would wait until the finger lifts. Not the root view's own (the
        // list's swipe). The double tap beats the terminal's taps (click,
        // double tap): with a keyboard up, a click waits to see that no
        // second tap comes.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            if g === doubleTap { return other is UITapGestureRecognizer && other.view !== g.view }
            guard claims, other.view !== g.view else { return false }
            return other is UIPanGestureRecognizer
        }
    }
}
