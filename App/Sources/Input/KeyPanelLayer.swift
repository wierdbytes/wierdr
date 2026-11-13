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
    func keyPanel(address: String?, covered: Bool, state: Binding<KeyPanelState>) -> some View {
        modifier(KeyPanelLayer(address: address, covered: covered, state: state))
    }
}

/// The key panel (`PhoneKeyPanel`) over a terminal area, and how it and the keyboards come.
///
/// A swipe to the left anywhere on a terminal pulls the panel out at the right
/// with the finger (on the iPad its pane gets the focus). Its keys come to
/// rest at the height the swipe began, under the thumb (⏎ there as it opens).
/// VoiceOver: the terminal's action Keys.
///
/// The terminal's own keyboard comes with a double tap on the terminal
/// (`WierdrTerminalView`); the message field's, with a tap on the field under
/// it (`ComposerBar`). Taps on the terminal are clicks for the program and its
/// pans scroll it, with a keyboard up too, and beside the panel while it is
/// out; a double tap brings the terminal's keyboard or hides the one that is
/// up (the message field's: the field goes down to one line). Only a swipe
/// right puts the panel back. While the area is `covered` (the list, the
/// sidebar overlay), the panel and the keyboards go and the gestures rest.
struct KeyPanelLayer: ViewModifier {
    /// The focused terminal (nil: no terminal here, no keys).
    var address: String?
    var covered: Bool
    @Binding var state: KeyPanelState

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    /// The finger's horizontal travel while it moves the panel.
    @State private var drag: CGFloat?
    /// The terminal area in global coordinates.
    @State private var area: CGRect = .zero
    /// The window y the last swipe that pulled the panel out began at (its keys rest there).
    @State private var swipeY: CGFloat?

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
                    onEnd: { projected, _ in finishDrag(projected: projected) },
                    // The keyboard (and the message field), at once; the panel stays.
                    onDoubleTap: { hideKeyboards() }
                )
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { area = $0 }
            .overlay(alignment: .trailing) {
                if let address { panel(address) }
            }
            .onChange(of: covered) { _, covered in
                guard covered else { return }
                setPanel(open: false)
                hideKeyboards()
            }
            .onChange(of: address, initial: true) { old, new in
                if old != new { setActions(on: old, []) }
                setActions(on: new, [
                    UIAccessibilityCustomAction(name: "Keys") { _ in setPanel(open: true); return true },
                ])
            }
    }

    /// VoiceOver's way to the panel: an action of the terminal.
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
        return PhoneKeyPanel(address: address, shown: progress > 0, restY: swipeY ?? area.midY,
                             close: { setPanel(open: false) })
            .id(address)
            .offset(x: (1 - progress) * PhoneKeyPanel.width)
            .allowsHitTesting(progress > 0)
            .accessibilityHidden(progress == 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .clipped()
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

    /// The finger moved the panel; a swipe that pulls it out puts its keys at the swipe's height.
    private func moved(_ x: CGFloat, at p: CGPoint) {
        if drag == nil, !state.open { swipeY = area.minY + p.y }
        drag = x
    }
}
