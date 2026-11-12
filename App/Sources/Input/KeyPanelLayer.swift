import SwiftUI
import UIKit

/// The key panel as the views around it see it: out or not.
struct KeyPanelState: Equatable {
    var open = false

    /// Room it takes at the trailing side while it is out (for toasts beside it).
    var trailingInset: CGFloat { open ? PhoneKeyPanel.width : 0 }
}

extension View {
    /// The key panel over this terminal area and the ways it and the keyboards come (`KeyPanelLayer`).
    func keyPanel(address: String?, covered: Bool, thumbY: CGFloat = 0, state: Binding<KeyPanelState>) -> some View {
        modifier(KeyPanelLayer(address: address, covered: covered, thumbY: thumbY, state: state))
    }
}

/// The key panel (`PhoneKeyPanel`) over a terminal area, and how it and the keyboards come.
///
/// A swipe to the left anywhere on a terminal pulls the panel out at the right
/// with the finger (on the iPad its pane gets the focus). Its keys come to
/// rest: on the iPhone a third of the screen up from its bottom; on the iPad
/// at the height the swipe began, under the thumb (⏎ there as it opens).
/// VoiceOver: the terminal's actions Keys and Write a Message.
///
/// While a swipe that began with the panel hidden is under way, the message
/// field's icon beside the panel, below the finger; let go on it and the field
/// comes (the panel goes). The terminal's own keyboard comes with a double tap
/// on the terminal (`WierdrTerminalView`).
/// Taps on the terminal are clicks for the program and its pans scroll it, with
/// a keyboard up too; a double tap hides the keyboard (the message field with
/// it); with the panel out, a tap beside it puts the panel back (a double tap
/// there brings the terminal's keyboard; the panel stays), and so does a swipe
/// right. While the area is `covered` (the list, the sidebar overlay), the
/// panel and the keyboards go and the gestures rest.
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
    /// The terminal area in global coordinates.
    @State private var area: CGRect = .zero
    /// A swipe that pulls the panel out is under way: where it began (the message icon sits below).
    @State private var pickerStart: CGPoint?
    /// The finger is on the message icon.
    @State private var overMessage = false
    /// iPad: the window y the last swipe that pulled the panel out began at (its keys rest there).
    @State private var swipeY: CGFloat?

    /// iPad (a narrow window too): the keys come to rest where the swipe began, ⏎ there as the panel opens.
    private var restsAtSwipe: Bool { !Device.isPhone }

    func body(content: Content) -> some View {
        let enabled = address != nil && !covered
        content
            .background {
                // Behind the terminal, its size: where the panel's gestures start.
                PhoneKeyPanelGestures(
                    enabled: enabled,
                    isOpen: state.open,
                    keyboardUp: keyboardUp,
                    onDrag: { x, p in moved(x, at: p) },
                    onEnd: { projected, p in released(projected: projected, at: p) },
                    onTap: { setPanel(open: false) },
                    // The keyboard (and the message field), at once; the panel stays.
                    onDoubleTap: { hideKeyboards() }
                )
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { area = $0 }
            .overlay(alignment: .trailing) {
                if let address { panel(address) }
            }
            .overlay {
                if let start = pickerStart {
                    MessagePickerIcon(center: messageIconCenter(start), lit: overMessage)
                }
            }
            .sensoryFeedback(.selection, trigger: overMessage)
            .onChange(of: covered) { _, covered in
                guard covered else { return }
                setPanel(open: false)
                hideKeyboards()
            }
            .onChange(of: address, initial: true) { old, new in
                if old != new { setActions(on: old, []) }
                setActions(on: new, [
                    UIAccessibilityCustomAction(name: "Keys") { _ in setPanel(open: true); return true },
                    UIAccessibilityCustomAction(name: "Write a Message") { _ in writeMessage(); return true },
                ])
            }
    }

    /// VoiceOver's way to the panel and the message field: actions of the terminal.
    private func setActions(on address: String?, _ actions: [UIAccessibilityCustomAction]) {
        guard let address else { return }
        services.terminalSession(address)?.terminalView.appActions = actions
    }

    // MARK: Keyboards

    /// The terminal has the keyboard, or the message field is open: a finger's
    /// double tap on the terminal hides it (a pointer's doesn't, see `PhoneKeyPanelGestures`).
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
        // Travel to the left brings it out, to the right puts it back.
        return state.open ? 1 - min(max(d, 0), w) / w : min(max(-d, 0), w) / w
    }

    /// Always there while the terminal is (so it slides both ways and an
    /// upload goes on), just past the area's right side while hidden.
    private func panel(_ address: String) -> some View {
        let progress = progress
        return PhoneKeyPanel(address: address, shown: progress > 0, restY: restY, opensAtRest: restsAtSwipe,
                             close: { setPanel(open: false) })
            .id(address)
            .offset(x: (1 - progress) * PhoneKeyPanel.width)
            .allowsHitTesting(progress > 0)
            .accessibilityHidden(progress == 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .clipped()
    }

    /// Where the keys come to rest (window y): on the iPad where the swipe
    /// began (else the area's middle), on the iPhone `thumbY`.
    private var restY: CGFloat {
        restsAtSwipe ? swipeY ?? area.midY : thumbY
    }

    private func setPanel(open: Bool) {
        withAnimation(.snappy(duration: 0.25)) {
            state.open = open
            drag = nil
        }
    }

    private func finishDrag(projected: CGFloat) {
        let threshold = PhoneKeyPanel.width * 0.4
        setPanel(open: state.open ? projected < threshold : -projected > threshold)
    }

    // MARK: Swipe

    /// The finger moved the panel. A move that began with it hidden shows the message icon.
    private func moved(_ x: CGFloat, at p: CGPoint) {
        if drag == nil, !state.open {
            pickerStart = p
            swipeY = area.minY + p.y
        }
        drag = x
        if let start = pickerStart { overMessage = onMessageIcon(p, start: start) }
    }

    /// Let go on the icon: the message field (the panel goes); elsewhere: the panel as usual.
    private func released(projected: CGFloat, at p: CGPoint) {
        let message = pickerStart.map { onMessageIcon(p, start: $0) } ?? false
        pickerStart = nil
        overMessage = false
        guard message else { return finishDrag(projected: projected) }
        writeMessage()
    }

    /// The message field comes (the panel goes).
    private func writeMessage() {
        guard let address else { return }
        setPanel(open: false)
        controller.composing = address
    }

    /// Beside the panel, below the swipe's line (in the area), as far from where
    /// the swipe began as the panel is wide and a bit: a short move on to reach it.
    private func messageIconCenter(_ start: CGPoint) -> CGPoint {
        let w = area.width, h = area.height
        let size = MessagePickerIcon.size
        let travel = PhoneKeyPanel.width + size / 2 + 14
        let r = size / 2 + 6
        let x = max(r, min(start.x - travel, w - PhoneKeyPanel.width - r))
        let gap = size / 2 + 26
        return CGPoint(x: x, y: min(max(start.y + gap, r), max(r, h - r)))
    }

    private func onMessageIcon(_ p: CGPoint, start: CGPoint) -> Bool {
        let c = messageIconCenter(start)
        return hypot(c.x - p.x, c.y - p.y) <= MessagePickerIcon.size / 2 + 10
    }
}

// MARK: - Message icon

/// The message field's icon, shown beside the key panel (below the finger)
/// while a swipe that pulls the panel out is under way; it lights up under
/// the finger. Only a picture: the swipe does the picking.
struct MessagePickerIcon: View {
    var center: CGPoint
    var lit: Bool

    static let size: CGFloat = 58

    @Environment(\.theme) private var theme

    var body: some View {
        icon
            .position(center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var icon: some View {
        let on = lit
        return VStack(spacing: 2) {
            Image(systemName: "text.bubble")
                .font(.system(size: 20, weight: .semibold))
            Text("Message")
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
