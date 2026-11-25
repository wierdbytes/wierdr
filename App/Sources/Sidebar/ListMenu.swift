import SwiftUI
import UIKit

/// The sidebar's long-press menu, Telegram's (its `ContextController` with an "extracted"
/// source, as for messages and folder tabs): the item held is lifted out of the list over
/// a blurred, dimmed screen, and the menu, a glass panel, grows out of its bottom edge
/// under it. If they don't fit under the item, both go up together. One spring for all
/// of it (ζ 0.775, settled in 0.42 s); the medium haptic as it starts.
///
/// The finger that held can go on to the menu: past 4 pt the item under it is
/// lit (a selection haptic on every change) and letting go runs it (`fingerMoved`,
/// `fingerLifted`). A new touch on the menu lights its item at once, and letting go runs
/// it too; a tap elsewhere puts the menu away, and a tap on a lifted row opens it. An
/// item runs, and the menu goes in 0.2 s, its item back into its place in the list.
///
/// Without a picture (a tab of the iPad's tab bar: its glass can't be drawn afresh, drawn
/// it looked different), the item itself stays where it is, seen through a hole in the
/// dim of its shape, and only the menu moves to fit.
@MainActor
final class ListMenuOverlay: UIView {
    struct Source {
        /// `space:` or `row:` and the id (`SpaceDrag.menuLifted`).
        var identifier: String
        /// Where it lies, in the window.
        var frame: CGRect
        /// Lifted over the dim; nil: the item stays in place, seen through the dim.
        var picture: UIImage?
        var radius: CGFloat
        var menu: PhoneMenu
        /// A tap on it lifted (a row: opens it).
        var open: (() -> Void)?
    }

    /// Telegram's context menu spring: CASpringAnimation (mass 5, stiffness 900, damping 104)
    /// played in 0.42 s, ζ 0.775.
    static let spring = UISpringTimingParameters(mass: 1, stiffness: 560.6, damping: 36.7, initialVelocity: .zero)
    static let springDuration: TimeInterval = 0.42
    /// Between the lifted item and the menu.
    static let spacing: CGFloat = 7
    static let dismissDuration: TimeInterval = 0.2

    let source: Source
    let menuView: ListMenuView
    /// Where the item goes back to, in the window, read as the menu goes (it may have
    /// moved meanwhile: an item ran); nil: it's gone, the picture fades.
    var returnFrame: () -> CGRect? = { nil }
    /// The menu went (its animation over).
    var onDismissed: () -> Void = {}

    private let dark: Bool
    /// `source.frame` in this view.
    private var sourceFrame: CGRect = .zero
    private let dim = UIView()
    private var blur: UIVisualEffectView?
    private let item = UIImageView()
    private var opening: UIViewPropertyAnimator?
    private(set) var dismissing = false
    private let selection = UISelectionFeedbackGenerator()

    /// The holding finger's travel over the menu.
    private var scrubFrom: CGPoint?
    private(set) var scrubbing = false
    /// A new touch: on the menu, or elsewhere (a tap there puts it away).
    private var touchOnMenu = false
    private var touchStart: CGPoint = .zero

    init(source: Source, dark: Bool, compact: Bool) {
        self.source = source
        self.dark = dark
        self.menuView = ListMenuView(menu: source.menu, dark: dark)
        super.init(frame: .zero)
        accessibilityViewIsModal = true
        // iPhone: Telegram's dim over a blur; iPad: a plain dim.
        if compact {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: dark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight))
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(blur)
            self.blur = blur
            dim.backgroundColor = dark ? UIColor(white: 0, alpha: 0.6) : UIColor(red: 0, green: 10 / 255, blue: 38 / 255, alpha: 0.2)
        } else {
            dim.backgroundColor = UIColor(white: 0, alpha: 0.4)
        }
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(dim)
        item.image = source.picture
        item.layer.cornerRadius = source.radius
        item.layer.cornerCurve = .continuous
        item.layer.masksToBounds = true
        item.isAccessibilityElement = false
        addSubview(item)
        addSubview(menuView)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    /// The item and the menu under it: in place if they fit, else up together, between the
    /// status bar (+ 8) and the screen's bottom (- 10, over the home indicator). The menu
    /// at the item's left edge if it's in the screen's left half, else at its right edge.
    /// An item without a picture stays where it is (a tab, by the status bar), the menu
    /// under it going up over it only in a window too short for both.
    private func layoutBlock(itemSize: CGSize, menuSize: CGSize, from origin: CGRect) -> (item: CGRect, menu: CGRect) {
        let bounds = self.bounds
        let safe = window?.safeAreaInsets ?? .zero
        let top = safe.top + 8, bottom = bounds.height - 10 - safe.bottom
        var y = origin.minY
        let lifted = source.picture != nil
        if lifted {
            let blockBottom = y + itemSize.height + Self.spacing + menuSize.height
            if blockBottom > bottom { y -= blockBottom - bottom }
            y = max(y, top)
        }
        let itemFrame = CGRect(origin: CGPoint(x: origin.minX, y: y), size: itemSize)
        var x = origin.midX < bounds.midX ? origin.minX + 2 : origin.maxX - 7 - menuSize.width
        x = min(max(x, 12), bounds.width - 12 - menuSize.width)
        var menuY = itemFrame.maxY + Self.spacing
        if !lifted { menuY = max(min(menuY, bottom - menuSize.height), top) }
        return (itemFrame, CGRect(origin: CGPoint(x: x, y: menuY), size: menuSize))
    }

    /// No picture: the dim (and the blur) leave the item's shape clear, the item seen
    /// through them as it is.
    private func cutHole(_ hole: CGRect) {
        func mask() -> CAShapeLayer {
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(roundedRect: hole, cornerRadius: source.radius))
            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.path = path.cgPath
            layer.fillRule = .evenOdd
            return layer
        }
        dim.frame = bounds
        dim.layer.mask = mask()
        if let blur {
            blur.frame = bounds
            let view = UIView(frame: bounds)
            view.layer.addSublayer(mask())
            blur.mask = view
        }
    }

    // MARK: Open

    /// Over `container` (full screen), right over `sibling` if given: the list's screen, so
    /// what's pushed over it (the pane screen, after a row opened or Split Right) covers
    /// the menu as it goes, rather than the menu going over it.
    func present(in container: UIView, over sibling: UIView? = nil) {
        frame = container.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let sibling { container.insertSubview(self, aboveSubview: sibling) } else { container.addSubview(self) }
        sourceFrame = convert(source.frame, from: nil)
        if source.picture == nil { cutHole(sourceFrame) }
        let size = menuView.preferredSize
        let (itemFrame, menuFrame) = layoutBlock(itemSize: sourceFrame.size, menuSize: size, from: sourceFrame)
        dim.alpha = 0
        blur?.alpha = 0
        item.frame = sourceFrame
        menuView.bounds = CGRect(origin: .zero, size: size)
        menuView.center = CGPoint(x: menuFrame.midX, y: sourceFrame.maxY)
        menuView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
        menuView.alpha = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selection.prepare()
        UIView.animate(withDuration: 0.2) {
            self.dim.alpha = 1
            self.blur?.alpha = 1
        }
        UIView.animate(withDuration: 0.05) { self.menuView.alpha = 1 }
        let opening = UIViewPropertyAnimator(duration: Self.springDuration, timingParameters: Self.spring)
        opening.addAnimations {
            self.item.frame = itemFrame
            self.menuView.center = CGPoint(x: menuFrame.midX, y: menuFrame.midY)
            self.menuView.transform = .identity
        }
        opening.startAnimation()
        self.opening = opening
        UIAccessibility.post(notification: .screenChanged, argument: menuView)
    }

    // MARK: Close

    /// Puts the menu away; `then` runs first (an item's work), the item goes back where
    /// the list has it once that's laid out (`inPlace`: it fades where it is, the row
    /// being opened over it).
    func dismiss(inPlace: Bool = false, then action: (() -> Void)? = nil) {
        guard !dismissing else { return }
        dismissing = true
        isUserInteractionEnabled = false
        action?()
        DispatchQueue.main.async { [self] in
            opening?.stopAnimation(true)
            opening = nil
            let target = inPlace ? nil : returnFrame().map { convert($0, from: nil) }
            let edge = (target ?? item.frame).maxY
            UIView.animate(withDuration: Self.dismissDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                self.dim.alpha = 0
                self.blur?.alpha = 0
                self.menuView.alpha = 0
                self.menuView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
                self.menuView.center = CGPoint(x: self.menuView.center.x, y: edge)
                if let target { self.item.frame = target } else { self.item.alpha = 0 }
            } completion: { _ in
                self.removeFromSuperview()
                self.onDismissed()
            }
        }
    }

    // MARK: The menu's items

    private func light(at point: CGPoint) {
        let index = menuView.index(at: convert(point, to: menuView))
        guard index != menuView.highlighted else { return }
        menuView.setHighlight(index)
        selection.selectionChanged()
        selection.prepare()
    }

    /// Runs the lit item: a submenu takes the menu's place, Back goes back, an item runs
    /// and the menu goes.
    private func runLit() {
        guard let index = menuView.highlighted else { return }
        choose(index)
    }

    fileprivate func choose(_ index: Int) {
        switch menuView.entry(index) {
        case .back:
            resize { self.menuView.pop() }
        case .item(let item) where item.children != nil:
            resize { self.menuView.push(item.children ?? []) }
        case .item(let item) where !item.disabled:
            menuView.setHighlight(index, animated: false)
            dismiss(then: item.run)
        default:
            menuView.setHighlight(nil)
        }
    }

    /// The menu changes its page (`change`, on `ListMenuView`): it and the item move to
    /// fit its new size, on Telegram's push curve.
    private func resize(_ change: () -> (size: CGSize, animations: () -> Void, completion: () -> Void)) {
        let (size, animations, completion) = change()
        opening?.stopAnimation(true)
        opening = nil
        let (itemFrame, menuFrame) = layoutBlock(itemSize: item.bounds.size, menuSize: size, from: sourceFrame)
        let animator = UIViewPropertyAnimator(duration: 0.35, controlPoint1: CGPoint(x: 0.38, y: 0.7),
                                              controlPoint2: CGPoint(x: 0.125, y: 1))
        animator.addAnimations {
            self.item.frame = itemFrame
            self.menuView.transform = .identity
            self.menuView.bounds.size = menuFrame.size
            self.menuView.center = CGPoint(x: menuFrame.midX, y: menuFrame.midY)
            animations()
        }
        animator.addCompletion { _ in completion() }
        animator.startAnimation()
        scrubbing = false
        scrubFrom = nil
    }

    // MARK: The holding finger

    func isOverMenu(_ point: CGPoint, margin: CGFloat = 0) -> Bool {
        menuView.frame.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    /// Over the lifted item (where it is now).
    func isOverItem(_ point: CGPoint, margin: CGFloat = 0) -> Bool {
        (item.layer.presentation()?.frame ?? item.frame).insetBy(dx: -margin, dy: -margin).contains(point)
    }

    /// The finger that held moved (in this view): past 4 pt, it lights the item under it.
    func fingerMoved(to point: CGPoint) {
        guard !dismissing else { return }
        if !scrubbing {
            guard let from = scrubFrom else { scrubFrom = point; return }
            // Telegram's counts only up or down; here the menu may lie under the finger
            // (the item went up for it to fit), so any way.
            guard hypot(point.x - from.x, point.y - from.y) > 4 else { return }
            scrubbing = true
        }
        light(at: point)
    }

    /// The finger that held is up: its lit item runs (none: the menu stays).
    func fingerLifted(at point: CGPoint) {
        guard !dismissing, scrubbing else { return }
        scrubbing = false
        scrubFrom = nil
        if menuView.highlighted != nil { runLit() }
    }

    // MARK: New touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !dismissing, let touch = touches.first else { return }
        let p = touch.location(in: self)
        touchStart = p
        touchOnMenu = isOverMenu(p)
        if touchOnMenu { light(at: p) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !dismissing, touchOnMenu, let touch = touches.first else { return }
        light(at: touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !dismissing, let touch = touches.first else { return }
        let p = touch.location(in: self)
        if touchOnMenu {
            runLit()
        } else if hypot(p.x - touchStart.x, p.y - touchStart.y) < 10 {
            if item.frame.contains(p), let open = source.open { dismiss(inPlace: true, then: open) } else { dismiss() }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touchOnMenu { menuView.setHighlight(nil) }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    // MARK: Pointer

    @objc private func hover(_ hover: UIHoverGestureRecognizer) {
        switch hover.state {
        case .began, .changed: hovered(at: hover.location(in: self))
        default: hovered(at: nil)
        }
    }

    /// A pointer over the menu lights its items (no haptic), as Telegram's on the iPad.
    private func hovered(at point: CGPoint?) {
        guard !dismissing, !scrubbing else { return }
        menuView.setHighlight(point.flatMap { isOverMenu($0) ? menuView.index(at: convert($0, to: menuView)) : nil })
    }
}

/// The menu's glass panel (Telegram's `ContextControllerActionsStackNode`): 220–260 pt wide,
/// 43-pt items (an icon in a 32-pt column at 20, the title at 60 in 17-pt text), no lines
/// between items but a 20-pt divider between sections, 10 pt over and under them, corners
/// of 30. The lit item has a pill under it (inset 10), which slides between items. A
/// submenu takes the page's place sliding in from the right, a Back item on top.
@MainActor
final class ListMenuView: UIView {
    enum Entry {
        case item(PhoneMenuItem)
        case back
        case separator
    }

    private struct Page {
        var view: UIView
        var entries: [Entry]
        var frames: [CGRect]
        var size: CGSize
    }

    private static let font = UIFont.systemFont(ofSize: 17)
    private static var rowHeight: CGFloat { 22 + ceil(font.lineHeight) }
    /// A section's caption (`PhoneMenuItem.caption`): smaller, dim, at the titles' edge.
    private static let captionFont = UIFont.systemFont(ofSize: 13)
    private static var captionHeight: CGFloat { 12 + ceil(captionFont.lineHeight) }

    private let dark: Bool
    private let glass: UIVisualEffectView
    private let clip = UIView()
    private var page: Page
    private var stack: [PhoneMenu]
    private let pill = UIView()
    private(set) var highlighted: Int?
    private var primary: UIColor { dark ? .white : .black }
    private var destructive: UIColor {
        dark ? UIColor(red: 0xEB / 255, green: 0x55 / 255, blue: 0x45 / 255, alpha: 1) : UIColor(red: 1, green: 0x3B / 255, blue: 0x30 / 255, alpha: 1)
    }

    var preferredSize: CGSize { page.size }

    init(menu: PhoneMenu, dark: Bool) {
        self.dark = dark
        self.stack = [menu]
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = UIColor(white: 1, alpha: dark ? 0.025 : 0.1)
            glass = UIVisualEffectView(effect: effect)
            glass.cornerConfiguration = .corners(radius: .fixed(30))
        } else {
            glass = UIVisualEffectView(effect: UIBlurEffect(style: dark ? .systemThickMaterialDark : .systemThickMaterialLight))
            glass.layer.cornerRadius = 30
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
        }
        page = Page(view: UIView(), entries: [], frames: [], size: .zero)
        super.init(frame: .zero)
        overrideUserInterfaceStyle = dark ? .dark : .light
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        clip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        clip.layer.cornerRadius = 30
        clip.layer.cornerCurve = .continuous
        clip.layer.masksToBounds = true
        glass.contentView.addSubview(clip)
        pill.backgroundColor = primary.withAlphaComponent(0.1)
        pill.layer.cornerCurve = .continuous
        pill.alpha = 0
        page = makePage(menu, back: false)
        clip.addSubview(pill)
        clip.addSubview(page.view)
        page.view.frame = CGRect(origin: .zero, size: page.size)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        clip.frame = glass.contentView.bounds
    }

    func entry(_ index: Int) -> Entry { page.entries[index] }

    /// The item at `point` (in this view) that can be chosen.
    func index(at point: CGPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        for (i, entry) in page.entries.enumerated() where page.frames[i].minY <= point.y && point.y < page.frames[i].maxY {
            switch entry {
            case .back: return i
            case .item(let item): return item.disabled ? nil : i
            case .separator: return nil
            }
        }
        return nil
    }

    func setHighlight(_ index: Int?, animated: Bool = true) {
        let was = highlighted
        highlighted = index
        guard let index else {
            if was != nil { UIView.animate(withDuration: animated ? 0.2 : 0) { self.pill.alpha = 0 } }
            return
        }
        let row = page.frames[index]
        let frame = CGRect(x: 10, y: row.minY, width: page.size.width - 20, height: row.height)
        pill.layer.cornerRadius = min(20, frame.height / 2)
        if was == nil || pill.alpha == 0 {
            pill.frame = frame
            UIView.animate(withDuration: animated ? 0.2 : 0) { self.pill.alpha = 1 }
        } else {
            UIView.animate(withDuration: animated ? 0.16 : 0, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                self.pill.frame = frame
            }
        }
    }

    // MARK: Submenus

    typealias Change = (size: CGSize, animations: () -> Void, completion: () -> Void)

    func push(_ menu: PhoneMenu) -> Change {
        stack.append(menu)
        return turn(to: makePage(menu, back: true), forward: true)
    }

    func pop() -> Change {
        if stack.count > 1 { stack.removeLast() }
        return turn(to: makePage(stack[stack.count - 1], back: stack.count > 1), forward: false)
    }

    /// The new page slides in (from the right going in, from the left going back), the
    /// old one out the other way, fading.
    private func turn(to new: Page, forward: Bool) -> Change {
        let old = page
        setHighlight(nil, animated: false)
        page = new
        let width = max(old.size.width, new.size.width)
        new.view.frame = CGRect(origin: CGPoint(x: forward ? width : -width, y: 0), size: new.size)
        new.view.alpha = 0
        clip.addSubview(new.view)
        return (new.size, {
            new.view.frame.origin = .zero
            new.view.alpha = 1
            old.view.frame.origin.x = forward ? -width * 0.4 : width * 0.4
            old.view.alpha = 0
        }, {
            old.view.removeFromSuperview()
        })
    }

    // MARK: Drawing

    private func makePage(_ menu: PhoneMenu, back: Bool) -> Page {
        var entries: [Entry] = back ? [.back] : []
        let sections = menu.filter { !$0.isEmpty }
        for (i, section) in sections.enumerated() {
            if i > 0 || (back && i == 0) { entries.append(.separator) }
            entries += section.map { .item($0) }
        }
        let hasSubmenus = sections.joined().contains { $0.children != nil }
        let text = entries.map { entry -> CGFloat in
            switch entry {
            case .item(let item):
                let font = item.caption ? Self.captionFont : Self.font
                return ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
            case .back: return ceil(("Back" as NSString).size(withAttributes: [.font: Self.font]).width)
            case .separator: return 0
            }
        }.max() ?? 0
        let width = min(260, max(220, 60 + text + 18 + (hasSubmenus ? 22 : 0)))
        let view = UIView()
        var frames: [CGRect] = []
        var y: CGFloat = 10
        for entry in entries {
            let height: CGFloat
            switch entry {
            case .separator:
                height = 20
                let line = UIView(frame: CGRect(x: 18, y: y + 9.5, width: width - 36, height: 1))
                line.backgroundColor = primary.withAlphaComponent(0.15)
                view.addSubview(line)
            case .back:
                height = Self.rowHeight
                view.addSubview(row(title: "Back", icon: UIImage(systemName: "chevron.left"), color: primary,
                                    chevron: false, frame: CGRect(x: 0, y: y, width: width, height: height)))
            case .item(let item) where item.caption:
                height = Self.captionHeight
                let label = UILabel(frame: CGRect(x: 20, y: y + 4, width: width - 38, height: height - 4))
                label.text = item.title
                label.font = Self.captionFont
                label.textColor = primary.withAlphaComponent(0.5)
                label.lineBreakMode = .byTruncatingTail
                label.accessibilityTraits = .header
                view.addSubview(label)
            case .item(let item):
                height = Self.rowHeight
                let color = item.destructive ? destructive : primary
                let row = row(title: item.title, icon: item.icon.uiImage, color: color, chevron: item.children != nil,
                              frame: CGRect(x: 0, y: y, width: width, height: height))
                row.alpha = item.disabled ? 0.4 : 1
                if item.disabled { row.accessibilityTraits.insert(.notEnabled) }
                view.addSubview(row)
            }
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height
        }
        let size = CGSize(width: width, height: max(28, y + 10))
        view.frame = CGRect(origin: .zero, size: size)
        // VoiceOver: each item a button that runs it.
        for (i, entry) in entries.enumerated() {
            guard case .separator = entry else {
                (view.subviews.first { $0.frame == frames[i] } as? MenuRow)?.activate = { [weak self] in
                    (self?.superview as? ListMenuOverlay)?.choose(i)
                }
                continue
            }
        }
        return Page(view: view, entries: entries, frames: frames, size: size)
    }

    private func row(title: String, icon: UIImage?, color: UIColor, chevron: Bool, frame: CGRect) -> MenuRow {
        let row = MenuRow(frame: frame)
        let label = UILabel()
        label.text = title
        label.font = Self.font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        let right: CGFloat = chevron ? 40 : 18
        label.frame = CGRect(x: 60, y: 0, width: frame.width - 60 - right, height: frame.height)
        row.addSubview(label)
        if let icon {
            let image = UIImageView(image: icon)
            image.tintColor = color
            image.contentMode = .center
            image.frame = CGRect(x: 20, y: 0, width: 32, height: frame.height)
            row.addSubview(image)
        }
        if chevron {
            let image = UIImageView(image: UIImage(systemName: "chevron.right",
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
            image.tintColor = color.withAlphaComponent(0.5)
            image.contentMode = .center
            image.frame = CGRect(x: frame.width - 18 - 18, y: 0, width: 18, height: frame.height)
            row.addSubview(image)
        }
        row.isAccessibilityElement = true
        row.accessibilityLabel = title
        row.accessibilityTraits = .button
        return row
    }

    /// An item, for VoiceOver.
    final class MenuRow: UIView {
        var activate: (() -> Void)?
        override func accessibilityActivate() -> Bool {
            activate?()
            return activate != nil
        }
    }
}
