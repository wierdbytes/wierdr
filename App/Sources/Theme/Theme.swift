import SwiftUI
import WierdrModel

/// Herdr's resolved theme colors (docs/research/ui-spec.md §0, herdr-app-model.md §9).
/// The user's layout uses `{light: "paper", dark: "atom-one-dark"}`; we follow the
/// system appearance (or the Settings override).
struct Theme: Equatable {
    var isDark: Bool

    var canvas: Color
    var chrome: Color
    var background: Color
    var surface: Color
    var raised: Color
    var popover: Color
    var hover: Color
    var selected: Color
    var border: Color
    var input: Color
    var foreground: Color
    var muted: Color
    var dim: Color
    var accent: Color
    var accentForeground: Color
    var working: Color
    var blocked: Color
    var done: Color
    var idle: Color

    /// The terminal palette as hex strings (for the terminal view: SwiftTerm wants raw colors).
    var terminal: TerminalPalette

    /// ansi0…15.
    var ansi: [Color] { terminal.ansi.map { Color(hex: $0) } }
    func ansi(_ i: Int) -> Color { Color(hex: terminal.ansi[i]) }
    var terminalForeground: Color { Color(hex: terminal.foreground) }
    var terminalBackground: Color { Color(hex: terminal.background) }
    var terminalCursor: Color { Color(hex: terminal.cursor) }
    var terminalSelection: Color { Color(hex: terminal.selection) }

    static func resolve(_ scheme: ColorScheme) -> Theme { scheme == .dark ? .atomOneDark : .paper }

    // MARK: Presets

    static let atomOneDark = Theme(
        isDark: true,
        canvas: Color(hex: "#1c1f24"), chrome: Color(hex: "#16191d"),
        background: Color(hex: "#21252b"), surface: Color(hex: "#21252b"),
        raised: Color(hex: "#35393e"), popover: Color(hex: "#2e3238"),
        hover: Color(hex: "#ffffff0e"), selected: Color(hex: "#ffffff17"),
        border: Color(hex: "#ffffff18"), input: Color(hex: "#ffffff24"),
        foreground: Color(hex: "#eeeeef"), muted: Color(hex: "#9c9ea1"), dim: Color(hex: "#6f7175"),
        accent: Color(hex: "#61afef"), accentForeground: Color(hex: "#21252b"),
        working: Color(hex: "#e5c07b"), blocked: Color(hex: "#e06c75"),
        done: Color(hex: "#98c379"), idle: Color(hex: "#6f7175"),
        terminal: TerminalPalette(
            foreground: "#abb2bf", background: "#21252b", cursor: "#abb2bf", selection: "#323844",
            ansi: ["#454c59", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                   "#767676", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf"]))

    static let paper = Theme(
        isDark: false,
        canvas: Color(hex: "#fafaf9"), chrome: Color(hex: "#f1f1ee"),
        background: Color(hex: "#ffffff"), surface: Color(hex: "#ffffff"),
        raised: Color(hex: "#f6f6f6"), popover: Color(hex: "#ffffff"),
        hover: Color(hex: "#0000000c"), selected: Color(hex: "#00000012"),
        border: Color(hex: "#00000017"), input: Color(hex: "#00000026"),
        foreground: Color(hex: "#1b1b1e"), muted: Color(hex: "#69696b"), dim: Color(hex: "#969698"),
        accent: Color(hex: "#1f62d0"), accentForeground: Color(hex: "#ffffff"),
        working: Color(hex: "#9a6700"), blocked: Color(hex: "#c93c2c"),
        done: Color(hex: "#1a7f37"), idle: Color(hex: "#a8a8aa"),
        terminal: TerminalPalette(
            foreground: "#25272c", background: "#ffffff", cursor: "#25272c", selection: "#cfdcf5",
            ansi: ["#25272c", "#c62a2a", "#1a7f37", "#8f5d00", "#1f62d0", "#7a45c8", "#0f6f74", "#5f6068",
                   "#7b7e87", "#d1242f", "#1f883d", "#9a6700", "#0969da", "#8250df", "#1b7c83", "#111214"]))

    // MARK: Hard-coded mod colors (§0)

    /// Space avatar fills, palette order ansi6, ansi3, ansi4, ansi5, ansi2, ansi1.
    static let avatarPalette = ["#22a99a", "#e3814f", "#5b8def", "#8b7cf6", "#3fae6a", "#d9649a"]

    /// Status color (marks, tints).
    func color(for status: AgentStatus) -> Color {
        switch status {
        case .working: return working
        case .blocked: return blocked
        case .done: return done
        case .idle: return idle
        }
    }

    /// `@effort` colors: pi-statusline Tokyo Night on dark, the named ANSI colors on light.
    func effortColor(_ word: String) -> Color {
        switch word.lowercased() {
        case "off": return isDark ? Color(hex: "#565f89") : dim
        case "minimal": return isDark ? Color(hex: "#bb9af7") : ansi(5)
        case "low": return isDark ? Color(hex: "#7aa2f7") : ansi(4)
        case "medium": return isDark ? Color(hex: "#7dcfff") : ansi(6)
        case "high": return isDark ? Color(hex: "#ff9e64") : ansi(3)
        case "xhigh": return isDark ? Color(hex: "#f7768e") : ansi(1)
        case "max": return isDark ? Color(hex: "#f7768e") : ansi(1)
        default: return muted
        }
    }

    /// `max` effort: a per-letter gradient.
    var maxEffortGradient: [Color] {
        isDark ? ["#ff9e64", "#f7768e", "#d787af", "#bb9af7"].map { Color(hex: $0) }
               : [ansi(3), ansi(1), ansi(5), ansi(5)]
    }

    var green: Color { isDark ? Color(hex: "#9ece6a") : ansi(2) }
    var yellow: Color { isDark ? Color(hex: "#e0af68") : ansi(3) }
    var red: Color { isDark ? Color(hex: "#f7768e") : ansi(1) }

    /// Context bar fill by floor(percent): ≤60 green, ≤80 yellow, else red.
    func contextBarColor(_ fraction: Double) -> Color {
        let pct = Int((fraction * 100).rounded(.down))
        if pct <= 60 { return green }
        if pct <= 80 { return yellow }
        return red
    }

    /// Context number color by prompt cache: warm green, ≤30 s left yellow, expired/unknown muted.
    func contextNumberColor(cacheUntil: Date?, now: Date) -> Color {
        guard let cacheUntil else { return muted }
        let left = cacheUntil.timeIntervalSince(now)
        if left <= 0 { return muted }
        if left <= 30 { return yellow }
        return green
    }
}

/// Terminal colors for a terminal emulator view.
struct TerminalPalette: Equatable, Sendable {
    var foreground: String
    var background: String
    var cursor: String
    var selection: String
    /// ansi0…15, `#rrggbb`.
    var ansi: [String]
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.atomOneDark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Resolves the theme from the current color scheme and puts it in the environment.
struct ThemeResolver: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.theme, Theme.resolve(scheme))
    }
}

extension View {
    func resolvingTheme() -> some View { modifier(ThemeResolver()) }
}

// MARK: - Hex colors

extension Color {
    /// `#rgb`, `#rrggbb` or `#rrggbbaa`.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xff) / 255; g = Double((v >> 16) & 0xff) / 255
            b = Double((v >> 8) & 0xff) / 255; a = Double(v & 0xff) / 255
        } else {
            r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255
            b = Double(v & 0xff) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Appearance override (Settings)

enum AppearanceOverride: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
