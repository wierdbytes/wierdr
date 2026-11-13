import SwiftUI
import UIKit

/// The composer's text (`ComposerBar`): a `UITextView`, as Telegram's, laid
/// out with its metrics (system 17 pt, text insets 4.5 / 5.5, at least 31 pt:
/// a 40-pt capsule for one line). SwiftUI's `TextField` can't turn smart
/// quotes off, scroll a one-line window or carry the iPad's accessory.
///
/// While it doesn't have the keyboard it is one line tall: a window into the
/// draft as it is (its line breaks too), from its first line each time the
/// keyboard goes; a finger scrolls it through the lines, a tap brings the
/// keyboard with the caret where it landed. With the keyboard it grows with
/// the text up to `maxHeight`, then scrolls. A hardware keyboard's Return
/// sends (Telegram's rule; ⇧Return is a new line); the on-screen keyboard's
/// Return is a new line.
struct ComposerTextView: UIViewRepresentable {
    var text: String
    /// Has the keyboard (or should get it).
    var focused: Bool
    /// An agent (prose: capitals, corrections) or a shell (commands as typed).
    var prose: Bool
    var placeholder: String
    /// The tallest the text may get (Telegram's cap, from the room above).
    var maxHeight: CGFloat
    var theme: Theme
    var onEdit: (String) -> Void
    var onFocus: (Bool) -> Void
    var onReturn: () -> Void

    /// Telegram's `chatTextInputFieldMinHeight`: one line of 17 pt and the insets.
    static let minHeight: CGFloat = 31
    static let font = UIFont.systemFont(ofSize: 17)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.font = Self.font
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = true
        // Its insets are its own: the iPhone's bar dips into the home indicator's safe area,
        // and the automatic adjustment moved the one-line window off its line (iOS 26).
        view.contentInsetAdjustmentBehavior = .never
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceVertical = false
        view.returnKeyType = .default
        view.adjustsFontForContentSizeCategory = false
        if !Device.isPhone { view.inputAccessoryView = EmptyAccessory() }
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // Only what changed: setting the text traits again (even to the same
        // values) makes the keyboard resync its document, and keys typed fast
        // meanwhile land where the caret was (seen on an iPhone, iOS 26).
        if c.theme != theme {
            c.theme = theme
            view.textColor = UIColor(theme.foreground)
            view.tintColor = UIColor(theme.accent)
            view.keyboardAppearance = theme.isDark ? .dark : .light
        }
        if c.prose != prose {
            c.prose = prose
            view.autocapitalizationType = prose ? .sentences : .none
            view.autocorrectionType = prose ? .default : .no
            view.spellCheckingType = prose ? .default : .no
            // Straight quotes always (they'd be made straight on sending anyway); dashes in prose only.
            view.smartQuotesType = .no
            view.smartDashesType = prose ? .default : .no
            view.smartInsertDeleteType = prose ? .default : .no
        }
        if view.accessibilityLabel != placeholder { view.accessibilityLabel = placeholder }
        view.onReturn = onReturn
        // Telegram: the text column ends 56 pt from the capsule's edge beside
        // the send button (the view itself ends 11 pt in). The send button is
        // there whenever there is text, so the inset stays: switching it with
        // the first character made keys typed fast meanwhile land where the
        // caret had been (the keyboard resyncs; seen on an iPhone, iOS 26).
        let insets = UIEdgeInsets(top: 4.5, left: 0, bottom: 5.5, right: 45)
        if view.textContainerInset != insets { view.textContainerInset = insets }
        let indicator = UIEdgeInsets(top: 9, left: 0, bottom: 40, right: 0)
        if view.verticalScrollIndicatorInsets != indicator { view.verticalScrollIndicatorInsets = indicator }

        let collapsed = !focused && !view.isFirstResponder
        view.oneLine = collapsed
        c.apply(text: text, collapsed: collapsed)

        if focused, !view.isFirstResponder {
            DispatchQueue.main.async {
                guard view.window != nil, !view.isFirstResponder, c.parent?.focused == true else { return }
                _ = view.becomeFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ComposerUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let collapsed = !focused && !view.isFirstResponder
        return CGSize(width: width, height: Self.height(of: view, width: width, collapsed: collapsed, cap: maxHeight))
    }

    /// Telegram's: `ceil(lines · lineHeight + 10)`, at least 31, at most `cap` (then it scrolls).
    /// Measured here, not with `UITextView.sizeThatFits`: with TextKit 2 that
    /// missed the empty line a Return at the end starts, where the caret is.
    static func height(of view: UITextView, width: CGFloat, collapsed: Bool, cap: CGFloat) -> CGFloat {
        let one = ceil(font.lineHeight + 10)
        guard !collapsed else { return max(minHeight, one) }
        let inset = view.textContainerInset
        let column = width - inset.left - inset.right - 2 * view.textContainer.lineFragmentPadding
        var text = view.text ?? ""
        // A line break at the end starts a line of its own: measure it with something on it.
        if text.isEmpty || text.hasSuffix("\n") || text.hasSuffix("\r") || text.hasSuffix("\u{2028}") { text += "X" }
        let used = (text as NSString).boundingRect(
            with: CGSize(width: max(1, column), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        let fitted = ceil(used.height + inset.top + inset.bottom)
        return min(max(minHeight, fitted), max(cap, minHeight))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView?
        weak var view: ComposerUITextView?
        /// What the view was last set up with (`updateUIView` sets only what changed).
        var theme: Theme?
        var prose: Bool?
        /// One line tall at the last update (the keyboard gone).
        private var collapsed = false
        /// The text last reported as typed: SwiftUI handing it back (maybe a
        /// key behind) is no change from outside.
        private var reported: String?

        /// The draft, and the one-line window back at its first line when the keyboard has just gone.
        func apply(text: String, collapsed: Bool) {
            guard let view else { return }
            if collapsed, !self.collapsed { view.setContentOffset(.zero, animated: false) }
            self.collapsed = collapsed
            if text != reported, view.text != text, view.markedTextRange == nil {
                // Changed from outside (a path, a paste, sent): the caret goes to the end.
                view.text = text
                reported = text
                view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                view.textChanged()
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent?.onFocus(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent?.onFocus(false)
        }

        /// One line tall, a finger's scroll comes to rest on a whole line.
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let view = scrollView as? ComposerUITextView, view.oneLine else { return }
            let line = ComposerTextView.font.lineHeight
            let end = max(0, view.contentSize.height + view.contentInset.bottom - view.bounds.height)
            let y = (targetContentOffset.pointee.y / line).rounded() * line
            targetContentOffset.pointee.y = min(max(0, y), end)
        }

        func textViewDidChange(_ textView: UITextView) {
            reported = textView.text
            (textView as? ComposerUITextView)?.textChanged()
            parent?.onEdit(textView.text)
        }
    }

    /// iPad: an empty, 1-pt input accessory, so `KeyboardCover` can tell where
    /// the keyboard begins (as with the terminal's key bar: above a docked
    /// keyboard, at the bottom under a floating one).
    final class EmptyAccessory: UIView {
        override init(frame: CGRect) {
            super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            autoresizingMask = .flexibleWidth
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 1) }
    }
}

/// The composer's text view: Return from a hardware keyboard sends, and the
/// iPad's 1-pt accessory is found through it (`KeyboardCover`).
final class ComposerUITextView: UITextView {
    var onReturn: (() -> Void)?

    /// One line tall (the keyboard gone): only one line shows (the next one's
    /// top would peek out of the insets), and the last one can come to rest at the top.
    var oneLine = false {
        didSet {
            guard oneLine != oldValue else { return }
            showsVerticalScrollIndicator = !oneLine
            contentInset.bottom = oneLine ? 1 : 0
            setNeedsLayout()
        }
    }
    private let lineMask = CALayer()

    private static weak var focusedView: ComposerUITextView?

    /// The accessory and window of the composer that has the keyboard (iPad).
    static var activeAccessory: (bar: UIView, window: UIWindow)? {
        guard let view = focusedView, view.isFirstResponder, let window = view.window,
              let bar = view.inputAccessoryView, bar.window != nil else { return nil }
        return (bar, window)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { Self.focusedView = self }
        return ok
    }

    /// The text or the field's size changed: the next layout scrolls the caret into view.
    private var followsCaret = false

    override var frame: CGRect {
        didSet { if frame.size != oldValue.size { followsCaret = true } }
    }

    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { followsCaret = true } }
    }

    /// Typed or set: once laid out (SwiftUI resizes the field a moment
    /// later), the caret is scrolled into view.
    func textChanged() {
        followsCaret = true
        setNeedsLayout()
    }

    // Only after a change, not on every layout: a finger scrolling back
    // through a long message isn't pulled back to the caret.
    override func layoutSubviews() {
        super.layoutSubviews()
        updateLineMask()
        snapToLine()
        guard followsCaret else { return }
        followsCaret = false
        keepCaretInView()
    }

    /// One line tall: a mask over the first line's place (it moves with the
    /// bounds, which scrolling shifts, so it is set again on every layout).
    private func updateLineMask() {
        guard oneLine else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineMask.backgroundColor = UIColor.black.cgColor
        // The line's own band: the insets around it would show the lines next to it once scrolled.
        lineMask.frame = CGRect(x: bounds.minX, y: bounds.minY + textContainerInset.top, width: bounds.width,
                                height: ComposerTextView.font.lineHeight)
        if layer.mask !== lineMask { layer.mask = lineMask }
        CATransaction.commit()
    }

    /// One line tall and at rest: on a whole line, whatever moved it (a
    /// finger's scroll settles there by itself, see the coordinator).
    private func snapToLine() {
        guard oneLine, !isTracking, !isDragging, !isDecelerating, bounds.height > 0 else { return }
        let line = ComposerTextView.font.lineHeight
        let end = max(0, contentSize.height + contentInset.bottom - bounds.height)
        let y = min(max(0, (contentOffset.y / line).rounded() * line), end)
        if abs(contentOffset.y - y) > 0.5 { contentOffset.y = y }
    }

    /// Scrolls just enough for the caret's line (and the inset under it) to
    /// show; the whole text fits: from its top.
    private func keepCaretInView() {
        let height = bounds.height
        guard height > 0 else { return }
        var y = min(max(contentOffset.y, 0), max(0, contentSize.height - height))
        if isFirstResponder, let range = selectedTextRange {
            let caret = caretRect(for: range.end)
            if !caret.isNull, !caret.isInfinite, caret.height > 0 {
                let bottom = caret.maxY + textContainerInset.bottom
                if bottom > y + height { y = bottom - height }
                let top = caret.minY - textContainerInset.top
                if top < y { y = top }
                y = max(0, y)
            }
        }
        if abs(contentOffset.y - y) > 0.5 { setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false) }
    }

    // A hardware keyboard's Return (no modifiers, not finishing marked text): send.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key, isPlainReturn(key), markedTextRange == nil, let onReturn {
            onReturn()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key, isPlainReturn(key), markedTextRange == nil, onReturn != nil { return }
        super.pressesEnded(presses, with: event)
    }

    private func isPlainReturn(_ key: UIKey) -> Bool {
        (key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter)
            && key.modifierFlags.intersection([.shift, .alternate, .command, .control]).isEmpty
    }
}
