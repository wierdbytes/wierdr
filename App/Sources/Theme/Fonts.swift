import SwiftUI
import UIKit

/// The bundled fonts: Geist (UI) and JetBrains Mono (terminal, mono text).
/// Both are variable fonts; weights are set through the `wght` axis so every
/// weight the spec uses (400/500/600/700) renders exactly, independent of the
/// named instances the font happens to expose.
enum AppFont {
    static let uiFamily = "Geist"
    static let monoFamily = "JetBrains Mono"

    private static let wghtAxis = 0x7767_6874 // 'wght'
    private static var cache: [String: UIFont] = [:]

    static func uiFont(family: String, size: CGFloat, weight: CGFloat) -> UIFont {
        let key = "\(family)|\(size)|\(weight)"
        if let f = cache[key] { return f }
        var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        descriptor = descriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
        ])
        var font = UIFont(descriptor: descriptor, size: size)
        if font.familyName != family {
            // Not registered (should not happen): fall back to the system font of that weight.
            font = family == monoFamily
                ? .monospacedSystemFont(ofSize: size, weight: .init(rawValue: (weight - 400) / 500))
                : .systemFont(ofSize: size, weight: .init(rawValue: (weight - 400) / 500))
        }
        cache[key] = font
        return font
    }

    /// Logs the registered families once (debug builds) so a missing font is obvious.
    static func checkRegistered() {
        #if DEBUG
        for family in [uiFamily, monoFamily, "Symbols Nerd Font"] {
            let names = UIFont.fontNames(forFamilyName: family)
            print("[fonts] \(family): \(names.isEmpty ? "MISSING" : names.joined(separator: ", "))")
        }
        #endif
    }
}

/// Spec weights (500/600/700). Herdr's desktop renderer draws stems lighter than
/// Core Text, so the axis values are calibrated a little down to match its look.
enum UIWeight: CGFloat {
    case regular = 400, medium = 480, semibold = 560, bold = 660
}

extension Font {
    /// Geist at an exact point size (desktop px = pt).
    static func ui(_ size: CGFloat, _ weight: UIWeight = .regular) -> Font {
        Font(AppFont.uiFont(family: AppFont.uiFamily, size: size, weight: weight.rawValue))
    }

    /// JetBrains Mono at an exact point size.
    static func mono(_ size: CGFloat, _ weight: UIWeight = .regular) -> Font {
        Font(AppFont.uiFont(family: AppFont.monoFamily, size: size, weight: weight.rawValue))
    }
}
