import SwiftUI
import WierdrModel

/// A UI icon from the asset catalog (`ui.<name>`), drawn as a tinted template at a fixed size.
struct Icon: View {
    var name: String
    var size: CGFloat
    var color: Color?

    init(_ name: String, size: CGFloat, color: Color? = nil) {
        self.name = name; self.size = size; self.color = color
    }

    var body: some View {
        Image(name.contains(".") ? name : "ui.\(name)")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(color ?? Color.primary)
    }
}

/// A program's icon: a tinted glyph, or the full-color picture (`tint == false`).
struct ProgramIcon: View {
    var program: Program
    var size: CGFloat
    var color: Color

    var body: some View {
        Image(program.iconAsset)
            .resizable()
            .renderingMode(program.tint ? .template : .original)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}

// MARK: - Status marks (§4.5)

/// The compact status mark used in rows, the tab bar and the counts.
struct StatusMark: View {
    enum Style { case compact, full }
    var status: AgentStatus?
    var style: Style = .compact
    /// Overrides the status color (`dim` for a zero count).
    var tint: Color? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        switch status {
        case .working:
            Spinner(size: 12, color: tint ?? theme.working)
                .padding(.horizontal, 1)
        case .blocked:
            if style == .full {
                Text("Needs you")
                    .font(.ui(10.5, .semibold))
                    .foregroundStyle(theme.blocked)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(theme.blocked.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            } else {
                Circle().fill(tint ?? theme.blocked)
                    .frame(width: 7, height: 7)
                    .padding(.horizontal, 3)
            }
        case .done:
            Circle().fill(tint ?? theme.done)
                .frame(width: 7, height: 7)
                .padding(.horizontal, 3)
        case .idle:
            Circle().strokeBorder(tint ?? theme.idle, lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .padding(.horizontal, 3)
        case nil:
            Color.clear.frame(width: 7, height: 7).padding(.horizontal, 3)
        }
    }
}

/// Herdr's `spinner.svg` drawn natively: a 24%-opacity ring and a quarter arc
/// (stroke 3.2 and radius 9.4 in a 24-pt box). Static, like the desktop.
struct Spinner: View {
    var size: CGFloat
    var color: Color

    var body: some View {
        let k = size / 24
        ZStack {
            Circle().stroke(color.opacity(0.24), lineWidth: 3.2 * k)
            Circle().trim(from: 0, to: 0.25)
                .stroke(color, style: StrokeStyle(lineWidth: 3.2 * k, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18.8 * k, height: 18.8 * k)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Status summary marks (§4.6): blocked, done, working with counts (idle not counted).
struct StatusSummary: View {
    var counts: [AgentStatus: Int]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ForEach([AgentStatus.blocked, .done, .working], id: \.self) { status in
                if let n = counts[status], n > 0 {
                    HStack(spacing: 4) {
                        StatusMark(status: status)
                        Text("\(n)")
                            .font(.ui(11))
                            .foregroundStyle(status == .blocked ? theme.blocked : theme.muted)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Format.summary(counts))
    }
}

/// The space avatar: 18×18 rounded square with the initial.
struct SpaceAvatar: View {
    var space: Space
    var size: CGFloat = 18

    var body: some View {
        Text(space.initial)
            .font(.ui(size * 10.5 / 18, .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: space.color), in: RoundedRectangle(cornerRadius: size * 5 / 18))
    }
}

// MARK: - Menu icons

/// Asset icons sized for native menus. UIKit menus draw an image at its
/// intrinsic size, and some SVGs declare `1em` (≈1 pt), so render them to a
/// fixed size first; tinted glyphs stay templates, full-color ones stay original.
@MainActor
enum MenuIcon {
    private static var cache: [String: UIImage] = [:]

    static func image(_ name: String, size: CGFloat = 20) -> Image {
        if let cached = cache[name] { return Image(uiImage: cached) }
        guard let source = UIImage(named: name) else { return Image(systemName: "app") }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let drawn = renderer.image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        let image = drawn.withRenderingMode(source.renderingMode == .alwaysOriginal ? .alwaysOriginal : .alwaysTemplate)
        cache[name] = image
        return Image(uiImage: image)
    }
}
