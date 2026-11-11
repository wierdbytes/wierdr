import UIKit
import SwiftTerm

/// The key bar above the on-screen keyboard: Esc, sticky Ctrl and Alt, Tab,
/// common shell symbols, arrows (auto-repeat; iPad only: the iPhone's are in
/// its key panel, `PhoneKeyPanel`) and a hide-keyboard key.
/// Styled with the terminal theme.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    private weak var terminalView: WierdrTerminalView?
    private let scroll = UIScrollView()
    private let leading = UIStackView()
    private let trailing = UIStackView()
    private var ctrlButton: KeyButton!
    private var altButton: KeyButton!
    private var buttons: [KeyButton] = []
    private var repeatTimer: Timer?
    private var theme = TerminalTheme.atomOneDark
    private var observers: [NSObjectProtocol] = []

    var enableInputClicksWhenVisible: Bool { true }

    init(terminalView: WierdrTerminalView) {
        self.terminalView = terminalView
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: phone ? 42 : 50), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleWidth
        build()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .terminalViewControlModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModifiers() }
        })
        observers.append(center.addObserver(forName: .terminalViewMetaModifierReset, object: terminalView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModifiers() }
        })
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIDevice.current.userInterfaceIdiom == .phone ? 42 : 50)
    }

    private func build() {
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        for stack in [leading, trailing] {
            stack.axis = .horizontal
            stack.spacing = 6
            stack.alignment = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        scroll.addSubview(leading)
        addSubview(trailing)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            scroll.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
            leading.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            leading.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            leading.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            leading.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            leading.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            trailing.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        leading.addArrangedSubview(key("esc") { $0.sendBytes([0x1b]) })
        ctrlButton = key("ctrl", sticky: true) { bar in
            guard let tv = bar.terminalView else { return }
            tv.controlModifier.toggle()
            bar.refreshModifiers()
        }
        leading.addArrangedSubview(ctrlButton)
        altButton = key("alt", sticky: true) { bar in
            guard let tv = bar.terminalView else { return }
            tv.metaModifier.toggle()
            bar.refreshModifiers()
        }
        leading.addArrangedSubview(altButton)
        leading.addArrangedSubview(key("tab", symbol: "arrow.right.to.line") { $0.sendBytes([0x09]) })
        for s in ["~", "|", "/", "\\", "-", "_", ":", ";", "`", "'", "\"", "$", "*", "&", "<", ">", "{", "}", "[", "]", "(", ")"] {
            leading.addArrangedSubview(key(s) { $0.typeSymbol(s) })
        }

        if UIDevice.current.userInterfaceIdiom != .phone {
            trailing.addArrangedSubview(key("left", symbol: "arrow.left", repeats: true) { $0.arrow(altBytes: [0x1b, 0x62]) { $0.sendKeyLeft() } })
            trailing.addArrangedSubview(key("down", symbol: "arrow.down", repeats: true) { $0.arrow(altBytes: nil) { $0.sendKeyDown() } })
            trailing.addArrangedSubview(key("up", symbol: "arrow.up", repeats: true) { $0.arrow(altBytes: nil) { $0.sendKeyUp() } })
            trailing.addArrangedSubview(key("right", symbol: "arrow.right", repeats: true) { $0.arrow(altBytes: [0x1b, 0x66]) { $0.sendKeyRight() } })
        }
        trailing.addArrangedSubview(key("hide", symbol: "keyboard.chevron.compact.down") { bar in
            _ = bar.terminalView?.resignFirstResponder()
        })
        apply(theme: theme)
    }

    private func key(_ title: String, symbol: String? = nil, sticky: Bool = false, repeats: Bool = false,
                     action: @escaping (TerminalKeyBar) -> Void) -> KeyButton {
        let b = KeyButton(type: .custom)
        b.accessibilityLabel = title
        if let symbol {
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        } else {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = title.count > 1 ? .systemFont(ofSize: 15, weight: .medium)
                                                 : UIFont(name: "JetBrainsMono-Regular", size: 18) ?? .monospacedSystemFont(ofSize: 18, weight: .regular)
        }
        b.layer.cornerRadius = 7
        b.layer.cornerCurve = .continuous
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: symbol != nil || title.count == 1 ? 44 : 52).isActive = true
        b.isSticky = sticky
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UIDevice.current.playInputClick()
            action(self)
            if repeats {
                self.repeatTimer?.invalidate()
                let timer = Timer(fire: Date(timeIntervalSinceNow: 0.45), interval: 0.07, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { action(self) } }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.repeatTimer = timer
            }
        }, for: .touchDown)
        if repeats {
            for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
                b.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: event)
            }
        }
        buttons.append(b)
        return b
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeat() }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func sendBytes(_ bytes: [UInt8]) {
        terminalView?.onUserTouch?()
        terminalView?.send(bytes)
    }

    /// Symbols go through text input, so a latched Ctrl/Alt applies to them.
    private func typeSymbol(_ s: String) {
        terminalView?.onUserTouch?()
        terminalView?.insertText(s)
        refreshModifiers()
    }

    private func arrow(altBytes: [UInt8]?, _ plain: (WierdrTerminalView) -> Void) {
        guard let tv = terminalView else { return }
        tv.onUserTouch?()
        if tv.metaModifier, let altBytes {
            tv.send(altBytes)
            tv.metaModifier = false
            refreshModifiers()
        } else {
            plain(tv)
        }
    }

    func refreshModifiers() {
        ctrlButton.isLatched = terminalView?.controlModifier ?? false
        altButton.isLatched = terminalView?.metaModifier ?? false
    }

    func apply(theme: TerminalTheme) {
        self.theme = theme
        backgroundColor = theme.keyBarBackground
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        for b in buttons {
            b.fill = theme.keyFill
            b.latchedFill = theme.keyFillActive
            b.setTitleColor(theme.keyText, for: .normal)
            b.tintColor = theme.keyText
        }
        refreshModifiers()
    }
}

final class KeyButton: UIButton {
    var isSticky = false
    var fill: UIColor = .systemGray5 { didSet { updateFill() } }
    var latchedFill: UIColor = .systemBlue { didSet { updateFill() } }
    var isLatched = false { didSet { updateFill() } }

    override var isHighlighted: Bool { didSet { updateFill() } }

    private func updateFill() {
        if isLatched {
            backgroundColor = latchedFill
        } else {
            backgroundColor = isHighlighted ? fill.withAlphaComponent(min(1, fill.cgColor.alpha * 2.2)) : fill
        }
    }
}
