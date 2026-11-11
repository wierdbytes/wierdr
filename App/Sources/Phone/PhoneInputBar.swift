import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import WierdrModel

/// Under the iPhone's terminal while it doesn't have the keyboard: quick keys
/// (Esc, arrows, Return, Tab, 1/2/3, y/n…) that answer an agent without the
/// keyboard, and a compose field with the system keyboard (dictation,
/// autocorrect, any language) whose text goes to the program as one paste,
/// followed by Return. The keyboard button types straight into the terminal
/// instead (with the terminal's own key bar); the bar steps aside meanwhile.
/// The paperclip puts a photo or a copied image beside the terminal on its
/// machine (`terminal.put`, like pasting an image on the desktop) and adds its
/// path to the message.
struct PhoneInputBar: View {
    var address: String

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState private var composing: Bool
    @State private var text = ""
    @State private var sent = 0
    @State private var picking = false
    @State private var picked: PhotosPickerItem?
    @State private var uploading = false

    var body: some View {
        let session = services.terminalSession(address)
        if session?.hasKeyboardFocus != true {
            VStack(spacing: 0) {
                QuickKeys { key in send(key, session) }
                    .frame(height: verticalSizeClass == .compact ? 38 : 42)
                compose(session)
            }
            .background(theme.chrome.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Hairline().ignoresSafeArea(edges: .horizontal) }
            .sensoryFeedback(.impact(weight: .light), trigger: sent)
            .onAppear { text = controller.drafts[address] ?? "" }
            .onChange(of: text) { _, t in controller.drafts[address] = t.isEmpty ? nil : t }
            .photosPicker(isPresented: $picking, selection: $picked, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    await attach(data, session)
                }
            }
            .transition(.opacity)
        }
    }

    private func compose(_ session: TerminalSession?) -> some View {
        let empty = text.isEmpty
        // Prose for agents (capitals, corrections); commands for shells (as typed).
        let prose = controller.workspace.terminal(address)?.isAgent ?? true
        return HStack(alignment: .bottom, spacing: 6) {
            Button {
                composing = false
                guard let session else { return controller.toast(unavailable) }
                session.takeKeyboard()
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(theme.muted)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Type in the Terminal")

            attachMenu(session)

            TextField("Message", text: $text, axis: .vertical)
                .font(.ui(16))
                .foregroundStyle(theme.foreground)
                .tint(theme.accent)
                .lineLimit(1...6)
                .textInputAutocapitalization(prose ? .sentences : .never)
                .autocorrectionDisabled(!prose)
                .focused($composing)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 40)
                .background(theme.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                .accessibilityLabel("Message to the terminal")

            Button { submit(session, pressReturn: true) } label: {
                Image(systemName: empty ? "return" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(empty ? theme.foreground : theme.accentForeground)
                    .frame(width: 36, height: 36)
                    .background(empty ? theme.raised : theme.accent, in: Circle())
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if !empty {
                    Button { submit(session, pressReturn: false) } label: {
                        Label("Insert Without Return", systemImage: "text.insert")
                    }
                }
                Button { text += UIPasteboard.general.string ?? "" } label: {
                    Label("Paste Here", systemImage: "doc.on.clipboard")
                }
                if !empty {
                    Button(role: .destructive) { text = "" } label: { Label("Clear", systemImage: "xmark") }
                }
            }
            .accessibilityLabel(empty ? "Return" : "Send")
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// Why input can't go anywhere: the demo has no terminals; live, the
    /// session is not there yet (or the terminal is gone).
    private var unavailable: String {
        controller.isDemo ? "Not available in the demo" : "The terminal is not connected yet"
    }

    /// Undoes the keyboard's smart punctuation, which breaks commands and
    /// flags: curly quotes become straight. For a shell (`prose == false`)
    /// every em/en dash becomes `--` and «» become `"`; for an agent only an
    /// em dash glued to a word (`—verbose`, typed as `--verbose`) does, so
    /// prose keeps its dashes (`1–2`, `a — b`) and guillemets.
    static func plain(_ s: String, prose: Bool) -> String {
        var out = s
        var pairs = [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""),
                     ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'")]
        if !prose { pairs += [("\u{00AB}", "\""), ("\u{00BB}", "\""), ("\u{2014}", "--"), ("\u{2013}", "--")] }
        for (from, to) in pairs { out = out.replacingOccurrences(of: from, with: to) }
        return out.replacingOccurrences(of: "\u{2014}(?=[^\\s\u{2014}])", with: "--", options: .regularExpression)
    }

    private func attachMenu(_ session: TerminalSession?) -> some View {
        Menu {
            Button { picking = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button {
                Task { await attach(UIPasteboard.general.image.flatMap { $0.pngData() }, session) }
            } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
            .disabled(!UIPasteboard.general.hasImages)
        } label: {
            Group {
                if uploading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(theme.muted)
                }
            }
            .frame(width: 34, height: 40)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(uploading)
        .accessibilityLabel("Attach Image")
    }

    /// Puts the image beside the terminal and adds its path to the message.
    private func attach(_ data: Data?, _ session: TerminalSession?) async {
        guard let session else { return controller.toast(unavailable) }
        guard let data else { return controller.toast("Couldn't read that image") }
        uploading = true
        defer { uploading = false }
        // Decoding a 48 MP photo takes a moment and memory: off the main thread.
        guard let image = await Task.detached(priority: .userInitiated, operation: { ImageForAgent(data) }).value else {
            return controller.toast("Couldn't read that image")
        }
        do {
            let path = try await session.put(image.data, name: image.name)
            if let last = text.last, !last.isWhitespace { text += " " }
            text += path + " "
            composing = true
        } catch {
            controller.toast("Image: \(error.localizedDescription)")
        }
    }

    private func send(_ key: TerminalSession.Key, _ session: TerminalSession?) {
        guard let session else { return controller.toast(unavailable) }
        guard session.acceptsInput else { return controller.toast("The terminal is not connected yet") }
        session.send(key: key)
    }

    /// Text (or, when empty, just Return) to the program.
    private func submit(_ session: TerminalSession?, pressReturn: Bool) {
        guard let session else { return controller.toast(unavailable) }
        guard session.acceptsInput else { return controller.toast("The terminal is not connected yet") }
        let prose = controller.workspace.terminal(address)?.isAgent ?? true
        let message = Self.plain(text.trimmingCharacters(in: .newlines), prose: prose)
        session.send(text: message, submit: pressReturn)
        text = ""
        sent += 1
        if !message.isEmpty { composing = false }
    }
}

/// The quick keys: one row, scrolls sideways; arrows repeat while held.
private struct QuickKeys: View {
    var send: (TerminalSession.Key) -> Void
    @Environment(\.theme) private var theme

    private struct K: Identifiable {
        var id: String { label }
        var label: String
        var symbol: String?
        var key: TerminalSession.Key
        var repeats = false
        var a11y: String
    }

    private let keys: [K] = [
        K(label: "esc", key: .escape, a11y: "Escape"),
        K(label: "⏎", symbol: "return", key: .enter, a11y: "Return"),
        K(label: "↑", symbol: "arrow.up", key: .up, repeats: true, a11y: "Up"),
        K(label: "↓", symbol: "arrow.down", key: .down, repeats: true, a11y: "Down"),
        K(label: "←", symbol: "arrow.left", key: .left, repeats: true, a11y: "Left"),
        K(label: "→", symbol: "arrow.right", key: .right, repeats: true, a11y: "Right"),
        K(label: "tab", key: .tab, a11y: "Tab"),
        K(label: "⇧tab", key: .backtab, a11y: "Shift Tab"),
        K(label: "1", key: .text("1"), a11y: "1"),
        K(label: "2", key: .text("2"), a11y: "2"),
        K(label: "3", key: .text("3"), a11y: "3"),
        K(label: "y", key: .text("y"), a11y: "y"),
        K(label: "n", key: .text("n"), a11y: "n"),
        K(label: "/", key: .text("/"), a11y: "Slash"),
        K(label: "@", key: .text("@"), a11y: "At"),
        K(label: "!", key: .text("!"), a11y: "Exclamation mark"),
        K(label: "^C", key: .control(0x03), a11y: "Control C"),
        K(label: "^L", key: .control(0x0c), a11y: "Control L"),
        K(label: "^R", key: .control(0x12), a11y: "Control R"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys) { k in
                    Button { send(k.key) } label: {
                        Group {
                            if let symbol = k.symbol {
                                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                            } else {
                                Text(k.label)
                                    .font(k.label.count > 1 ? .ui(13.5, .medium) : .mono(16, .medium))
                            }
                        }
                        .foregroundStyle(theme.foreground)
                        .frame(minWidth: 26)
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .background(theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(KeyPressStyle())
                    .buttonRepeatBehavior(k.repeats ? .enabled : .disabled)
                    .accessibilityLabel(k.a11y)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
    }
}

/// A key cap that darkens while pressed.
private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

/// An image made ready for an agent: screenshots stay PNG; photos (HEIC and
/// others) become JPEG; anything over 2048 px on a side is scaled down
/// (ImageIO thumbnails: no full decode, orientation applied), so it stays
/// well under `terminal.put`'s 8 MB. Safe off the main thread.
struct ImageForAgent: Sendable {
    var data: Data
    var name: String

    static let maxSide = 2048

    init?(_ original: Data) {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let isPNG = CGImageSourceGetType(source).map { UTType($0 as String) == .png } ?? false
        let stamp = Self.stamp()
        // Already right: a PNG screenshot of a sane size goes as it is.
        if isPNG, original.count <= 6_000_000, max(width, height) <= Self.maxSide {
            data = original
            name = "image-\(stamp).png"
            return
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if isPNG, let png = Self.encode(image, as: .png, quality: nil), png.count <= 6_000_000 {
            data = png
            name = "image-\(stamp).png"
        } else if let jpeg = Self.encode(image, as: .jpeg, quality: 0.85) {
            data = jpeg
            name = "photo-\(stamp).jpg"
        } else {
            return nil
        }
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// `20261111-165257`, in ASCII digits and the Gregorian calendar whatever the device's settings.
    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
