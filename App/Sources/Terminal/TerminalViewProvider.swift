import SwiftUI
import WierdrModel

/// What a pane's terminal view needs to know.
struct TerminalViewContext {
    /// Qualified terminal address (`t5w`, `lf/t1`).
    var address: String
    /// The terminal's current record (title, program, status …), if known.
    var terminal: TerminalInfo?
    /// Whether this pane has the keyboard on this screen (send FOCUS 1/0, become first responder).
    var focused: Bool
    /// Terminal colors of the current theme (fg/bg/cursor/selection/ansi0…15 as hex).
    var palette: TerminalPalette
    /// JetBrains Mono point size (Settings, default 14).
    var fontSize: CGFloat
    /// Content padding inside the pane (14 × 12); the grid is fitted inside it.
    var padding: EdgeInsets
    /// Asks the panel to focus this pane (e.g. the terminal view got a tap).
    var requestFocus: @MainActor () -> Void
}

/// Builds the view that shows a terminal inside a pane card.
///
/// The live implementation (SwiftTerm `TerminalView` fed by a HerdrCore attach
/// stream) plugs in here, e.g.:
///
/// ```swift
/// let live = TerminalViewProvider { ctx in
///     AnyView(LiveTerminal(address: ctx.address, session: session, palette: ctx.palette,
///                          fontSize: ctx.fontSize, focused: ctx.focused)   // a UIViewRepresentable
///         .padding(ctx.padding))
/// }
/// ```
///
/// The view is keyed by `address` (SwiftUI identity), so one pane keeps one
/// view across focus/theme changes; update it in `updateUIView`.
struct TerminalViewProvider {
    var makeView: @MainActor (TerminalViewContext) -> AnyView

    /// Draws a static, convincing terminal (demo mode, previews, screenshots).
    static let demo = TerminalViewProvider { ctx in AnyView(DemoTerminalView(context: ctx)) }
}

private struct TerminalViewProviderKey: EnvironmentKey {
    static let defaultValue = TerminalViewProvider.demo
}

extension EnvironmentValues {
    var terminalViewProvider: TerminalViewProvider {
        get { self[TerminalViewProviderKey.self] }
        set { self[TerminalViewProviderKey.self] = newValue }
    }
}
