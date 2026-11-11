import SwiftUI

/// A small icon button in Herdr's style: square, rounded, `muted`/`dim` icon,
/// pointer hover → `hover` background + `foreground` icon. Native pointer
/// shape (highlight) on iPad.
struct ChromeIconButton: View {
    var icon: String
    var iconSize: CGFloat = 15
    var frame: CGFloat = 26
    var radius: CGFloat = 6
    var color: Color? = nil
    var hoverBackground: Color? = nil
    var label: String
    var action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: iconSize, color: hovering ? theme.foreground : (color ?? theme.muted))
                .frame(width: frame, height: frame)
                .background(hovering ? (hoverBackground ?? theme.hover) : .clear,
                            in: RoundedRectangle(cornerRadius: radius))
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: radius))
                // A full-height, slightly wider target so neighbouring buttons'
                // touch areas meet instead of the topmost one winning the overlap.
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
                .contentShape(.interaction, Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -2)
        .padding(.vertical, -6)
        .onHover { hovering = $0 }
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}

/// A 1-pt line in the theme's border color.
struct Hairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.border)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// A press feedback style that keeps custom backgrounds (dims a little while pressed).
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Keeps a bar's leading content clear of the iPadOS 26 window controls
/// (the "traffic lights" of a windowed app), which sit in the top-leading
/// corner of the window when the navigation bar is hidden.
struct WindowControlsClearance: ViewModifier {
    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, inset)
            .onGeometryChange(for: CGFloat.self) { proxy in
                if #available(iOS 26.0, *) {
                    return proxy.containerCornerInsets.topLeading.width
                }
                return 0
            } action: { inset = $0 }
    }
}

extension View {
    func clearsWindowControls() -> some View { modifier(WindowControlsClearance()) }
}
