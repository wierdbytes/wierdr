import UIKit
import Observation
import SwiftTerm
import HerdrCore

/// One live terminal of the core, shown in a SwiftTerm view.
///
/// Owns the emulator view (created once, reused across SwiftUI updates and
/// pane moves) and its attach stream: attaches when the view has a size and is
/// wanted, sends FACTS then RESIZE when the grid changes, FOCUS with the
/// keyboard focus, returns flow-control credit after feeding, and reattaches
/// (fresh emulator; the core repaints screen + 2000 lines of history) after a
/// connection change, a lost program or a font change.
///
/// Create through `TerminalSessionPool.session(for:)`.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        /// Not attached (not shown yet, or detached while off screen).
        case idle
        case connecting
        case live
        /// Waiting for a new connection or for a lost (kept) program's new shell.
        case reconnecting
        /// The program ended: exited / killed / finished (or the terminal is gone).
        case ended(Ended)
        case error(String)
    }

    struct Ended: Equatable {
        var reason: String
        var exitCode: Int?
        var signal: Int?

        /// "Process exited (0)", "Process killed", ...
        var message: String {
            switch reason {
            case "exited":
                if let signal { return "Process exited (signal \(signal))" }
                return "Process exited (\(exitCode.map(String.init) ?? "?"))"
            case "killed": return "Process killed"
            case "not_found": return "Terminal is gone"
            default: return "Process \(reason)"
            }
        }
    }

    nonisolated let address: String
    nonisolated var id: String { address }

    private(set) var state: State = .idle
    /// OSC 0/2 title from the program ("" until it sets one).
    private(set) var title: String = ""
    /// The emulator's grid (the size we report to the core).
    private(set) var cols = 0
    private(set) var rows = 0
    /// Whether the terminal view has the keyboard focus.
    private(set) var hasKeyboardFocus = false

    @ObservationIgnored let terminalView: WierdrTerminalView
    /// Padding + theme background around the emulator view; what `TerminalSurface` embeds.
    @ObservationIgnored let container: TerminalContainerView

    @ObservationIgnored private(set) var theme: TerminalTheme
    @ObservationIgnored private(set) var fontSize: CGFloat
    @ObservationIgnored private var connection: CoreConnection?
    @ObservationIgnored private var stream: AttachStream?
    @ObservationIgnored private var attachTask: Task<Void, Never>?
    @ObservationIgnored private var requested: (cols: Int, rows: Int)?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Double = 0.5
    @ObservationIgnored private var generation = 0
    @ObservationIgnored let pipe = FeedPipe()
    @ObservationIgnored private var sentGrid: (cols: Int, rows: Int)?
    @ObservationIgnored private var sentDisplay: Display?
    @ObservationIgnored private var suspendGridUpdates = false

    /// On screen (its container is in a window).
    @ObservationIgnored private(set) var isVisible = false
    /// When it was last on screen (for the pool's idle detach).
    @ObservationIgnored private(set) var lastVisible = Date()
    /// The pool's say: keep (or get) a stream. Cleared when detached for idleness.
    @ObservationIgnored var wantsAttach = false
    /// Called with every state change (the pool uses it for bookkeeping).
    @ObservationIgnored var onStateChange: ((TerminalSession) -> Void)?
    /// A tap on the terminal (set by `TerminalSurface`: the app focuses the pane).
    @ObservationIgnored var onTap: (() -> Void)?

    /// Whether a stream is open or being opened.
    var isAttached: Bool { stream != nil || attachTask != nil }
    /// The core connection terminals attach on (nil while disconnected).
    var currentConnection: CoreConnection? { connection }

    init(address: String, theme: TerminalTheme, fontSize: CGFloat, useMetal: Bool) {
        self.address = address
        self.theme = theme
        self.fontSize = fontSize
        let fonts = TerminalFonts.make(size: fontSize)
        let view = WierdrTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), font: fonts.normal)
        view.setFonts(normal: fonts.normal, bold: fonts.bold, italic: fonts.italic, boldItalic: fonts.boldItalic)
        terminalView = view
        container = TerminalContainerView(terminalView: view, useMetal: useMetal)
        configureView()
        applyColors()
        container.session = self
    }

    // MARK: View setup

    private func configureView() {
        let v = terminalView
        v.terminalDelegate = self
        v.optionAsMetaKey = true
        v.useBrightColors = false            // bold is bold, not bright (as Ghostty)
        v.collapseBrightColorsToBase = false
        v.glyphFallbackProvider = NerdFontFallback.shared
        v.linkReporting = .implicit
        v.allowMouseReporting = true
        v.changeScrollback(10_000)
        v.onFocusChange = { [weak self] focused in self?.focusChanged(focused) }
        v.onUserTouch = { [weak self] in self?.userActivity() }
        v.onTap = { [weak self] in
            self?.userActivity()
            self?.onTap?()
        }
    }

    private func applyColors() {
        let v = terminalView
        v.installColors(theme.palette)
        v.nativeForegroundColor = theme.foregroundColor
        v.nativeBackgroundColor = theme.backgroundColor
        v.caretColor = theme.cursorColor
        v.caretTextColor = theme.backgroundColor
        v.selectedTextBackgroundColor = theme.selectionColor
        v.applyTheme(theme)
        container.backgroundColor = theme.backgroundColor
    }

    /// New colors and/or font size. Colors apply live (FACTS tells the core);
    /// a font change reattaches so the repaint matches the new grid.
    func apply(theme newTheme: TerminalTheme, fontSize newSize: CGFloat) {
        let themeChanged = newTheme != theme
        let fontChanged = newSize != fontSize
        guard themeChanged || fontChanged else { return }
        theme = newTheme
        if themeChanged { applyColors() }
        if fontChanged {
            fontSize = newSize
            let fonts = TerminalFonts.make(size: newSize)
            suspendGridUpdates = true
            terminalView.setFonts(normal: fonts.normal, bold: fonts.bold, italic: fonts.italic, boldItalic: fonts.boldItalic)
            suspendGridUpdates = false
            readGrid()
            if isAttached { reattach() }
        } else {
            sendFactsIfChanged()
        }
    }

    func setUseMetal(_ on: Bool) { container.setUseMetal(on) }
    var isUsingMetal: Bool { terminalView.isUsingMetalRenderer }

    // MARK: Pool / app inputs

    func setConnection(_ newConnection: CoreConnection?) {
        guard newConnection !== connection else { return }
        let hadStream = isAttached || state == .live || state == .reconnecting || state == .connecting
        connection = newConnection
        dropStream()
        retryTask?.cancel()
        retryDelay = 0.5
        if case .ended = state { return }
        if newConnection == nil {
            if hadStream { setState(.reconnecting) }
        } else if wantsAttach || hadStream {
            if hadStream { setState(.reconnecting) }
            attachIfPossible()
        }
    }

    /// The core restarted a lost kept terminal (`restarted` event): reattach now.
    func terminalRestarted() {
        switch state {
        case .reconnecting, .ended, .error:
            retryTask?.cancel()
            retryDelay = 0.5
            dropStream()
            setState(.reconnecting)
            attachIfPossible()
        default:
            break
        }
    }

    /// Attach (again) if wanted; resets an `.error`.
    func retry() {
        if case .ended = state { return }
        wantsAttach = true
        dropStream()
        setState(connection == nil ? .reconnecting : .connecting)
        attachIfPossible()
    }

    /// Close the stream (off screen for a while). Shown again = reattach.
    func detach() {
        wantsAttach = false
        retryTask?.cancel()
        let wasEnded: Bool = { if case .ended = state { return true } else { return false } }()
        dropStream()
        if !wasEnded { setState(.idle) }
    }

    /// For good: the terminal was removed or the pool is torn down.
    func close() {
        detach()
        terminalView.onFocusChange = nil
        terminalView.onUserTouch = nil
        terminalView.onTap = nil
        container.removeFromSuperview()
    }

    func visibilityChanged(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        lastVisible = Date()
        if visible {
            wantsAttach = true
            attachIfPossible()
        }
    }

    // MARK: Attach

    private func currentGrid() -> (cols: Int, rows: Int)? {
        guard container.hasLaidOut else { return nil }
        let d = terminalView.terminalDimensions
        guard d.cols >= 2, d.rows >= 1 else { return nil }
        return (d.cols, d.rows)
    }

    /// Cell size in device pixels, as the emulator lays cells out.
    private func cellPixels() -> Display.CellSize? {
        let d = terminalView.terminalDimensions
        guard d.cols > 0, d.rows > 0 else { return nil }
        let frame = terminalView.getOptimalFrameSize()
        let scale = container.window?.screen.scale ?? container.traitCollection.displayScale
        let s = scale > 0 ? scale : 2
        let w = (frame.width / CGFloat(d.cols) * s).rounded()
        let h = (frame.height / CGFloat(d.rows) * s).rounded()
        guard w > 0, h > 0 else { return nil }
        return Display.CellSize(width: UInt32(w), height: UInt32(h))
    }

    private func currentDisplay() -> Display { theme.display(cellPixels: cellPixels()) }

    func attachIfPossible() {
        guard wantsAttach, let connection, stream == nil, attachTask == nil else { return }
        if case .ended = state { return }
        guard let grid = currentGrid() else { return } // after the first layout
        retryTask?.cancel()
        generation += 1
        let gen = generation
        if state != .reconnecting { setState(.connecting) }
        let display = currentDisplay()
        requested = grid
        let params = AttachParams(terminal: address, cols: UInt16(clamping: grid.cols), rows: UInt16(clamping: grid.rows),
                                  history: 2000, display: display)
        attachTask = Task { [weak self] in
            do {
                let s = try await connection.attach(params)
                guard let self else { s.close(); return }
                self.didAttach(s, gen: gen, on: connection, grid: grid, display: display)
            } catch {
                self?.attachFailed(error, gen: gen)
            }
        }
    }

    private func didAttach(_ s: AttachStream, gen: Int, on conn: CoreConnection, grid: (cols: Int, rows: Int), display: Display) {
        guard gen == generation, conn === connection else { s.close(); return }
        attachTask = nil
        // The first paint is for the size we asked; if the grid moved meanwhile, ask again.
        if let now = currentGrid(), now != grid {
            s.close()
            attachIfPossible()
            return
        }
        stream = s
        sentGrid = grid
        sentDisplay = display
        terminalView.router.setStream(s)
        pipe.begin(gen) // the emulator is reset right before the first paint
        let pipe = self.pipe
        let view = terminalView
        Task.detached(priority: .userInitiated) { [weak self] in
            for await event in s.output {
                switch event {
                case .data(let bytes):
                    pipe.feed(bytes, gen: gen, into: view, stream: s)
                case .resize:
                    break // only observers get these
                case .closed(let reason):
                    await pipe.drain()
                    await self?.streamClosed(reason, gen: gen)
                }
            }
        }
        retryDelay = 0.5
        setState(.live)
        if terminalView.isFirstResponder { s.focus(true) }
        sendFactsIfChanged()
    }

    private func attachFailed(_ error: Error, gen: Int) {
        guard gen == generation else { return }
        attachTask = nil
        if error is CancellationError { return }
        if let e = error as? CoreError {
            if e.isUnavailable {
                setState(.reconnecting)        // a kept terminal waiting for its new shell
                scheduleRetry()
            } else if e.isNotFound {
                setState(.ended(Ended(reason: "not_found")))
            } else if e.kind == "finished" {
                setState(.ended(Ended(reason: "finished")))
            } else {
                setState(.error(e.message))
            }
        } else if error is ConnectionError {
            setState(.reconnecting)            // a new connection reattaches
        } else {
            setState(.error(error.localizedDescription))
        }
    }

    private func streamClosed(_ reason: JSONValue?, gen: Int) {
        guard gen == generation else { return } // a stream we replaced
        stream = nil
        terminalView.router.setStream(nil)
        guard let reason else {
            if state == .live || state == .connecting { setState(.idle) }
            return
        }
        let end = TerminalEnd(reason)
        switch end.reason ?? "" {
        case "exited", "killed", "finished":
            setState(.ended(Ended(reason: end.reason ?? "exited", exitCode: end.exitCode, signal: end.signal)))
        case "disconnected":
            setState(.reconnecting)            // wait for setConnection(new)
        default:
            // A kept terminal lost its program (signaled, holder_lost, ...):
            // its new shell comes with `restarted`; retry meanwhile.
            setState(.reconnecting)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.attachIfPossible()
        }
    }

    /// Close the stream (if any) and forget it; its events are ignored from now on.
    private func dropStream() {
        generation += 1
        attachTask?.cancel()
        attachTask = nil
        stream?.close()
        stream = nil
        sentGrid = nil
        terminalView.router.setStream(nil)
    }

    private func reattach() {
        dropStream()
        setState(.connecting)
        attachIfPossible()
    }

    private func setState(_ s: State) {
        guard s != state else { return }
        state = s
        onStateChange?(self)
    }

    // MARK: Size, facts, focus

    /// The emulator's grid changed (layout, rotation, font).
    fileprivate func gridChanged(cols c: Int, rows r: Int) {
        cols = c
        rows = r
        guard !suspendGridUpdates else { return }
        if let stream {
            sendFactsIfChanged()
            if sentGrid.map({ $0 != (c, r) }) ?? true {
                stream.resize(cols: c, rows: r)
                sentGrid = (c, r)
            }
        } else if attachTask == nil {
            attachIfPossible()
        }
    }

    fileprivate func readGrid() {
        let d = terminalView.terminalDimensions
        cols = d.cols
        rows = d.rows
    }

    /// Layout settled for the first time (or again): attach when wanted.
    fileprivate func layoutChanged() {
        readGrid()
        if stream == nil, attachTask == nil { attachIfPossible() }
    }

    private func sendFactsIfChanged() {
        guard let stream else { return }
        let display = currentDisplay()
        guard display != sentDisplay else { return }
        stream.facts(display)
        sentDisplay = display
    }

    private func focusChanged(_ focused: Bool) {
        hasKeyboardFocus = focused
        stream?.focus(focused)
    }

    /// A touch or typing: take the size back from another viewer (as the desktop does on mouse-down).
    func userActivity() {
        if let stream, let grid = currentGrid() {
            stream.resize(cols: grid.cols, rows: grid.rows)
            sentGrid = grid
        }
    }
}

// MARK: - Input from the app (iPhone key panel)

extension TerminalSession {
    /// A key the app sends on the person's behalf (the iPhone's key panel).
    enum Key: Hashable {
        case escape, enter, tab, backtab, up, down, left, right
        /// A control character (`0x03` = Ctrl+C).
        case control(UInt8)
        /// Plain text typed as keys.
        case text(String)
    }

    /// Whether input reaches the program now (a stream is open).
    var acceptsInput: Bool { state == .live }

    /// Sends a key as typed (arrows follow the program's cursor-key mode).
    func send(key: Key) {
        userActivity()
        let v = terminalView
        switch key {
        case .escape: v.send([0x1b])
        case .enter: v.send([0x0d])
        case .tab: v.send([0x09])
        case .backtab: v.send([0x1b, 0x5b, 0x5a])
        case .up: v.sendKeyUp()
        case .down: v.sendKeyDown()
        case .left: v.sendKeyLeft()
        case .right: v.sendKeyRight()
        case .control(let byte): v.send([byte])
        case .text(let s): v.send(Array(s.utf8))
        }
    }

    /// Text as one paste (bracketed when the program asked for it, so line
    /// breaks stay in it), then Return when `submit`. The iPhone's key panel
    /// pastes clipboard text and image paths this way, without Return.
    func send(text: String, submit: Bool) {
        userActivity()
        if !text.isEmpty { terminalView.pasteText(text) }
        guard submit else { return }
        if text.isEmpty {
            terminalView.send([0x0d])
        } else {
            // A separate write a moment later, so no program takes it for part of the paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.terminalView.send([0x0d])
            }
        }
    }

    /// Puts a file beside the terminal on its machine (`terminal.put`, as a
    /// pasted image on the desktop) and returns its path there.
    func put(_ data: Data, name: String) async throws -> String {
        guard let connection = currentConnection else { throw ConnectionError.disconnected("Not connected") }
        return try await connection.putFile(address, name: name, data: data).path
    }

    /// Gives the terminal the keyboard (typing straight into it, with the key bar).
    func takeKeyboard() {
        if !terminalView.isFirstResponder { _ = terminalView.becomeFirstResponder() }
    }

    func releaseKeyboard() {
        if terminalView.isFirstResponder { _ = terminalView.resignFirstResponder() }
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Keyboard and text input (DATA: human activity, takes size ownership).
        if let log = WierdrTerminalView.keyLog { log("input \(data.map { String(format: "%02x", $0) }.joined(separator: " "))") }
        guard let stream else { return }
        stream.send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        gridChanged(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        guard let url = URL(string: request.link), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52 from the program (e.g. an agent's "copy" command).
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

// MARK: - Container

/// The emulator view inside the pane padding (14 x 12 pt) on the theme
/// background. The emulator's own cols x rows = the desktop's grid formula:
/// floor((w - 2·padX) / cellW) x floor((h - 2·padY) / cellH).
final class TerminalContainerView: UIView {
    /// 14 x 12 as the desktop; tighter on iPhone, where every column counts.
    static var padding: UIEdgeInsets {
        Device.isPhone ? UIEdgeInsets(top: 6, left: 8, bottom: 4, right: 8)
                       : UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    }

    weak var session: TerminalSession?
    let terminalView: WierdrTerminalView
    private(set) var hasLaidOut = false
    private var wantsMetal: Bool

    init(terminalView: WierdrTerminalView, useMetal: Bool) {
        self.terminalView = terminalView
        self.wantsMetal = useMetal
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(terminalView)
        if Device.isPhone {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            addGestureRecognizer(pinch)
        }
    }

    // MARK: Pinch: text size (iPhone)

    private var pinchStart: CGFloat = 0
    private lazy var sizeBadge: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        l.textAlignment = .center
        l.layer.cornerRadius = 10
        l.layer.cornerCurve = .continuous
        l.clipsToBounds = true
        l.alpha = 0
        addSubview(l)
        return l
    }()

    /// Two fingers change the terminal text size for every terminal (Settings'
    /// value); the badge shows the size, the terminals follow when the fingers lift.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let current = session?.fontSize ?? TerminalFonts.defaultSize
        func target() -> CGFloat {
            let r = TerminalFonts.sizeRange
            return min(r.upperBound, max(r.lowerBound, (pinchStart * g.scale).rounded()))
        }
        switch g.state {
        case .began:
            pinchStart = current
            showSize(current)
        case .changed:
            showSize(target())
        case .ended:
            let size = target()
            hideSize()
            if size != current {
                UserDefaults.standard.set(Double(size), forKey: TerminalFonts.sizeKey)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        default:
            hideSize()
        }
    }

    private func showSize(_ size: CGFloat) {
        let badge = sizeBadge
        let theme = session?.theme ?? .atomOneDark
        badge.backgroundColor = theme.foregroundColor.withAlphaComponent(0.88)
        badge.textColor = theme.backgroundColor
        badge.text = "\(Int(size)) pt"
        badge.frame = CGRect(x: (bounds.width - 84) / 2, y: (bounds.height - 40) / 2, width: 84, height: 40)
        bringSubviewToFront(badge)
        badge.alpha = 1
    }

    private func hideSize() {
        UIView.animate(withDuration: 0.25, delay: 0.3) { self.sizeBadge.alpha = 0 }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.inset(by: Self.padding)
        guard inner.width > 0, inner.height > 0 else { return }
        if terminalView.frame != inner { terminalView.frame = inner }
        terminalView.layoutIfNeeded()
        let first = !hasLaidOut
        hasLaidOut = true
        if first || window != nil { session?.layoutChanged() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, wantsMetal, !terminalView.isUsingMetalRenderer {
            try? terminalView.setUseMetal(true)
            terminalView.matchMetalScale()
        }
        session?.visibilityChanged(window != nil)
    }

    func setUseMetal(_ on: Bool) {
        wantsMetal = on
        guard window != nil, on != terminalView.isUsingMetalRenderer else { return }
        try? terminalView.setUseMetal(on)
        terminalView.matchMetalScale()
    }

    /// The terminal keymap as key commands with priority over the text system,
    /// which otherwise eats ⌥/⌘ + ←/→/⌫ (UITextInput word/line editing) before
    /// they reach `pressesBegan`. They live here, on the terminal view's next
    /// responder, because SwiftTerm's `canPerformAction` (not overridable)
    /// refuses every action it does not know, which disables key commands on
    /// the terminal view itself.
    override var keyCommands: [UIKeyCommand]? {
        terminalView.isFirstResponder ? mappedKeyCommands : []
    }

    /// Built once: UIKit asks for `keyCommands` often, and new instances each
    /// time make it rebuild its shortcut tables.
    private lazy var mappedKeyCommands: [UIKeyCommand] = {
        var commands: [UIKeyCommand] = []
        for m in WierdrTerminalView.keymap {
            let input: String
            switch m.key {
            case .keyboardLeftArrow: input = UIKeyCommand.inputLeftArrow
            case .keyboardRightArrow: input = UIKeyCommand.inputRightArrow
            case .keyboardDeleteOrBackspace: input = UIKeyCommand.inputDelete
            case .keyboardPeriod: input = "."
            default: continue
            }
            let c = UIKeyCommand(input: input, modifierFlags: m.modifiers, action: #selector(mappedKeyCommand(_:)))
            c.wantsPriorityOverSystemBehavior = true
            commands.append(c)
        }
        return commands
    }()

    @objc private func mappedKeyCommand(_ sender: UIKeyCommand) {
        let key: UIKeyboardHIDUsage
        switch sender.input {
        case UIKeyCommand.inputLeftArrow: key = .keyboardLeftArrow
        case UIKeyCommand.inputRightArrow: key = .keyboardRightArrow
        case UIKeyCommand.inputDelete: key = .keyboardDeleteOrBackspace
        case ".": key = .keyboardPeriod
        default: return
        }
        let mods = sender.modifierFlags.intersection([.command, .alternate, .control, .shift])
        guard let m = WierdrTerminalView.keymap.first(where: { $0.key == key && $0.modifiers == mods }) else { return }
        WierdrTerminalView.keyLog?("key command \(m.name)")
        terminalView.lastKeyCommand = (key, Date())
        terminalView.onUserTouch?()
        terminalView.send(m.bytes)
    }
}

// MARK: - Feeding

/// Feeds a stream's bytes to the emulator off the main thread, in order, and
/// returns credit after each chunk. One serial queue per session; a new
/// generation (a new stream) resets the emulator right before its first byte,
/// so a repaint never mixes with the previous content.
final class FeedPipe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pw.xff.wierdr.terminal.feed", qos: .userInteractive)
    // Confined to `queue`.
    private var current = -1
    private var needsReset = false
    /// Totals (bytes, chunks, seconds spent parsing), for diagnostics.
    private(set) var stats = (bytes: 0, chunks: 0, seconds: 0.0)

    func readStats() async -> (bytes: Int, chunks: Int, seconds: Double) {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.stats) } }
    }

    func begin(_ gen: Int) {
        queue.async {
            self.current = gen
            self.needsReset = true
        }
    }

    func feed(_ bytes: Data, gen: Int, into view: TerminalView, stream: AttachStream) {
        nonisolated(unsafe) let view = view
        queue.async {
            guard gen == self.current else {
                stream.consumed(bytes.count)
                return
            }
            if self.needsReset {
                self.needsReset = false
                view.feed(text: "\u{1b}c")       // RIS: screen, scrollback, modes
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            view.feed(byteArray: [UInt8](bytes)[...])
            self.stats.bytes += bytes.count
            self.stats.chunks += 1
            self.stats.seconds += CFAbsoluteTimeGetCurrent() - t0
            stream.consumed(bytes.count)
        }
    }

    /// Waits until everything queued so far was fed.
    func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
    }
}
