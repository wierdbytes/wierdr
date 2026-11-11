import SwiftUI
import UIKit
import PhotosUI
import WierdrModel

/// The iPhone's keys, at the right edge: a swipe from the right edge (or a
/// tap on the grip there) slides out a narrow column of large keys over the
/// terminal, within the right thumb's reach, with or without the keyboard
/// (then above it). The column has no backing and the keys are translucent,
/// so it hides as little of the terminal as it can. It scrolls past its
/// ends, so the first and the last key can come to the thumb: about a third
/// of the screen up from its bottom (with the keyboard up, the first one to
/// the middle of the column above it, and ⏎ no higher than its bottom);
/// each time it opens with ⏎ at its bottom, where the keys an agent asks
/// for are (⏎, esc, arrows, tab, 1 2 3, y n), with ctrl keys, the keyboard
/// and inserting (text, a photo, a copied image) above. Keys don't close
/// it, so ↓ ↓ ⏎ is three taps; a swipe to the right or a tap on the terminal
/// does. Type opens the message field above the keyboard (`PhoneComposeBar`);
/// a tap on the terminal types straight into it, with its key bar.
struct PhoneKeyPanel: View {
    var address: String
    /// On screen (even partly): each time it comes out, it starts at its bottom.
    var shown: Bool
    /// The window's height (where a third of the screen from the bottom is).
    var screenHeight: CGFloat
    var close: () -> Void

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    @State private var pressed = 0
    @State private var picking = false
    @State private var picked: PhotosPickerItem?
    /// The photo being picked goes into the message (it was open when Photo was tapped).
    @State private var pickIntoMessage = false
    @State private var uploading = false
    /// The column's top and height in the window: how far past its ends it scrolls.
    @State private var frame: CGRect = .zero

    static let width: CGFloat = 96
    fileprivate static let keyHeight: CGFloat = 52
    private static let bottomID = "bottom"

    var body: some View {
        let session = services.terminalSession(address)
        let typing = session?.hasKeyboardFocus == true || composing
        // Room past either end, so the first or the last key can come to the thumb.
        // With the keyboard up, none below: ⏎ stops at the column's bottom, just above it.
        let rest = restLine(typing: typing)
        let top = max(12, rest - Self.keyHeight / 2)
        let bottom = typing ? 12 : max(12, frame.height - rest - Self.keyHeight / 2)
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                group {
                    PanelButton(icon: "doc.on.clipboard", caption: "Paste", a11y: "Paste Text") { pasteText(session) }
                    PanelButton(icon: "photo.on.rectangle", caption: "Photo", a11y: "Attach a Photo", busy: uploading) {
                        guard session != nil else { return controller.toast(unavailable) }
                        // The picker takes the keyboard away: remember where the path goes.
                        pickIntoMessage = composing
                        picking = true
                    }
                    PanelButton(icon: "photo.badge.plus", caption: "Image", a11y: "Paste an Image", busy: uploading) {
                        // Asking first doesn't trigger the paste prompt.
                        guard UIPasteboard.general.hasImages else { return controller.toast("No image on the clipboard") }
                        let intoMessage = composing
                        Task {
                            await attach(UIPasteboard.general.image.flatMap { $0.pngData() }, session,
                                         intoMessage: intoMessage, missing: "Couldn't read that image")
                        }
                    }
                    if typing {
                        PanelButton(icon: "keyboard.chevron.compact.down", caption: "Hide", a11y: "Hide the Keyboard") {
                            if composing { controller.composing = nil }
                            session?.releaseKeyboard()
                        }
                    } else {
                        PanelButton(icon: "keyboard", caption: "Type", a11y: "Write a Message") {
                            close()
                            controller.composing = address
                        }
                    }
                }
                group {
                    key("^R", .control(0x12), a11y: "Control R")
                    key("^L", .control(0x0c), a11y: "Control L")
                    key("^D", .control(0x04), a11y: "Control D")
                    key("^J", .control(0x0a), a11y: "Control J")
                    key("^C", .control(0x03), a11y: "Control C")
                }
                group {
                    key("!", .text("!"), a11y: "Exclamation mark")
                    key("@", .text("@"), a11y: "At")
                    key("/", .text("/"), a11y: "Slash")
                }
                group {
                    key("n", .text("n"), a11y: "n")
                    key("y", .text("y"), a11y: "y")
                    key("3", .text("3"), a11y: "3")
                    key("2", .text("2"), a11y: "2")
                    key("1", .text("1"), a11y: "1")
                }
                group {
                    key("⇧tab", .backtab, a11y: "Shift Tab")
                    key("tab", .tab, a11y: "Tab")
                }
                group {
                    key("←", .left, symbol: "arrow.left", repeats: true, a11y: "Left")
                    key("→", .right, symbol: "arrow.right", repeats: true, a11y: "Right")
                    key("↑", .up, symbol: "arrow.up", repeats: true, a11y: "Up")
                    key("↓", .down, symbol: "arrow.down", repeats: true, a11y: "Down")
                }
                group {
                    key("esc", .escape, a11y: "Escape")
                    key("⏎", .enter, symbol: "return", prominent: true, a11y: "Return")
                }
                .padding(.bottom, 12)
                .id(Self.bottomID)
            }
            .padding(.horizontal, 7)
            .padding(.top, top)
            .padding(.bottom, bottom - 12)
        }
        .onChange(of: shown) { _, shown in if shown { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
        .task(id: frame.height) {
            // The keyboard came or went (or the screen turned): ⏎ back at the
            // bottom, once the scroll view has finished growing or shrinking.
            guard shown else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
        }
        // Only the top and height (not x, which the back swipe moves every frame).
        .onGeometryChange(for: CGRect.self) { p in
            let f = p.frame(in: .global)
            return CGRect(x: 0, y: f.minY, width: 0, height: f.height)
        } action: { frame = $0 }
        .frame(width: Self.width)
        // No backing: only the keys cover the terminal, and they let it show through.
        .sensoryFeedback(.impact(weight: .light), trigger: pressed)
        .photosPicker(isPresented: $picking, selection: $picked, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await attach(data, session, intoMessage: pickIntoMessage, missing: "Couldn't read that image")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key Panel")
    }

    /// Where the first or the last key comes to rest at the end of the
    /// scroll, from the column's top: a third of the screen up from its
    /// bottom; with the keyboard up, the middle of the column (above it).
    private func restLine(typing: Bool) -> CGFloat {
        guard !typing, screenHeight > 0 else { return frame.height / 2 }
        return min(max(screenHeight * 2 / 3 - frame.minY, Self.keyHeight), frame.height - Self.keyHeight)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 6, content: content)
    }

    private func key(_ label: String, _ key: TerminalSession.Key, symbol: String? = nil,
                     repeats: Bool = false, prominent: Bool = false, a11y: String) -> some View {
        PanelButton(label: label, icon: symbol, a11y: a11y, repeats: repeats, prominent: prominent) {
            send(key)
        }
    }

    /// Why input can't go anywhere: the demo has no terminals; live, the
    /// session is not there yet (or the terminal is gone).
    private var unavailable: String {
        controller.isDemo ? "Not available in the demo" : "The terminal is not connected yet"
    }

    /// The message field is open (`PhoneComposeBar`): text and image paths go into it.
    private var composing: Bool { controller.composing == address }

    /// Adds to the message (a space before, unless at a line's start) and opens it again
    /// if something (the paste prompt, the photo picker) took the keyboard away.
    private func addToMessage(_ s: String) {
        var text = controller.drafts[address] ?? ""
        if let last = text.last, !last.isWhitespace { text += " " }
        controller.drafts[address] = text + s
        controller.composing = address
        pressed += 1
    }

    private func live(_ session: TerminalSession?) -> TerminalSession? {
        guard let session else { controller.toast(unavailable); return nil }
        guard session.acceptsInput else { controller.toast("The terminal is not connected yet"); return nil }
        return session
    }

    private func send(_ key: TerminalSession.Key) {
        guard let session = live(services.terminalSession(address)) else { return }
        session.send(key: key)
        pressed += 1
    }

    /// The clipboard's text into the message while it is open; otherwise into
    /// the program, as a paste (bracketed when it asked), no Return.
    private func pasteText(_ session: TerminalSession?) {
        let intoMessage = composing
        guard intoMessage || live(session) != nil else { return }
        guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string, !text.isEmpty else {
            return controller.toast("No text on the clipboard")
        }
        if intoMessage { return addToMessage(text) }
        session?.send(text: text, submit: false)
        pressed += 1
    }

    /// Puts the image beside the terminal on its machine (`terminal.put`, like
    /// pasting an image on the desktop) and adds its path to the message, or
    /// types it into the program.
    private func attach(_ data: Data?, _ session: TerminalSession?, intoMessage: Bool, missing: String) async {
        guard let session = live(session) else { return }
        guard let data else { return controller.toast(missing) }
        uploading = true
        defer { uploading = false }
        // Decoding a 48 MP photo takes a moment and memory: off the main thread.
        guard let image = await Task.detached(priority: .userInitiated, operation: { ImageForAgent(data) }).value else {
            return controller.toast("Couldn't read that image")
        }
        do {
            let path = try await session.put(image.data, name: image.name)
            if intoMessage { return addToMessage(path + " ") }
            session.send(text: path + " ", submit: false)
            pressed += 1
        } catch {
            controller.toast("Image: \(error.localizedDescription)")
        }
    }
}

/// One key of the panel: as wide as the column, 52 pt tall, translucent.
private struct PanelButton: View {
    var label: String?
    var icon: String?
    var caption: String?
    var a11y: String
    var repeats = false
    var prominent = false
    var busy = false
    var action: () -> Void

    @Environment(\.theme) private var theme

    init(label: String? = nil, icon: String? = nil, caption: String? = nil, a11y: String,
         repeats: Bool = false, prominent: Bool = false, busy: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.caption = caption
        self.a11y = a11y
        self.repeats = repeats
        self.prominent = prominent
        self.busy = busy
        self.action = action
    }

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let color = prominent ? theme.accentForeground : theme.foreground
        Button(action: action) {
            VStack(spacing: 3) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: caption == nil ? 19 : 17, weight: .semibold))
                } else if let label {
                    Text(label)
                        .font(label.count > 2 ? .ui(16, .medium) : .mono(20, .medium))
                }
                if let caption {
                    Text(caption).font(.ui(10.5, .medium)).foregroundStyle(theme.muted)
                }
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .frame(height: PhoneKeyPanel.keyHeight)
            .background {
                // Translucent, unblurred: the terminal stays readable under the keys.
                shape.fill(prominent ? theme.accent.opacity(0.75) : theme.raised.opacity(0.55))
            }
            .overlay(shape.strokeBorder(prominent ? .clear : theme.border.opacity(0.6), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PanelPressStyle())
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .disabled(busy)
        .accessibilityLabel(a11y)
    }
}

/// A key that dims and shrinks a little while pressed.
private struct PanelPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

/// The grip at the right edge while the panel is closed: a hint that it is
/// there, and a tap target that opens it.
struct PhoneKeyPanelGrip: View {
    var open: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: open) {
            Capsule()
                .fill(theme.dim.opacity(0.55))
                .frame(width: 4, height: 44)
                .frame(width: 22, height: 96, alignment: .trailing)
                .padding(.trailing, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Keys")
        .accessibilityHint("Opens the keys")
    }
}

// MARK: - Gestures

/// The panel's gestures. Placed behind the terminal, it fills the terminal's
/// area (where they start) and puts its recognizers on the window's root
/// view, so they see touches over the terminal too (like the back swipe).
/// Closed, a pan from the area's right edge pulls the panel out; open, a
/// rightward pan anywhere in the area pushes it back, and a tap on the
/// terminal beside it closes it instead of taking the keyboard. While the
/// message field is open, a tap on the terminal closes that (and its
/// keyboard) instead, the panel first if both are. Their pans
/// (the terminal's scrolling, selection and mouse, the panel's scrolling)
/// wait for it, so a swipe that moves the panel does nothing else.
struct PhoneKeyPanelGestures: UIViewRepresentable {
    var enabled: Bool
    var isOpen: Bool
    /// The message field is open: a tap on the terminal closes it rather than typing there.
    var isComposing = false
    /// Leftward is negative.
    var onDrag: (CGFloat) -> Void
    /// Where the panel would come to rest at the finger's speed (translation).
    var onEnd: (CGFloat) -> Void
    var onTapOutside: () -> Void

    static let edgeWidth: CGFloat = 24

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.coordinator = context.coordinator
        context.coordinator.anchor = anchor
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.pan.isEnabled != enabled { c.pan.isEnabled = enabled }
        let tapOn = enabled && (isOpen || isComposing)
        if c.tap.isEnabled != tapOn { c.tap.isEnabled = tapOn }
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window?.rootViewController?.view)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PhoneKeyPanelGestures?
        weak var anchor: Anchor?
        let pan = UIPanGestureRecognizer()
        let tap = UITapGestureRecognizer()
        /// The current pan may move the panel (it began where it should): others' pans wait for it.
        private var claims = false

        override init() {
            super.init()
            pan.maximumNumberOfTouches = 1
            pan.addTarget(self, action: #selector(moved(_:)))
            pan.delegate = self
            tap.addTarget(self, action: #selector(tapped(_:)))
            tap.delegate = self
            tap.isEnabled = false
        }

        func attach(to view: UIView?) {
            guard let view, pan.view !== view else { return }
            detach()
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(tap)
        }

        func detach() {
            pan.view?.removeGestureRecognizer(pan)
            tap.view?.removeGestureRecognizer(tap)
        }

        @objc private func moved(_ g: UIPanGestureRecognizer) {
            guard let parent, let view = g.view else { return }
            let x = g.translation(in: view).x
            switch g.state {
            case .began, .changed: parent.onDrag(x)
            case .ended: parent.onEnd(x + g.velocity(in: view).x * 0.25)
            case .cancelled, .failed: parent.onEnd(0)
            default: break
            }
        }

        @objc private func tapped(_ g: UITapGestureRecognizer) {
            if g.state == .ended { parent?.onTapOutside() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if g === pan { claims = false }
            guard let parent, let anchor, anchor.window != nil else { return false }
            // The terminal's area now, in window coordinates (it moves with the back swipe).
            let area = anchor.convert(anchor.bounds, to: nil)
            let p = touch.location(in: nil)
            // Beside the terminal's rows only (not over the top bar); to its
            // right is the edge (or, in landscape, the safe area up to it).
            guard p.y >= area.minY, p.y <= area.maxY, p.x >= area.minX else { return false }
            if g === tap {
                // Beside the panel only: its keys take their own taps.
                if parent.isOpen { return p.x < area.maxX - PhoneKeyPanel.width }
                return parent.isComposing && p.x <= area.maxX
            }
            claims = parent.isOpen || p.x >= area.maxX - PhoneKeyPanelGestures.edgeWidth
            return claims
        }

        // Closed: only a leftward, mostly horizontal move; open: a rightward one.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === pan, let parent, let view = g.view else { return true }
            let v = pan.velocity(in: view)
            let dx = parent.isOpen ? v.x : -v.x
            return dx > 0 && dx > abs(v.y)
        }

        // The terminal's and the panel's pans wait for the panel's (it fails
        // at once on a vertical move). Not the keys' presses: a held arrow
        // would wait until the finger lifts. Not the root view's own (the back
        // swipe). The tap beside the panel beats the terminal's tap.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            if g === tap { return other is UITapGestureRecognizer && other.view !== g.view }
            guard claims, other.view !== g.view else { return false }
            return parent?.isOpen == true ? other is UIPanGestureRecognizer : true
        }
    }
}
