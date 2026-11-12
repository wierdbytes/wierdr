import SwiftUI
import WierdrModel

/// A sub-agent without a pane, looked at over the window (the desktop's peek:
/// `wierd-agents`' peek bar for a sub-agent). A card of 82% of the window: a
/// 38-pt bar (its status, its provider or program, what it's on, `from <its
/// parent>`, Keep ↵ and ✕ esc) over its live terminal, which takes typing like
/// any pane's (a pointer's click; the puck, which stays where it is over the
/// window, `KeyLayerHost`, brings its keys and keyboards to it while it's up).
/// Keep makes it a tab right after its parent's; Close, a tap beside the card
/// or esc leave it running. esc and Return are the bar's only while the
/// terminal doesn't have the keyboard (then they're the program's).
struct SubAgentPeek: View {
    let address: String

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @Environment(\.terminalViewProvider) private var provider
    @Environment(\.services) private var services
    @AppStorage(TerminalFonts.sizeKey) private var fontSize = Double(TerminalFonts.defaultSize)
    /// The terminal takes the keyboard only when asked (a click, the puck's
    /// keyboards): opening the peek doesn't steal esc from the bar.
    @State private var focused = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(theme.isDark ? 0.45 : 0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.closePeek() }
                    .accessibilityLabel("Close")
                    .accessibilityAddTraits(.isButton)
                card
                    .frame(width: (geo.size.width * 0.82).rounded(), height: (geo.size.height * 0.82).rounded())
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The whole window, the status bar's strip too (the keyboard is `keyboardCoverPadding`'s).
        .ignoresSafeArea(.container)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { controller.closePeek() }
    }

    private var card: some View {
        let terminal = controller.workspace.terminal(address)
        return VStack(spacing: 0) {
            PeekBar(address: address, terminal: terminal, terminalHasKeyboard: terminalHasKeyboard)
            Color.clear
                .overlay {
                    provider.makeView(TerminalViewContext(
                        address: address, terminal: terminal, focused: focused, palette: theme.terminal,
                        fontSize: fontSize, padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14),
                        requestFocus: { focused = true }))
                    .id(address)
                }
                .clipped()
            if controller.composing == address {
                PhoneComposeBar(address: address, placeholder: "Message to \(Format.kidTitle(terminal ?? TerminalInfo(address: address)))")
                    .id(address)
            }
        }
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.2), radius: 30, y: 10)
        .onChange(of: terminalHasKeyboard) { _, has in if has { focused = true } }
    }

    private var terminalHasKeyboard: Bool {
        services.terminalSession(address)?.hasKeyboardFocus == true || controller.composing == address
    }
}

/// The peek's bar: status, provider or program, what it's on, `from <parent>`,
/// Keep and Close. A sub-agent never reads done here (it reports to its parent).
private struct PeekBar: View {
    let address: String
    let terminal: TerminalInfo?
    let terminalHasKeyboard: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    var body: some View {
        let ws = controller.workspace
        let parent = ws.terminal(terminal?.parent)
        let target = controller.keepTarget(for: address)
        HStack(spacing: 9) {
            StatusMark(status: terminal?.kidStatus)
                .frame(width: 18)
            if let asset = terminal?.meta?.providerAsset {
                Icon(asset, size: 13, color: theme.muted)
            } else if let program = terminal?.program {
                ProgramIcon(program: program, size: 14, color: theme.muted)
            }
            Text(terminal.map { Format.kidTitle($0) } ?? address)
                .font(.ui(12.5, .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
            if let parent {
                Text("from \(Format.kidTitle(parent))")
                    .font(.ui(12.5))
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            PeekButton(label: "Keep", key: "↵", strong: true, hint: keepHint(target, ws)) {
                controller.keep(address)
            }
            .keyboardShortcut(terminalHasKeyboard ? nil : KeyboardShortcut(.return, modifiers: []))
            .disabled(target == nil)
            PeekButton(label: "✕", key: "esc", strong: false, hint: "Close (it keeps running)") {
                controller.closePeek()
            }
            .keyboardShortcut(terminalHasKeyboard ? nil : KeyboardShortcut(.escape, modifiers: []))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
    }

    private func keepHint(_ target: (spaceID: String, after: String?, parent: String?)?, _ ws: Workspace) -> String {
        if let parent = target?.parent, let t = ws.terminal(parent) {
            return "Keep it in a tab next to \(Format.agentTitle(t, tab: ws.pane(showing: parent)?.tab))"
        }
        if let space = ws.space(target?.spaceID) { return "Keep it as a tab in \(space.displayName)" }
        return "Keep it as a tab"
    }
}

private struct PeekButton: View {
    var label: String
    var key: String
    var strong: Bool
    var hint: String
    var action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.ui(12.5, strong ? .medium : .regular))
                Text(key).font(.ui(10)).opacity(0.75)
            }
            .foregroundStyle(strong ? theme.accentForeground : (hovering ? theme.foreground : theme.muted))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(strong ? theme.accent.opacity(hovering ? 0.9 : 1) : (hovering ? theme.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .hoverEffect(.highlight)
        .accessibilityLabel(strong ? "Keep" : "Close")
        .accessibilityHint(hint)
    }
}
