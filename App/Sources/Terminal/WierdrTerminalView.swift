import UIKit
import MetalKit
import GameController
import Synchronization
import SwiftTerm
import HerdrCore

/// Where bytes the emulator produces on its own go: answers to terminal
/// queries (tagged AUTOMATIC_INPUT) and mouse reports / pastes (DATA).
/// Thread-safe: replies are produced while output is parsed, off the main thread.
final class EmulatorOutputRouter: Sendable {
    private let stream = Mutex<AttachStream?>(nil)

    func setStream(_ s: AttachStream?) { stream.withLock { $0 = s } }

    func emit(_ bytes: [UInt8], automatic: Bool) {
        guard !bytes.isEmpty, let s = stream.withLock({ $0 }) else { return }
        if automatic {
            s.sendAutomatic(Data(bytes)) // AUTOMATIC_INPUT when negotiated, else DATA
        } else {
            s.send(Data(bytes))
        }
    }
}

/// SwiftTerm's iOS view with Wierdr's input rules:
/// - emulator-generated replies go out tagged as automatic input (the core
///   already answered the queries it can; focus reports are the core's job);
/// - the desktop's terminal keymap (⌥←/→/⌫, ⌘←/→/⌫) and ⌘. as Esc;
/// - ⌘-shortcuts that are not ours are left to the app's menu commands;
/// - a themed key bar above the on-screen keyboard.
final class WierdrTerminalView: TerminalView {
    nonisolated let router = EmulatorOutputRouter()

    /// Became (true) or stopped being (false) the first responder.
    var onFocusChange: ((Bool) -> Void)?
    /// Keys from the key bar or the keymap (to reclaim the size).
    var onUserTouch: (() -> Void)?
    /// A tap or pointer click on the terminal.
    var onTap: (() -> Void)?
    /// The terminal view that has the keyboard, if any.
    private(set) static weak var keyboardOwner: WierdrTerminalView?
    /// A tap gives the terminal the keyboard (iPad). On the iPhone it doesn't:
    /// a tap is a click for the program, and the keyboard comes only when
    /// asked for (`requestKeyboard`: the key panel's swipe, switching panes).
    let tapsTakeKeyboard = !Device.isPhone
    /// Set while the keyboard is asked for on purpose (see `tapsTakeKeyboard`).
    private var keyboardRequested = false

    private var keyBar: TerminalKeyBar?

    /// Emulator options. Kitty graphics get Ghostty's image storage (320 MB per
    /// screen, as the desktop's libghostty) instead of SwiftTerm's 10 MB: pi's
    /// screenshots are up to 2000 px, i.e. up to 16 MB decoded each, so with
    /// 10 MB a larger one is refused (ENOMEM) and each new one evicts the
    /// previous. pi keeps up to 64 MB of off-screen images uploaded and, when
    /// its view scrolls back, only re-places them by id (`a=p`), so evicted
    /// ones never come back.
    static var emulatorOptions: TerminalOptions {
        var o = TerminalOptions.default
        o.kittyGraphics.storageLimitBytesPerScreen = 320_000_000
        return o
    }

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font, options: Self.emulatorOptions)
        let bar = TerminalKeyBar(terminalView: self)
        keyBar = bar
        // Shown with a hardware keyboard too (iPadOS puts it at the bottom):
        // the Magic Keyboard has no Esc, and GCKeyboard cannot tell reliably
        // whether the on-screen keyboard is up.
        inputAccessoryView = bar
        let touch = UITapGestureRecognizer(target: self, action: #selector(touched))
        touch.cancelsTouchesInView = false
        touch.delaysTouchesEnded = false
        touch.delegate = TouchPassthrough.shared
        addGestureRecognizer(touch)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme(_ theme: TerminalTheme) {
        keyBar?.apply(theme: theme)
        keyboardAppearance = theme.isDark ? .dark : .light
        indicatorStyle = theme.isDark ? .white : .black
    }

    /// A hardware keyboard is (probably) attached: focusing a pane then gives it
    /// the keyboard without popping the on-screen one.
    static var hardwareKeyboardConnected: Bool { GCKeyboard.coalesced != nil }

    /// A tap always takes the keyboard (iPad). SwiftTerm spends the first tap
    /// of an unfocused terminal only on focus, except when the program tracks
    /// the mouse (pi, vim with `mouse=a`, ...): then it forwards the click and
    /// stays unfocused, so the keyboard never shows. The click still reaches
    /// the program either way. On the iPhone a tap never takes it.
    @objc private func touched() {
        if tapsTakeKeyboard, !isFirstResponder { _ = becomeFirstResponder() }
        onTap?()
    }

    /// Gives the terminal the keyboard on purpose (also on the iPhone, where taps don't).
    func requestKeyboard() {
        guard !isFirstResponder else { return }
        keyboardRequested = true
        defer { keyboardRequested = false }
        _ = becomeFirstResponder()
    }

    // MARK: Metal scale

    override func layoutSubviews() {
        super.layoutSubviews()
        matchMetalScale()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        matchMetalScale()
    }

    #if DEBUG || WIERDR_LAB
    /// Lab hook: render the Metal view at this scale instead (`nativeScale` reproduces the bug).
    static var debugMetalScale: CGFloat?
    #endif

    /// SwiftTerm's Metal renderer sizes cells and glyphs in pixels of the
    /// screen's `scale`, but an iOS `MTKView` renders at the screen's
    /// `nativeScale`. They differ under Display Zoom (an iPad Pro on "More
    /// Space": scale 2, nativeScale ≈ 1.72): the drawable is smaller than the
    /// grid, so the picture is magnified and the right columns and the top rows
    /// (rows are laid out from the bottom) fall outside the view. Render at
    /// `scale`; the compositor scales it to the panel like any other layer.
    func matchMetalScale() {
        guard let mtk = subviews.first(where: { $0 is MTKView }) else { return }
        var scale = window?.screen.scale ?? traitCollection.displayScale
        #if DEBUG || WIERDR_LAB
        if let s = Self.debugMetalScale { scale = s }
        #endif
        guard scale > 0, mtk.contentScaleFactor != scale else { return }
        mtk.contentScaleFactor = scale
        mtk.setNeedsLayout()
        mtk.setNeedsDisplay()
    }

    // MARK: Emulator output

    nonisolated override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        // Focus reports: the core sends them itself on FOCUS frames (mode 1004).
        if data.count == 3, data.elementsEqual([0x1b, 0x5b, 0x49]) || data.elementsEqual([0x1b, 0x5b, 0x4f]) {
            return
        }
        // Output is parsed off the main thread, so anything produced there is
        // the emulator answering the program. On the main thread it is the
        // user (mouse reports, paste).
        router.emit(Array(data), automatic: !Thread.isMainThread)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        // iPhone: SwiftTerm's own tap (and UIKit restoring focus) doesn't bring the keyboard.
        if !tapsTakeKeyboard, !keyboardRequested, !isFirstResponder { return false }
        let wasFirst = isFirstResponder
        let ok = super.becomeFirstResponder()
        if ok { Self.keyboardOwner = self }
        if ok && !wasFirst { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let wasFirst = isFirstResponder
        let ok = super.resignFirstResponder()
        if ok && wasFirst {
            if Self.keyboardOwner === self { Self.keyboardOwner = nil }
            onFocusChange?(false)
        }
        return ok
    }

    // MARK: Keyboard

    struct MappedKey {
        var name: String
        var key: UIKeyboardHIDUsage
        var modifiers: UIKeyModifierFlags
        var bytes: [UInt8]
    }

    /// The desktop's "terminal" keymap (`~/.config/herdr-app/keys.json`), plus ⌘. as Esc
    /// for iPad keyboards without an Esc key.
    static let keymap: [MappedKey] = [
        MappedKey(name: "alt-left", key: .keyboardLeftArrow, modifiers: .alternate, bytes: [0x1b, 0x62]),        // ESC b
        MappedKey(name: "alt-right", key: .keyboardRightArrow, modifiers: .alternate, bytes: [0x1b, 0x66]),      // ESC f
        MappedKey(name: "alt-backspace", key: .keyboardDeleteOrBackspace, modifiers: .alternate, bytes: [0x17]), // ^W
        MappedKey(name: "cmd-left", key: .keyboardLeftArrow, modifiers: .command, bytes: [0x01]),                // ^A
        MappedKey(name: "cmd-right", key: .keyboardRightArrow, modifiers: .command, bytes: [0x05]),              // ^E
        MappedKey(name: "cmd-backspace", key: .keyboardDeleteOrBackspace, modifiers: .command, bytes: [0x15]),   // ^U
        MappedKey(name: "cmd-period", key: .keyboardPeriod, modifiers: .command, bytes: [0x1b]),                 // Esc
    ]

    /// Set when a key command (see `TerminalContainerView.keyCommands`) sent a mapping.
    var lastKeyCommand: (UIKeyboardHIDUsage, Date)?

    static func mappedBytes(for key: UIKey) -> [UInt8]? {
        let mods = key.modifierFlags.intersection([.command, .alternate, .control, .shift])
        return keymap.first { $0.key == key.keyCode && $0.modifiers == mods }?.bytes
    }

    /// Debug hook (the lab logs key presses with it).
    static var keyLog: ((String) -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let log = Self.keyLog, let key = press.key {
                log("press \(key.keyCode.rawValue) mods \(key.modifierFlags.rawValue) chars \(key.characters.debugDescription) mapped \(Self.mappedBytes(for: key) != nil)")
            }
            if let key = press.key, let bytes = Self.mappedBytes(for: key) {
                // Already sent by the key command for this press?
                if let (k, t) = lastKeyCommand, k == key.keyCode, Date().timeIntervalSince(t) < 0.05 { continue }
                onUserTouch?()
                send(bytes)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    // ⌘C / ⌘V come through UIKit's standard copy:/paste: actions, which
    // SwiftTerm implements (copy takes the selection; paste honors bracketed
    // paste mode 2004).

    /// Text typed through the same path as the on-screen keyboard (lab scripts).
    func typeText(_ text: String) {
        for ch in text {
            insertText(ch == "\r" ? "\n" : String(ch))
        }
    }
}

/// Lets our "user touched the terminal" recognizer run beside SwiftTerm's own.
private final class TouchPassthrough: NSObject, UIGestureRecognizerDelegate {
    @MainActor static let shared = TouchPassthrough()
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
}
