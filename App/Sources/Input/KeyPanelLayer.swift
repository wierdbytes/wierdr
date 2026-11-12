import SwiftUI
import UIKit

/// The side of the terminal area the key panel is at.
enum KeyPanelSide: Equatable {
    case leading, trailing
}

/// The key panel as the views around it see it: out or not, and on which side.
struct KeyPanelState: Equatable {
    var open = false
    var side: KeyPanelSide = .trailing

    /// Room it takes at the leading / trailing side while it is out (for toasts beside it).
    var leadingInset: CGFloat { open && side == .leading ? PhoneKeyPanel.width : 0 }
    var trailingInset: CGFloat { open && side == .trailing ? PhoneKeyPanel.width : 0 }
}

/// Which keyboard a swipe from the edge (or a drag from the puck) brings.
enum KeyboardChoice: Hashable {
    /// The terminal's own (typing straight into it, with its key bar).
    case terminal
    /// The message field's (`PhoneComposeBar`).
    case message
}

extension View {
    /// The key panel over this terminal area and the ways it and the keyboards come (`KeyPanelLayer`).
    func keyPanel(address: String?, covered: Bool, thumbY: CGFloat = 0, state: Binding<KeyPanelState>) -> some View {
        modifier(KeyPanelLayer(address: address, covered: covered, thumbY: thumbY, state: state))
    }
}

/// The key panel (`PhoneKeyPanel`) over a terminal area, and how it and the keyboards come.
///
/// iPhone: a swipe from the area's right edge pulls the panel out with the finger
/// (or a tap on the grip there). iPad: the right edge is Slide Over's and the left
/// one the sidebar's, so a puck (`KeyPuck`) instead, wherever the person put it
/// (one place per orientation): a tap brings the panel out on the puck's side
/// (the nearer one), a drag from it toward the middle pulls it out with the finger,
/// as the iPhone's swipe, and a long press picks it up to move it. Its keys come
/// to rest at the puck's height, under the thumb.
///
/// While a swipe (or a drag from the puck) that began with the panel hidden is
/// under way, two icons beside the panel: the terminal's keyboard above the
/// finger, the message field below; let go on one and it comes (the panel goes).
/// Taps on the terminal are clicks for the program; while a keyboard is up, a
/// tap hides it; with the panel out, a tap beside it puts the panel back. While
/// the area is `covered` (the list, the sidebar overlay), the panel and the
/// keyboards go and the gestures rest.
struct KeyPanelLayer: ViewModifier {
    /// The focused terminal (nil: no terminal here, no keys).
    var address: String?
    var covered: Bool
    /// iPhone: the window y the keys come to rest at (a third of the screen up from its bottom).
    var thumbY: CGFloat
    @Binding var state: KeyPanelState

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    /// The finger's horizontal travel while it moves the panel.
    @State private var drag: CGFloat?
    /// The terminal area in global coordinates (its size; its top places the puck in the window).
    @State private var area: CGRect = .zero
    /// A swipe from the edge (or the puck) is under way: where it began (the icons sit above and below).
    @State private var pickerStart: CGPoint?
    /// The icon under the finger.
    @State private var hovered: KeyboardChoice?
    /// The puck while it is being moved, and where it was when picked up.
    @State private var movingPuck: CGPoint?
    @State private var moveOrigin: CGPoint = .zero
    /// The puck's place per orientation: "x,y" as fractions of the area.
    @AppStorage("keys.puck.landscape") private var puckLandscape = ""
    @AppStorage("keys.puck.portrait") private var puckPortrait = ""

    /// iPad: the puck instead of the swipe from the right edge.
    private var usesPuck: Bool { !Device.isPhone }

    func body(content: Content) -> some View {
        let enabled = address != nil && !covered
        content
            .background {
                // Behind the terminal, its size: where the panel's gestures start.
                PhoneKeyPanelGestures(
                    enabled: enabled,
                    isOpen: state.open,
                    side: state.side,
                    opensFromEdge: !usesPuck,
                    keyboardUp: keyboardUp,
                    onDrag: { x, p in moved(x, at: p) },
                    onEnd: { projected, p in released(projected: projected, at: p) },
                    // The panel first; then the keyboard (and the message field), at once.
                    onTap: {
                        if state.open { return setPanel(open: false) }
                        hideKeyboards()
                    }
                )
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { area = $0 }
            .overlay(alignment: state.side == .trailing ? .trailing : .leading) {
                if let address { panel(address) }
            }
            .overlay(alignment: .topLeading) {
                if usesPuck, enabled { puck }
            }
            .overlay {
                if let start = pickerStart {
                    KeyboardPickerIcons(centers: iconCenters(start), hovered: hovered)
                }
            }
            .sensoryFeedback(.selection, trigger: hovered)
            .onChange(of: covered) { _, covered in
                guard covered else { return }
                setPanel(open: false)
                hideKeyboards()
            }
    }

    // MARK: Keyboards

    /// The terminal has the keyboard, or the message field is open: a finger's
    /// tap on the terminal hides it (a pointer's click doesn't, see `PhoneKeyPanelGestures`).
    private var keyboardUp: Bool {
        guard let address else { return false }
        return controller.composing == address || services.terminalSession(address)?.hasKeyboardFocus == true
    }

    /// Hides the message field or the terminal's keyboard, at once.
    private func hideKeyboards() {
        if controller.composing != nil { return controller.closeCompose() }
        let session = services.terminalSession(address ?? "")
        UIView.performWithoutAnimation { session?.releaseKeyboard() }
    }

    // MARK: Panel

    /// How far out the panel is: 0 hidden, 1 open.
    private var progress: CGFloat {
        let w = PhoneKeyPanel.width
        guard let d = drag else { return state.open ? 1 : 0 }
        // Travel toward the middle (away from the panel's side) brings it out.
        let out = state.side == .trailing ? -d : d
        return state.open ? 1 - min(max(-out, 0), w) / w : min(max(out, 0), w) / w
    }

    /// Always there while the terminal is (so it slides both ways and an
    /// upload goes on), just past the area's side while hidden.
    private func panel(_ address: String) -> some View {
        let progress = progress
        let trailing = state.side == .trailing
        return ZStack(alignment: trailing ? .trailing : .leading) {
            if progress == 0, !usesPuck {
                PhoneKeyPanelGrip { setPanel(open: true) }
                    .transition(.opacity)
            }
            PhoneKeyPanel(address: address, shown: progress > 0, restY: restY, opensAtRest: usesPuck,
                          close: { setPanel(open: false) })
                .id(address)
                .offset(x: (1 - progress) * PhoneKeyPanel.width * (trailing ? 1 : -1))
                .allowsHitTesting(progress > 0)
                .accessibilityHidden(progress == 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: trailing ? .trailing : .leading)
        .clipped()
    }

    /// Where the keys come to rest (window y): at the puck's height on the iPad.
    private var restY: CGFloat {
        usesPuck ? area.minY + puckCenter.y : thumbY
    }

    private func setPanel(open: Bool) {
        withAnimation(.snappy(duration: 0.25)) {
            state.open = open
            drag = nil
        }
    }

    /// The panel comes out on this side (only while it is in: it doesn't jump across).
    private func setSide(_ side: KeyPanelSide) {
        guard state.side != side, !state.open else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { state.side = side }
    }

    private func finishDrag(projected: CGFloat) {
        let threshold = PhoneKeyPanel.width * 0.4
        let out = state.side == .trailing ? -projected : projected
        setPanel(open: state.open ? out > -threshold : out > threshold)
    }

    // MARK: Swipe (or drag from the puck)

    /// The finger moved the panel. A move that began with it hidden shows the keyboard icons.
    private func moved(_ x: CGFloat, at p: CGPoint) {
        if drag == nil, !state.open { pickerStart = p }
        drag = x
        if let start = pickerStart { hovered = choice(at: p, start: start) }
    }

    /// Let go on an icon: that keyboard (the panel goes); elsewhere: the panel as usual.
    private func released(projected: CGFloat, at p: CGPoint) {
        let choice = pickerStart.flatMap { choice(at: p, start: $0) }
        pickerStart = nil
        hovered = nil
        guard let choice else { return finishDrag(projected: projected) }
        bring(choice)
    }

    /// That keyboard comes (the panel goes).
    private func bring(_ choice: KeyboardChoice) {
        guard let address else { return }
        setPanel(open: false)
        switch choice {
        case .terminal:
            controller.closeCompose()
            guard let session = services.terminalSession(address) else {
                return controller.toast(controller.isDemo ? "Not available in the demo" : "The terminal is not connected yet")
            }
            session.takeKeyboard()
        case .message:
            controller.composing = address
        }
    }

    /// Beside the panel, one above the swipe's line and one below (in the area).
    /// As far from where the swipe began as from the edge on the iPhone, so the
    /// thumb travels as much to reach them from the puck.
    private func iconCenters(_ start: CGPoint) -> [KeyboardChoice: CGPoint] {
        let w = area.width, h = area.height
        let size = KeyboardPickerIcons.size
        let travel = PhoneKeyPanel.width + size / 2 + 14
        let r = size / 2 + 6
        let x: CGFloat
        switch state.side {
        case .trailing:
            let from = usesPuck ? start.x : w
            x = max(r, min(from - travel, w - PhoneKeyPanel.width - r))
        case .leading:
            let from = usesPuck ? start.x : 0
            x = min(max(r, w - r), max(from + travel, PhoneKeyPanel.width + r))
        }
        let gap = size / 2 + 26
        func y(_ v: CGFloat) -> CGFloat { min(max(v, r), max(r, h - r)) }
        return [.terminal: CGPoint(x: x, y: y(start.y - gap)), .message: CGPoint(x: x, y: y(start.y + gap))]
    }

    private func choice(at p: CGPoint, start: CGPoint) -> KeyboardChoice? {
        let reach = KeyboardPickerIcons.size / 2 + 10
        return iconCenters(start).first { hypot($0.value.x - p.x, $0.value.y - p.y) <= reach }?.key
    }

    // MARK: Puck (iPad)

    /// Kept this far from the area's sides: the screen's edges take swipes
    /// (Slide Over, the sidebar), and a touch on the puck must not start one.
    private static let puckInset: CGFloat = 30

    private var puckCenter: CGPoint { movingPuck ?? clampPuck(storedPuck) }

    /// The panel comes out on the puck's side (the nearer one).
    private var puckSide: KeyPanelSide { puckCenter.x < area.width / 2 ? .leading : .trailing }

    private var puck: some View {
        // Out of the way while the panel is out (or coming); kept in the tree, so a drag goes on.
        let hidden = progress > 0 || pickerStart != nil
        return KeyPuck(moving: movingPuck != nil)
            .allowsHitTesting(false)
            .overlay {
                KeyPuckGestures(
                    passesTouches: hidden,
                    side: puckSide,
                    onTap: {
                        let side = puckSide
                        if state.side != side {
                            setSide(side)
                            DispatchQueue.main.async { setPanel(open: true) }
                        } else {
                            setPanel(open: true)
                        }
                    },
                    onDrag: { t, start in
                        setSide(puckSide)
                        moved(t.width, at: puckPoint(start, t))
                    },
                    onEnd: { projected, t, start in
                        released(projected: projected, at: puckPoint(start, t))
                    },
                    onMove: { phase, t in movePuck(phase, t) }
                )
            }
            .opacity(hidden ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: hidden)
            .position(puckCenter)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Keys")
            .accessibilityHint("Opens the keys")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setSide(puckSide); setPanel(open: true) }
            .accessibilityAction(named: "Terminal Keyboard") { bring(.terminal) }
            .accessibilityAction(named: "Write a Message") { bring(.message) }
    }

    /// A finger that began `start` from the puck's center and moved `t`, in the area.
    private func puckPoint(_ start: CGPoint, _ t: CGSize) -> CGPoint {
        CGPoint(x: puckCenter.x + start.x + t.width, y: puckCenter.y + start.y + t.height)
    }

    private func movePuck(_ phase: KeyPuckGestures.MovePhase, _ t: CGSize) {
        switch phase {
        case .began:
            moveOrigin = puckCenter
            withAnimation(.snappy(duration: 0.15)) { movingPuck = moveOrigin }
        case .changed:
            movingPuck = clampPuck(CGPoint(x: moveOrigin.x + t.width, y: moveOrigin.y + t.height))
        case .ended:
            if let p = movingPuck { savePuck(p) }
            withAnimation(.snappy(duration: 0.15)) { movingPuck = nil }
        }
    }

    /// Landscape or portrait: the puck has a place for each (with the keyboard
    /// up the area can be wider than tall in portrait, so the screen's, not the area's).
    private var isLandscape: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            return scene.effectiveGeometry.interfaceOrientation.isLandscape
        }
        return area.width > area.height
    }

    /// Where the person put it; at first: at the right, a bit below the middle (the right thumb).
    private var storedPuck: CGPoint {
        let parts = (isLandscape ? puckLandscape : puckPortrait).split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            return CGPoint(x: parts[0] * area.width, y: parts[1] * area.height)
        }
        return CGPoint(x: area.width - Self.puckInset - KeyPuck.size / 2 - 10, y: area.height * 0.62)
    }

    private func clampPuck(_ p: CGPoint) -> CGPoint {
        let m = Self.puckInset + KeyPuck.size / 2
        return CGPoint(x: min(max(p.x, m), max(m, area.width - m)),
                       y: min(max(p.y, m), max(m, area.height - m)))
    }

    private func savePuck(_ p: CGPoint) {
        guard area.width > 0, area.height > 0 else { return }
        let c = clampPuck(p)
        let s = String(format: "%.4f,%.4f", c.x / area.width, c.y / area.height)
        if isLandscape { puckLandscape = s } else { puckPortrait = s }
    }
}

// MARK: - Keyboard icons

/// The two icons shown beside the key panel while a swipe from the edge (or a
/// drag from the puck) is under way: the terminal's keyboard above, the message
/// field below; the one under the finger lights up. Only a picture: the swipe
/// does the picking.
struct KeyboardPickerIcons: View {
    var centers: [KeyboardChoice: CGPoint]
    var hovered: KeyboardChoice?

    static let size: CGFloat = 58

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            ForEach([KeyboardChoice.terminal, .message], id: \.self) { choice in
                if let c = centers[choice] { icon(choice).position(c) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func icon(_ choice: KeyboardChoice) -> some View {
        let on = hovered == choice
        return VStack(spacing: 2) {
            Image(systemName: choice == .terminal ? "keyboard" : "text.bubble")
                .font(.system(size: 20, weight: .semibold))
            Text(choice == .terminal ? "Terminal" : "Message")
                .font(.ui(9.5, .medium))
        }
        .foregroundStyle(on ? theme.accentForeground : theme.foreground)
        .frame(width: Self.size, height: Self.size)
        .background(on ? theme.accent : theme.raised.opacity(0.92), in: Circle())
        .overlay(Circle().strokeBorder(on ? .clear : theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8)
        .scaleEffect(on ? 1.15 : 1)
        .animation(.snappy(duration: 0.15), value: on)
    }
}

// MARK: - Puck

/// The iPad's puck: a small translucent disc over the terminal (the terminal
/// shows through it), larger while it is being moved.
struct KeyPuck: View {
    var moving: Bool

    static let size: CGFloat = 46

    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .fill(theme.raised.opacity(moving ? 0.9 : 0.6))
            .overlay(Circle().strokeBorder(theme.border.opacity(0.8), lineWidth: 1))
            .overlay {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.foreground.opacity(moving ? 1 : 0.8))
            }
            .frame(width: Self.size, height: Self.size)
            .shadow(color: .black.opacity(moving ? 0.35 : 0.18), radius: moving ? 12 : 5, y: moving ? 4 : 1)
            .scaleEffect(moving ? 1.2 : 1)
            // Touches a little around it count too (`KeyPuckGestures`, over it).
            .frame(width: Self.size + 14, height: Self.size + 14)
    }
}

/// The puck's touches, in UIKit (a drag must go on while the puck fades, and
/// tell a tap, a drag and a long press apart): a tap opens the panel; a drag
/// toward the middle (mostly horizontal) moves the panel out with the finger;
/// a long press picks the puck up, and the finger moves it.
struct KeyPuckGestures: UIViewRepresentable {
    /// Hidden: new touches go to what is under it (one under way goes on).
    var passesTouches: Bool
    /// The panel's side: a drag the other way brings it out.
    var side: KeyPanelSide
    /// A tap: the panel comes out.
    var onTap: () -> Void
    /// The finger's travel (window points) and where it began, from the puck's center.
    var onDrag: (_ translation: CGSize, _ start: CGPoint) -> Void
    /// Where the panel would come to rest at the finger's speed (horizontal travel), the travel, where it began.
    var onEnd: (_ projected: CGFloat, _ translation: CGSize, _ start: CGPoint) -> Void
    var onMove: (_ phase: MovePhase, _ translation: CGSize) -> Void

    enum MovePhase { case began, changed, ended }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        context.coordinator.parent = self
        view.passesTouches = passesTouches
    }

    final class TouchView: UIView {
        var passesTouches = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !passesTouches else { return nil }
            // Round, like the puck.
            let r = min(bounds.width, bounds.height) / 2
            return hypot(point.x - bounds.midX, point.y - bounds.midY) <= r ? self : nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: KeyPuckGestures?
        private let tap = UITapGestureRecognizer()
        private let pan = UIPanGestureRecognizer()
        private let press = UILongPressGestureRecognizer()
        /// Where the dragging finger began, from the puck's center.
        private var start: CGPoint = .zero
        /// Where the finger was when the puck was picked up (window).
        private var pressOrigin: CGPoint = .zero

        func install(on view: UIView) {
            tap.addTarget(self, action: #selector(tapped(_:)))
            pan.addTarget(self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            press.addTarget(self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0.35
            press.allowableMovement = 10
            for g in [tap, pan, press] as [UIGestureRecognizer] {
                g.delegate = self
                view.addGestureRecognizer(g)
            }
        }

        @objc private func tapped(_ g: UITapGestureRecognizer) {
            if g.state == .ended { parent?.onTap() }
        }

        @objc private func panned(_ g: UIPanGestureRecognizer) {
            guard let parent, let view = g.view else { return }
            let t = g.translation(in: nil)
            let travel = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .began:
                let p = g.location(in: view)
                start = CGPoint(x: p.x - t.x - view.bounds.midX, y: p.y - t.y - view.bounds.midY)
                parent.onDrag(travel, start)
            case .changed:
                parent.onDrag(travel, start)
            case .ended:
                parent.onEnd(t.x + g.velocity(in: nil).x * 0.25, travel, start)
            case .cancelled, .failed:
                parent.onEnd(0, travel, start)
            default:
                break
            }
        }

        @objc private func pressed(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: nil)
            switch g.state {
            case .began:
                pressOrigin = p
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                parent?.onMove(.began, .zero)
            case .changed:
                parent?.onMove(.changed, CGSize(width: p.x - pressOrigin.x, height: p.y - pressOrigin.y))
            case .ended, .cancelled, .failed:
                parent?.onMove(.ended, .zero)
            default:
                break
            }
        }

        // A drag brings the panel only toward the middle, mostly horizontally,
        // and not once the puck has been picked up.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan, let parent else { return true }
            if press.state == .began || press.state == .changed { return false }
            let v = pan.velocity(in: nil)
            let out = parent.side == .trailing ? -v.x : v.x
            return out > 0 && out > abs(v.y)
        }
    }
}
