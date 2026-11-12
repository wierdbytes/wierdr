import SwiftUI
import UIKit
import WierdrModel

/// The message field, opened by Type in the key panel (or the keyboard icons
/// of the swipe or the puck): right above the system keyboard (dictation,
/// autocorrect, any language), a field and a send button. Under the terminal
/// on the iPhone; across the iPad's panel, in the status bar's place, for the
/// focused pane. The text goes to the program as one paste (bracketed when it
/// asked, so line breaks stay in the message), then Return; an empty field
/// sends just Return. Opened also by a tap on the terminal's right half. It closes
/// at once, with its keyboard and no animation (send, Hide in the key panel,
/// a tap on the terminal); its text stays as the terminal's draft. Photo, Image and Paste in the key panel
/// add to the message while it is open.
struct PhoneComposeBar: View {
    var address: String
    /// The iPad names the pane it goes to (there may be several on screen).
    var placeholder = "Message"

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var sent = 0

    var body: some View {
        let text = Binding(
            get: { controller.drafts[address] ?? "" },
            set: { controller.drafts[address] = $0.isEmpty ? nil : $0 }
        )
        let empty = text.wrappedValue.isEmpty
        // Prose for agents (capitals, corrections); commands for shells (as typed).
        let prose = controller.workspace.terminal(address)?.isAgent ?? true
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: text, axis: .vertical)
                .font(.ui(16))
                .foregroundStyle(theme.foreground)
                .tint(theme.accent)
                .lineLimit(1...6)
                .textInputAutocapitalization(prose ? .sentences : .never)
                .autocorrectionDisabled(!prose)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 40)
                .background(theme.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                .accessibilityLabel("Message to the terminal")

            Button { submit(pressReturn: true) } label: {
                Image(systemName: empty ? "return" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(empty ? theme.foreground : theme.accentForeground)
                    .frame(width: 36, height: 36)
                    .background(empty ? theme.raised : theme.accent, in: Circle())
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !empty {
                    Button { submit(pressReturn: false) } label: {
                        Label("Insert Without Return", systemImage: "text.insert")
                    }
                    Button(role: .destructive) { text.wrappedValue = "" } label: { Label("Clear", systemImage: "xmark") }
                }
            }
            .accessibilityLabel(empty ? "Return" : "Send")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(theme.chrome)
        .overlay(alignment: .top) { Hairline().ignoresSafeArea(edges: .horizontal) }
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .onAppear { focused = true }
        .onChange(of: controller.composing) { _, now in focused = now == address }
        // The keyboard went (Hide, a tap on the terminal, swiped away): the field goes with it.
        .onChange(of: focused) { _, on in
            if on, !Device.isPhone { ComposeAccessory.attachSoon() }
            if !on, controller.composing == address { controller.composing = nil }
        }
    }

    /// Text (or, when empty, just Return) to the program.
    private func submit(pressReturn: Bool) {
        guard let session = services.terminalSession(address) else {
            return controller.toast(controller.isDemo ? "Not available in the demo" : "The terminal is not connected yet")
        }
        guard session.acceptsInput else { return controller.toast("The terminal is not connected yet") }
        let prose = controller.workspace.terminal(address)?.isAgent ?? true
        let message = Self.plain((controller.drafts[address] ?? "").trimmingCharacters(in: .newlines), prose: prose)
        session.send(text: message, submit: pressReturn)
        controller.drafts[address] = nil
        sent += 1
        // Sent: the keyboard goes, to watch the answer.
        if !message.isEmpty { controller.closeCompose() }
    }

    /// Undoes the keyboard's smart punctuation, which breaks commands and
    /// flags: curly quotes become straight. For a shell (`prose == false`)
    /// every em/en dash becomes `--` and «» become `"`; for an agent only an
    /// em dash glued to a word (`—verbose`, typed as `--verbose`) does, so
    /// prose keeps its dashes (`1–2`, `a — b`) and guillemets.
    static func plain(_ s: String, prose: Bool) -> String {
        var out = s
        var pairs = [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
                     ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'")]
        if !prose { pairs += [("\u{00AB}", "\""), ("\u{00BB}", "\""), ("\u{2014}", "--"), ("\u{2013}", "--")] }
        for (from, to) in pairs { out = out.replacingOccurrences(of: from, with: to) }
        return out.replacingOccurrences(of: "\u{2014}(?=[^\\s\u{2014}])", with: "--", options: .regularExpression)
    }
}

/// iPad: the message field's keyboard carries an empty, 1-pt input accessory,
/// so `KeyboardCover` can tell where the keyboard begins (the same way as with
/// the terminal's key bar: above a docked keyboard, at the bottom under a
/// floating one). SwiftUI's keyboard safe area is off there; see `KeyboardCover`.
@MainActor
enum ComposeAccessory {
    private static weak var host: UIResponder?
    private static weak var accessory: UIView?

    /// The accessory and the window of the field carrying it, while that field has the keyboard.
    static var active: (bar: UIView, window: UIWindow)? {
        guard let host = host as? UIView, host.isFirstResponder, let window = host.window,
              let accessory, accessory.window != nil else { return nil }
        return (accessory, window)
    }

    /// Hangs it on the text field that has the keyboard, now and again a moment
    /// later (SwiftUI may make the field first responder after reporting focus).
    static func attachSoon() {
        attach()
        DispatchQueue.main.async { attach() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { attach() }
    }

    private static func attach() {
        guard let responder = UIResponder.wierdrFirstResponder else { return }
        if responder === host, accessory != nil { return }
        let bar = EmptyAccessory()
        if let field = responder as? UITextView {
            field.inputAccessoryView = bar
            field.reloadInputViews()
        } else if let field = responder as? UITextField {
            field.inputAccessoryView = bar
            field.reloadInputViews()
        } else {
            return
        }
        host = responder
        accessory = bar
    }

    private final class EmptyAccessory: UIView {
        override init(frame: CGRect) {
            super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            autoresizingMask = .flexibleWidth
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 1) }
    }
}

extension UIResponder {
    private static weak var reported: UIResponder?

    /// What has the keyboard now (nil: nothing).
    static var wierdrFirstResponder: UIResponder? {
        reported = nil
        UIApplication.shared.sendAction(#selector(wierdrReportFirstResponder), to: nil, from: nil, for: nil)
        return reported
    }

    @objc private func wierdrReportFirstResponder() { UIResponder.reported = self }
}

extension WorkspaceController {
    /// Closes the message field at once: its keyboard goes without
    /// sliding, the field without a transition (its text stays as the draft).
    func closeCompose() {
        guard composing != nil else { return }
        UIView.performWithoutAnimation {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { composing = nil }
    }
}
