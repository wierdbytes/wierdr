import SwiftUI
import UIKit

/// The pulled field (`PullToSearch`) flying to its place in Go to as Go to opens: let go
/// armed, the field leaves the list and lands where Go to's own field is, which shows
/// once it's there.
///
/// The flyer is a UIKit copy of the pulled field over the window (over the sheet, which
/// comes after it), at the pulled field's place and in its look (armed: the accent,
/// "Release to search"). While Go to's sheet is built (the main thread is busy for a
/// moment) it stays there; once Go to's field is in the window, every frame it goes on
/// along a critically damped spring from where it started to where that field is drawn
/// then (its presentation, as the sheet slides up and the keyboard pushes it up), so it
/// comes down on it wherever that is: its frame and corners, the accent fading out to
/// the field's glass, "Release to search" to the field's prompt, the icon to the field's.
/// There Go to's field shows (it's hidden while the flyer is on its way) and the flyer goes.
///
/// No flight with Reduce Motion (Go to just opens) or without Go to's field after 1.5 s.
@MainActor @Observable
final class GoToFlight {
    /// The flyer is on its way: Go to's field hides till it lands.
    private(set) var isFlying = false

    /// Go to's field (`GoToFieldAnchor`), where the flyer lands.
    @ObservationIgnored weak var target: UIView?

    struct Source {
        /// The pulled field's frame in its window.
        var rect: CGRect
        var window: UIWindow
        var style: PullToSearchStyle
    }

    @ObservationIgnored private var flyer: GoToFlyer?
    @ObservationIgnored private var source: Source?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var launched: CFTimeInterval = 0
    /// When it began to move (Go to's field was first in the window).
    @ObservationIgnored private var started: CFTimeInterval?

    /// The flight's spring (its duration: SwiftUI's response).
    private static let spring = PhoneSpring(duration: 0.45)
    /// Go to's field not in the window by then: no flight.
    private static let patience: CFTimeInterval = 1.5

    /// Takes the pulled field from `source`; false with Reduce Motion (no flight).
    func begin(_ source: Source, theme: Theme) -> Bool {
        guard !UIAccessibility.isReduceMotionEnabled else { return false }
        finish()
        // The field of a Go to opened before may still be about (as it goes).
        target = nil
        let flyer = GoToFlyer(style: source.style, theme: theme)
        flyer.frame = source.rect
        flyer.layout(progress: 0)
        source.window.addSubview(flyer)
        self.flyer = flyer
        self.source = source
        launched = CACurrentMediaTime()
        started = nil
        isFlying = true
        let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.tick(_:)))
        link.preferredFrameRateRange = PhoneMotion.frameRate
        link.add(to: .main, forMode: .common)
        self.link = link
        return true
    }

    /// Go to went before the flyer landed: it goes too.
    func cancel() { finish() }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let flyer, let source else { finish(); return }
        let now = link.targetTimestamp
        // Over the sheet, presented after the flyer came.
        if source.window.subviews.last !== flyer { source.window.bringSubviewToFront(flyer) }
        guard let target, let to = Self.drawnRect(target, in: source.window) else {
            if now - launched > Self.patience { finish() }
            return
        }
        let start = started ?? now
        started = start
        let left = Self.spring.state(at: now - start, x0: 1, v0: 0).x
        let p = 1 - left
        flyer.frame = CGRect(x: lerp(source.rect.minX, to.minX, p), y: lerp(source.rect.minY, to.minY, p),
                             width: lerp(source.rect.width, to.width, p), height: lerp(source.rect.height, to.height, p))
        flyer.layout(progress: p)
        if left < 0.002 { land() }
    }

    /// There: Go to's field shows, and the flyer goes once it's drawn.
    private func land() {
        let flyer = self.flyer
        self.flyer = nil
        stop()
        isFlying = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { flyer?.removeFromSuperview() }
    }

    private func finish() {
        stop()
        flyer?.removeFromSuperview()
        flyer = nil
        if isFlying { isFlying = false }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        source = nil
        started = nil
    }

    /// Where a view is drawn now (its presentation, its sheet's and the keyboard's moves
    /// included), in `window`; nil while it's in no window.
    private static func drawnRect(_ view: UIView, in window: UIWindow) -> CGRect? {
        guard let its = view.window else { return nil }
        let layer = view.layer.presentation() ?? view.layer
        let root = its.layer.presentation() ?? its.layer
        let rect = layer.convert(layer.bounds, to: root)
        return its === window ? rect : its.convert(rect, to: window)
    }

    /// The link's target (a link keeps its target; the flight it ticks, weakly).
    @MainActor
    private final class Tick: NSObject {
        weak var flight: GoToFlight?
        init(_ flight: GoToFlight) { self.flight = flight }
        @objc func tick(_ link: CADisplayLink) {
            guard let flight else { link.invalidate(); return }
            flight.tick(link)
        }
    }
}

/// Go to's field, where the flyer lands (`GoToFlight.target`): a view behind it.
struct GoToFieldAnchor: UIViewRepresentable {
    var flight: GoToFlight

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        flight.target = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { flight.target = view }
}

/// The flying field: the pulled field's look (armed) at 0, Go to's field's at 1 (its
/// glass, the muted magnifier 14 pt in, the prompt 8 pt after it).
private final class GoToFlyer: UIView {
    private let style: PullToSearchStyle
    /// Go to's field's glass (before iOS 26: its fill and keyline).
    private let glass: UIView
    /// The sidebar's field: a card's surface and border over the glass.
    private let card = UIView()
    private let accent = UIView()
    private let armedIcon = UIImageView()
    private let icon = UIImageView()
    private let armedLabel = UILabel()
    private let label = UILabel()

    private static let iconSize: CGFloat = 18
    private static let iconLeading: CGFloat = 14
    private static let spacing: CGFloat = 8
    private static let fontSize: CGFloat = 17

    init(style: PullToSearchStyle, theme: Theme) {
        self.style = style
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = false
            effect.tintColor = .white.withAlphaComponent(theme.isDark ? 0.025 : 0.1)
            glass = UIVisualEffectView(effect: effect)
        } else {
            glass = UIView()
            glass.backgroundColor = UIColor(theme.isDark ? theme.raised.opacity(0.85) : theme.background.opacity(0.7))
            glass.layer.borderColor = UIColor.white.withAlphaComponent(theme.isDark ? 0.15 : 0.6).cgColor
            glass.layer.borderWidth = 0.8
        }
        super.init(frame: .zero)
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true

        card.backgroundColor = UIColor(theme.surface)
        card.layer.borderColor = UIColor(theme.border).cgColor
        card.layer.borderWidth = 1
        card.isHidden = style.glass
        accent.backgroundColor = UIColor(theme.accent)
        for view in [card, accent] { view.layer.cornerCurve = .continuous }

        let image = UIImage(named: "ui.search")?.withRenderingMode(.alwaysTemplate)
        armedIcon.image = image
        armedIcon.tintColor = UIColor(theme.accentForeground)
        icon.image = image
        icon.tintColor = UIColor(theme.muted)

        armedLabel.text = "Release to search"
        armedLabel.font = style.uiFont
        armedLabel.textColor = UIColor(theme.accentForeground)
        label.text = "Spaces, agents"
        label.font = .systemFont(ofSize: Self.fontSize)
        label.textColor = UIColor(theme.foreground.opacity(theme.isDark ? 0.48 : 0.40))
        for text in [armedLabel, label] {
            text.sizeToFit()
            text.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        }

        for view in [glass, card, accent, armedIcon, icon, armedLabel, label] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its look at `p` (0: the pulled field's, 1: Go to's field's), its frame already set.
    func layout(progress p: CGFloat) {
        let size = bounds.size
        let h0 = style.height
        // The pulled field's corners (a capsule's, or the card's) to a capsule's.
        let radius = min(size.height / 2, lerp(style.cornerRadius ?? h0 / 2, size.height / 2, p))
        glass.frame = bounds
        if #available(iOS 26.0, *), let glass = glass as? UIVisualEffectView {
            glass.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
        } else {
            glass.layer.cornerRadius = radius
            glass.layer.cornerCurve = .continuous
        }
        for view in [card, accent] {
            view.frame = bounds
            view.layer.cornerRadius = radius
        }
        card.alpha = 1 - smoothstep(0.1, 0.7, p)
        accent.alpha = 1 - smoothstep(0, 0.65, p)

        let side = lerp(style.iconSize, Self.iconSize, p)
        let x = lerp(style.iconLeading, Self.iconLeading, p)
        let iconFrame = CGRect(x: x, y: (size.height - side) / 2, width: side, height: side)
        armedIcon.frame = iconFrame
        icon.frame = iconFrame
        armedIcon.alpha = 1 - smoothstep(0, 0.6, p)
        icon.alpha = smoothstep(0.2, 0.8, p)

        // The text after the icon, its size from the pulled field's to the prompt's.
        let textX = iconFrame.maxX + lerp(style.spacing, Self.spacing, p)
        let ratio = Self.fontSize / style.fontSize
        for (text, scale) in [(armedLabel, lerp(1, ratio, p)), (label, lerp(1 / ratio, 1, p))] {
            text.transform = .identity
            text.bounds = CGRect(origin: .zero, size: text.intrinsicContentSize)
            // Its anchor is its leading edge's middle.
            text.center = CGPoint(x: textX, y: size.height / 2)
            text.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        armedLabel.alpha = 1 - smoothstep(0, 0.5, p)
        label.alpha = smoothstep(0.35, 1, p)
    }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

private func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

extension WorkspaceController {
    /// Go to, let go armed from a pulled list (`PullToSearch`): its field flies from the
    /// list to its place (`GoToFlight`), or, with Reduce Motion, Go to just opens.
    func openGoTo(pulledFrom pull: PullToSearch, theme: Theme) {
        if let source = pull.flightSource(), goToFlight.begin(source, theme: theme) {
            pull.handOff()
        }
        showSwitcher = true
    }
}
