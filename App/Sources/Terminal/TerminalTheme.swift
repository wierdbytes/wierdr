import UIKit
import CoreText
import SwiftTerm
import HerdrCore

/// Colors of a terminal: what the emulator paints with and what the core is
/// told (`Display` facts) so it answers OSC 10/11/12 the way we look.
/// Values are `#rrggbb`.
struct TerminalTheme: Hashable, Sendable {
    var name: String
    var foreground: String
    var background: String
    var cursor: String
    var selection: String
    /// ansi0 ... ansi15.
    var ansi: [String]

    /// Herdr's `atom-one-dark` (the user's dark theme).
    static let atomOneDark = TerminalTheme(
        name: "atom-one-dark",
        foreground: "#abb2bf", background: "#21252b", cursor: "#abb2bf", selection: "#323844",
        ansi: ["#454c59", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
               "#767676", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf"])

    /// Herdr's `paper` (the default light theme).
    static let paper = TerminalTheme(
        name: "paper",
        foreground: "#25272c", background: "#ffffff", cursor: "#25272c", selection: "#cfdcf5",
        ansi: ["#25272c", "#c62a2a", "#1a7f37", "#8f5d00", "#1f62d0", "#7a45c8", "#0f6f74", "#5f6068",
               "#7b7e87", "#d1242f", "#1f883d", "#9a6700", "#0969da", "#8250df", "#1b7c83", "#111214"])

    static func `for`(dark: Bool) -> TerminalTheme { dark ? .atomOneDark : .paper }

    var isDark: Bool {
        let (r, g, b) = Self.rgb(background)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b <= 0.5
    }

    var foregroundColor: UIColor { Self.uiColor(foreground) }
    var backgroundColor: UIColor { Self.uiColor(background) }
    var cursorColor: UIColor { Self.uiColor(cursor) }
    var selectionColor: UIColor { Self.uiColor(selection) }
    var palette: [SwiftTerm.Color] { ansi.map(Self.termColor) }

    /// Key bar colors, derived like Herdr's panel colors.
    var keyFill: UIColor { isDark ? UIColor(white: 1, alpha: 0.09) : UIColor(white: 0, alpha: 0.06) }
    var keyFillActive: UIColor { Self.uiColor(ansi[4]).withAlphaComponent(isDark ? 0.45 : 0.30) }
    var keyBarBackground: UIColor { Self.uiColor(isDark ? "#1c1f24" : "#f1f1ee") }
    var keyText: UIColor { isDark ? Self.uiColor("#eeeeef") : Self.uiColor("#1b1b1e") }

    func display(cellPixels: Display.CellSize?) -> Display {
        Display(fg: foreground, bg: background, cursor: cursor, cell: cellPixels)
    }

    // MARK: Hex

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count >= 6, let v = UInt32(s.prefix(6), radix: 16) else { return (0, 0, 0) }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    static func uiColor(_ hex: String) -> UIColor {
        let (r, g, b) = rgb(hex)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    static func termColor(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = rgb(hex)
        return SwiftTerm.Color(red8: UInt16((r * 255).rounded()), green8: UInt16((g * 255).rounded()),
                               blue8: UInt16((b * 255).rounded()))
    }
}

/// The terminal fonts: JetBrains Mono (variable; bold = wght 700) with
/// Symbols Nerd Font as the fallback for Nerd Font icons.
enum TerminalFonts {
    /// 14 pt as the desktop; 12 pt on iPhone (about 57 columns in portrait).
    @MainActor static var defaultSize: CGFloat { Device.isPhone ? 12 : 14 }
    /// The Settings key for the size (`@AppStorage`), per device.
    static let sizeKey = "terminalFontSize"
    /// Sizes Settings and pinch allow.
    static let sizeRange: ClosedRange<CGFloat> = 9...24
    private static let weightAxis = 0x7767_6874 // 'wght'

    struct Set {
        var normal: UIFont
        var bold: UIFont
        var italic: UIFont
        var boldItalic: UIFont
    }

    static func make(size: CGFloat) -> Set {
        let regular = font("JetBrainsMono-Regular", weight: 400, size: size)
        let bold = font("JetBrainsMono-Regular", weight: 700, size: size)
        let italic = font("JetBrainsMono-Italic", weight: 400, size: size)
        let boldItalic = font("JetBrainsMono-Italic", weight: 700, size: size)
        return Set(normal: regular, bold: bold, italic: italic, boldItalic: boldItalic)
    }

    private static func font(_ postScriptName: String, weight: Int, size: CGFloat) -> UIFont {
        guard let base = UIFont(name: postScriptName, size: size) else {
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight >= 700 ? .bold : .regular)
        }
        if weight == 400 { return base }
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = base.fontDescriptor.addingAttributes([key: [weightAxis: weight]])
        return UIFont(descriptor: descriptor, size: size)
    }
}

/// Draws Nerd Font icons (private-use code points) that JetBrains Mono lacks
/// with the bundled Symbols Nerd Font. SwiftTerm asks only after the terminal
/// font was found to lack the glyph.
final class NerdFontFallback: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared = NerdFontFallback()

    let generation: UInt64 = 1
    private let lock = NSLock()
    private var fonts: [CGFloat: CTFont] = [:]
    private let available: Bool

    private init() {
        available = UIFont(name: "SymbolsNF", size: 12) != nil
    }

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        let v = scalar.value
        // Powerline separators fill their cell; everything else is an icon.
        if (0xE0B0...0xE0D7).contains(v) { return TerminalGlyphPlacementPolicy(placement: .stretch) }
        if (0xE000...0xF8FF).contains(v) || (0xF0000...0xFFFFD).contains(v)
            || (0x23FB...0x23FE).contains(v) || v == 0x2B58 {
            return TerminalGlyphPlacementPolicy(placement: .icon)
        }
        return nil
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        guard available else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let f = fonts[size] { return f }
        let f = CTFontCreateWithName("SymbolsNF" as CFString, size, nil)
        fonts[size] = f
        return f
    }
}
