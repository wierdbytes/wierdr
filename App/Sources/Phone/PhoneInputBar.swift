import SwiftUI
import WierdrModel

/// Under the iPhone's terminal while it doesn't have the keyboard: quick keys
/// (Esc, arrows, Return, Tab, 1/2/3, y/n…) that answer an agent without the
/// keyboard, and a compose field with the system keyboard (dictation,
/// autocorrect, any language) whose text goes to the program as one paste,
/// followed by Return. The keyboard button types straight into the terminal
/// instead (with the terminal's own key bar); the bar steps aside meanwhile.
struct PhoneInputBar: View {
    var address: String

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState private var composing: Bool
    @State private var text = ""
    @State private var sent = 0

    var body: some View {
        let session = services.terminalSession(address)
        if session?.hasKeyboardFocus != true {
            VStack(spacing: 0) {
                QuickKeys { key in send(key, session) }
                    .frame(height: verticalSizeClass == .compact ? 38 : 42)
                compose(session)
            }
            .background(theme.chrome.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Hairline().ignoresSafeArea(edges: .horizontal) }
            .sensoryFeedback(.impact(weight: .light), trigger: sent)
            .onAppear { text = controller.drafts[address] ?? "" }
            .onChange(of: text) { _, t in controller.drafts[address] = t.isEmpty ? nil : t }
            .transition(.opacity)
        }
    }

    private func compose(_ session: TerminalSession?) -> some View {
        let empty = text.isEmpty
        return HStack(alignment: .bottom, spacing: 6) {
            Button {
                composing = false
                guard let session else { return controller.toast("Not available in the demo") }
                session.takeKeyboard()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(theme.muted)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Type in the Terminal")

            TextField("Message", text: $text, axis: .vertical)
                .font(.ui(16))
                .foregroundStyle(theme.foreground)
                .tint(theme.accent)
                .lineLimit(1...6)
                .focused($composing)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 40)
                .background(theme.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                .accessibilityLabel("Message to the terminal")

            Button { submit(session, pressReturn: true) } label: {
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
                    Button { submit(session, pressReturn: false) } label: {
                        Label("Insert Without Return", systemImage: "text.insert")
                    }
                }
                Button { text += UIPasteboard.general.string ?? "" } label: {
                    Label("Paste Here", systemImage: "doc.on.clipboard")
                }
                if !empty {
                    Button(role: .destructive) { text = "" } label: { Label("Clear", systemImage: "xmark") }
                }
            }
            .accessibilityLabel(empty ? "Return" : "Send")
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Undoes the keyboard's smart punctuation, which breaks commands and
    /// flags: curly quotes become straight, and an em dash glued to a word
    /// (`—verbose`, typed as `--verbose`) becomes `--` again.
    static func plain(_ s: String) -> String {
        var out = s
        for (from, to) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
                           ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out.replacingOccurrences(of: "\u{2014}(?=[^\\s\u{2014}])", with: "--", options: .regularExpression)
    }

    private func send(_ key: TerminalSession.Key, _ session: TerminalSession?) {
        guard let session else { return controller.toast("Not available in the demo") }
        guard session.acceptsInput else { return controller.toast("The terminal is not connected yet") }
        session.send(key: key)
    }

    /// Text (or, when empty, just Return) to the program.
    private func submit(_ session: TerminalSession?, pressReturn: Bool) {
        guard let session else { return controller.toast("Not available in the demo") }
        guard session.acceptsInput else { return controller.toast("The terminal is not connected yet") }
        let message = Self.plain(text.trimmingCharacters(in: .newlines))
        session.send(text: message, submit: pressReturn)
        text = ""
        sent += 1
        if !message.isEmpty { composing = false }
    }
}

/// The quick keys: one row, scrolls sideways; arrows repeat while held.
private struct QuickKeys: View {
    var send: (TerminalSession.Key) -> Void
    @Environment(\.theme) private var theme

    private struct K: Identifiable {
        var id: String { label }
        var label: String
        var symbol: String?
        var key: TerminalSession.Key
        var repeats = false
        var a11y: String
    }

    private let keys: [K] = [
        K(label: "esc", key: .escape, a11y: "Escape"),
        K(label: "⏎", symbol: "return", key: .enter, a11y: "Return"),
        K(label: "↑", symbol: "arrow.up", key: .up, repeats: true, a11y: "Up"),
        K(label: "↓", symbol: "arrow.down", key: .down, repeats: true, a11y: "Down"),
        K(label: "←", symbol: "arrow.left", key: .left, repeats: true, a11y: "Left"),
        K(label: "→", symbol: "arrow.right", key: .right, repeats: true, a11y: "Right"),
        K(label: "tab", key: .tab, a11y: "Tab"),
        K(label: "⇧tab", key: .backtab, a11y: "Shift Tab"),
        K(label: "1", key: .text("1"), a11y: "1"),
        K(label: "2", key: .text("2"), a11y: "2"),
        K(label: "3", key: .text("3"), a11y: "3"),
        K(label: "y", key: .text("y"), a11y: "y"),
        K(label: "n", key: .text("n"), a11y: "n"),
        K(label: "/", key: .text("/"), a11y: "Slash"),
        K(label: "@", key: .text("@"), a11y: "At"),
        K(label: "!", key: .text("!"), a11y: "Exclamation mark"),
        K(label: "^C", key: .control(0x03), a11y: "Control C"),
        K(label: "^L", key: .control(0x0c), a11y: "Control L"),
        K(label: "^R", key: .control(0x12), a11y: "Control R"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys) { k in
                    Button { send(k.key) } label: {
                        Group {
                            if let symbol = k.symbol {
                                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                            } else {
                                Text(k.label)
                                    .font(k.label.count > 1 ? .ui(13.5, .medium) : .mono(16, .medium))
                            }
                        }
                        .foregroundStyle(theme.foreground)
                        .frame(minWidth: 26)
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(KeyPressStyle())
                    .buttonRepeatBehavior(k.repeats ? .enabled : .disabled)
                    .accessibilityLabel(k.a11y)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
    }
}

/// A key cap that darkens while pressed.
private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
