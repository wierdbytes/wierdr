import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import WierdrModel

/// The message field under the terminal, always there (Telegram's composer,
/// its geometry, glass and motion; the theme's colors): the attach button
/// (a 40-pt glass circle) and the field (a glass capsule, radius 20) with the
/// send button inside it, at its bottom right, from the first character on.
/// Under the iPhone's terminal; under all the iPad's panes (it writes to the
/// focused one, named in the placeholder); at the bottom of a sub-agent's
/// window. Hidden while the terminal has the keyboard itself (a double tap).
///
/// A tap on it brings the keyboard (dictation, autocorrect, any language) and
/// the field grows with the text, upward (at most Telegram's cap, then it
/// scrolls). A double tap on the terminal puts the keyboard away at once and
/// the field down to one line. Send: the text goes to the program as one
/// paste (bracketed when it asked, so line breaks stay in the message), then
/// Return, and the keyboard goes (to watch the answer); long-press: Insert
/// Without Return, Clear. The attach button's menu puts a photo, a file or a
/// copied image beside the terminal on its machine (`terminal.put`) and adds
/// its path to the message. The text stays as the terminal's draft.
struct ComposerBar: View {
    enum Placement {
        /// The iPhone's pane screen (its bottom edge): Telegram's insets, in by 18 pt beside the
        /// screen's rounded corners while the keyboard is down.
        case screen
        /// Under the iPad's panes (their 8-pt margin above).
        case panel
        /// The bottom of a sub-agent's window.
        case card
    }

    var address: String
    var placeholder = "Message"
    var placement: Placement
    /// The height of the terminal and this bar together: the text takes at
    /// most what Telegram's rule leaves (this − 120, at most 12 lines).
    var room: CGFloat

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.services) private var services
    @Environment(\.theme) private var theme
    /// The bottom safe area while the keyboard is down (the home indicator's; 0: none).
    @State private var homeInset: CGFloat = 0
    @State private var sent = 0
    @State private var uploading = false
    @State private var pickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var importing = false
    /// The field had the keyboard when an attachment was asked for: it gets it back.
    @State private var refocus = false

    var body: some View {
        let draft = controller.drafts[address] ?? ""
        let focused = controller.composing == address
        let hasText = !draft.isEmpty
        let compact = placement == .screen && !focused && homeInset > 0
        ComposerGlassGroup {
            HStack(alignment: .bottom, spacing: 6) {
                attachButton
                field(draft: draft, focused: focused, hasText: hasText)
            }
        }
        // Its own height whatever is left: the terminal above gives way.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8 + (compact ? 18 : 0))
        .padding(.top, placement == .panel ? 0 : 8)
        // Telegram's 20 + 8 above the screen's bottom, not the safe area's: into the home indicator's.
        .padding(.bottom, compact ? 28 - homeInset : 8)
        .frame(maxWidth: .infinity)
        .background {
            zone.ignoresSafeArea(edges: [.bottom, .horizontal])
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
                    // Only while the keyboard is down: up, the safe area is the keyboard's.
                    if placement == .screen, controller.composing != address, inset > 0, inset < 60 { homeInset = inset }
                }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .photosPicker(isPresented: $pickingPhoto, selection: $picked, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await attachImage(data)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            Task { await attachFile(result) }
        }
    }

    /// What the bar stands on: the terminal's background (the glass floats on it, as on Telegram's
    /// chat), the canvas under the iPad's panes.
    private var zone: Color { placement == .panel ? theme.canvas : theme.background }

    // MARK: Field

    private func field(draft: String, focused: Bool, hasText: Bool) -> some View {
        let prose = controller.workspace.terminal(address)?.isAgent ?? true
        return ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: draft, focused: focused, prose: prose, placeholder: placeholder,
                maxHeight: Self.maxTextHeight(room: room), theme: theme,
                onEdit: { edited($0) },
                onFocus: { focusChanged($0) },
                onReturn: { submit(pressReturn: true) })
            .padding(EdgeInsets(top: 5, leading: 12, bottom: 4, trailing: 11))
            if !hasText {
                // Telegram's: one line at the text's first line, gone at once with the first character.
                Text(placeholder)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.foreground.opacity(theme.isDark ? 0.48 : 0.40))
                    .lineLimit(1)
                    .padding(.leading, 12)
                    .padding(.trailing, 16)
                    .padding(.top, 9.5 + 1 / UIScreen.main.scale)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
        }
        // No minimum height here (the text is at least 31 + 9): a frame with
        // only a minimum takes a smaller proposal, and the text ran on below
        // the capsule, under the keyboard, when the terminal left too little room.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        // A tap on the capsule's margins brings the keyboard too.
        .onTapGesture { if !focused { setFocus(true) } }
        .overlay(alignment: .bottomTrailing) {
            ComposerSendButton(shown: hasText,
                               send: { submit(pressReturn: true) },
                               insert: { submit(pressReturn: false) },
                               clear: { edited("") })
        }
        .composerGlass(RoundedRectangle(cornerRadius: 20), theme: theme)
    }

    /// Telegram's cap on the text's height: what is left above it but 120 pt,
    /// in 22-pt steps of at most 12 lines (24 pt each, and the insets).
    static func maxTextHeight(room: CGFloat) -> CGFloat {
        let fieldMax = max(33, room - 120 - 9)
        let lines = max(1, min(12, (Int(fieldMax - 11) - 33) / 22))
        return CGFloat(lines) * 24 + 10
    }

    /// Typed: the draft; the field grows in 0.1 s, the send button comes or goes with Telegram's 0.4 s.
    private func edited(_ text: String) {
        let was = controller.drafts[address] ?? ""
        let flip = was.isEmpty != text.isEmpty
        withAnimation(flip ? ComposerMotion.transition : ComposerMotion.typing) {
            controller.drafts[address] = text.isEmpty ? nil : text
        }
    }

    private func focusChanged(_ on: Bool) {
        if on {
            guard controller.composing != address else { return }
            // Grows to the draft and steps out to the edges with the keyboard (its spring).
            withAnimation(ComposerMotion.keyboard) { controller.composing = address }
        } else if controller.composing == address {
            // Gone (a double tap, Hide, a picker over it): down to one line at once, with the keyboard.
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { controller.composing = nil }
        }
    }

    private func setFocus(_ on: Bool) {
        if on {
            withAnimation(ComposerMotion.keyboard) { controller.composing = address }
        } else {
            controller.closeCompose()
        }
    }

    // MARK: Sending

    /// Text (or, from a hardware keyboard's Return in an empty field, just Return) to the program.
    private func submit(pressReturn: Bool) {
        guard let session = live() else { return }
        let prose = controller.workspace.terminal(address)?.isAgent ?? true
        let message = Self.plain((controller.drafts[address] ?? "").trimmingCharacters(in: .newlines), prose: prose)
        session.send(text: message, submit: pressReturn)
        sent += 1
        guard !message.isEmpty else { return }
        // Cleared at once; the send button goes and the field shrinks with Telegram's 0.4 s.
        withAnimation(ComposerMotion.transition) { controller.drafts[address] = nil }
        // Sent: the keyboard goes, to watch the answer.
        controller.closeCompose()
    }

    private func live() -> TerminalSession? {
        guard let session = services.terminalSession(address) else {
            controller.toast(controller.isDemo ? "Not available in the demo" : "The terminal is not connected yet")
            return nil
        }
        guard session.acceptsInput else {
            controller.toast("The terminal is not connected yet")
            return nil
        }
        return session
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

    // MARK: Attach

    private var attachButton: some View {
        Menu {
            Button { begin { pickingPhoto = true } } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { begin { importing = true } } label: { Label("File", systemImage: "doc") }
            Button { pasteImage() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
        } label: {
            ZStack {
                if uploading {
                    ProgressView().controlSize(.small).tint(theme.foreground)
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(theme.foreground)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(AttachPressStyle())
        .menuOrder(.priority)
        .disabled(uploading)
        .composerGlass(Circle(), theme: theme)
        .accessibilityLabel("Attach")
        .accessibilityHint("A photo, a file or a copied image: its path goes into the message")
    }

    /// A picker is coming (it takes the keyboard): remember to give it back.
    private func begin(_ present: () -> Void) {
        guard live() != nil else { return }
        refocus = controller.composing == address
        present()
    }

    private func pasteImage() {
        guard live() != nil else { return }
        // Asking first doesn't trigger the paste prompt.
        guard UIPasteboard.general.hasImages else { return controller.toast("No image on the clipboard") }
        refocus = controller.composing == address
        Task { await attachImage(UIPasteboard.general.image.flatMap { $0.pngData() }) }
    }

    /// A photo or a copied image, made ready for an agent (`ImageForAgent`).
    private func attachImage(_ data: Data?) async {
        guard let data else { return controller.toast("Couldn't read that image") }
        uploading = true
        defer { uploading = false }
        // Decoding a 48 MP photo takes a moment and memory: off the main thread.
        guard let image = await Task.detached(priority: .userInitiated, operation: { ImageForAgent(data) }).value else {
            return controller.toast("Couldn't read that image")
        }
        await upload(image.data, name: image.name, what: "Image")
    }

    /// A file from Files, as it is (at most 8 MB, `terminal.put`'s limit).
    private func attachFile(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { controller.toast("File: \(error.localizedDescription)") }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        uploading = true
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
        uploading = false
        guard let data else { return controller.toast("Couldn't read that file") }
        guard data.count <= 8_000_000 else { return controller.toast("That file is over 8 MB") }
        await upload(data, name: url.lastPathComponent, what: "File")
    }

    /// Puts it beside the terminal on its machine (as a pasted image on the
    /// desktop) and adds its path to the message (a space before, unless at a
    /// line's start, and after).
    private func upload(_ data: Data, name: String, what: String) async {
        guard let session = live() else { return }
        uploading = true
        defer { uploading = false }
        do {
            let path = try await session.put(data, name: name)
            var text = controller.drafts[address] ?? ""
            if let last = text.last, !last.isWhitespace { text += " " }
            edited(text + path + " ")
            sent += 1
            if refocus { setFocus(true) }
        } catch {
            controller.toast("\(what): \(error.localizedDescription)")
        }
        refocus = false
    }
}

// MARK: - Motion

/// Telegram's curves for what the composer does.
enum ComposerMotion {
    /// Its 0.4-s state transition (`.animated(duration: 0.4, curve: .spring)`, a bezier in fact):
    /// the send button, the field's width and height when the text comes or goes.
    static let transition = Animation.timingCurve(0.38, 0.7, 0.125, 1.0, duration: 0.4)
    static let transitionCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.38, y: 0.7),
                                                 endControlPoint: UnitPoint(x: 0.125, y: 1.0))
    /// The field growing or shrinking a line while typing.
    static let typing = Animation.easeInOut(duration: 0.1)
    /// The keyboard's own spring (iOS 26), which the bar rides.
    static let keyboard = Animation.interpolatingSpring(mass: 1, stiffness: 555.027, damping: 47.118)
}

// MARK: - Send button

/// Inside the capsule at its bottom right (3 pt in): an accent pill, 40 × 34,
/// with Telegram's paper plane. It comes with the first character: from
/// nothing at the capsule's edge (scale 0.001, 17 pt to the right), out of a
/// 4-pt blur, fading in over 0.2 s, the plane flying in from the bottom left;
/// and goes the same way back. Pressed, it sinks to 0.75; a long press offers
/// Insert Without Return and Clear.
private struct ComposerSendButton: View {
    var shown: Bool
    var send: () -> Void
    var insert: () -> Void
    var clear: () -> Void

    @Environment(\.theme) private var theme
    @State private var launches = 0

    var body: some View {
        Menu {
            Button(action: insert) { Label("Insert Without Return", systemImage: "text.insert") }
            Button(role: .destructive, action: clear) { Label("Clear", systemImage: "xmark") }
        } label: {
            pill
        } primaryAction: {
            send()
        }
        .menuStyle(.button)
        .buttonStyle(SendPressStyle())
        .frame(width: 46, height: 40)
        .animation(.easeInOut(duration: 0.18)) { $0.blur(radius: shown ? 0 : 4) }
        .animation(.easeInOut(duration: 0.2)) { $0.opacity(shown ? 1 : 0) }
        .animation(ComposerMotion.transition) {
            $0.scaleEffect(shown ? 1 : 0.001).offset(x: shown ? 0 : 17)
        }
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .accessibilityLabel("Send")
        .accessibilityHint("Long press: insert without Return, or clear")
        .onChange(of: shown) { _, shown in if shown { launches += 1 } }
    }

    private var pill: some View {
        Capsule()
            .fill(theme.accent)
            .frame(width: 40, height: 34)
            .overlay {
                SendGlyph()
                    .fill(theme.accentForeground, style: FillStyle(eoFill: true))
                    .frame(width: 30, height: 30)
                    // The plane flies in from the bottom left (Telegram's additive −22, +18).
                    .keyframeAnimator(initialValue: CGSize.zero, trigger: launches) { glyph, offset in
                        glyph.offset(offset)
                    } keyframes: { _ in
                        KeyframeTrack {
                            MoveKeyframe(CGSize(width: -22, height: 18))
                            LinearKeyframe(CGSize.zero, duration: 0.4, timingCurve: ComposerMotion.transitionCurve)
                        }
                    }
            }
            .frame(width: 46, height: 40)
            .contentShape(Rectangle())
    }
}

/// Telegram's send button with long press on: it sinks to 0.75 over 0.4 s while held, back over 0.25 s.
private struct SendPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.75 : 1)
            .animation(.easeInOut(duration: configuration.isPressed ? 0.4 : 0.25), value: configuration.isPressed)
    }
}

/// Telegram's attach button: its icon drops to 0.4 at once on touch, back over 0.2 s.
private struct AttachPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.4 : 1)
            .animation(configuration.isPressed ? nil : .easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// Telegram's paper plane (`Chat/Input/Text/SendIcon`, a 30 × 30 pt PDF), filled even-odd.
struct SendGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        // The PDF's path: origin at the bottom left, moved by (4, 6.437256).
        let segments: [[CGFloat]] = [
            [1.374896, 9.472263, 9.427943, 12.958834, 12.114815, 14.069384],
            [17.229191, 16.183283, 18.291916, 16.550489, 18.984585, 16.562614],
            [19.136930, 16.565281, 19.477566, 16.527763, 19.698214, 16.349846],
            [19.884525, 16.199615, 19.935787, 15.996675, 19.960318, 15.854240],
            [19.984848, 15.711806, 20.015392, 15.387336, 19.991110, 15.133804],
            [19.713961, 12.240038, 18.514738, 5.217632, 17.904642, 1.976564],
            [17.646488, 0.605147, 17.138172, 0.145317, 16.646065, 0.100317],
            [15.576601, 0.002522, 14.764499, 0.802658, 13.728671, 1.477396],
            [12.107805, 2.533228, 11.192119, 3.190486, 9.618788, 4.220782],
            [7.800531, 5.411469, 8.979231, 6.065889, 10.015450, 7.135397],
            [10.286633, 7.415293, 14.998713, 11.674402, 15.089916, 12.060770],
            [15.101322, 12.109092, 15.111909, 12.289213, 15.004227, 12.384323],
            [14.896544, 12.479433, 14.737615, 12.446909, 14.622927, 12.421043],
            [14.379076, 12.366045, 6.854864, 7.318857, 6.854864, 7.318857],
            [6.854864, 7.318857, 5.752395, 6.566566, 4.857699, 6.585774],
            [4.200145, 6.599892, 2.935277, 6.955233, 1.994976, 7.258969],
            [0.841660, 7.631515, -0.074973, 7.828483, 0.004845, 8.461180],
            [0.067207, 8.955502, 1.374896, 9.472263, 1.374896, 9.472263],
        ]
        let sx = rect.width / 30, sy = rect.height / 30
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x + 4) * sx, y: rect.minY + (30 - (y + 6.437256)) * sy)
        }
        var path = Path()
        path.move(to: p(1.374896, 9.472263))
        for s in segments {
            path.addCurve(to: p(s[4], s[5]), control1: p(s[0], s[1]), control2: p(s[2], s[3]))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Glass

/// Telegram's glass container: on iOS 26 one `GlassEffectContainer` (7-pt
/// merging) holds the attach button's and the field's glass.
private struct ComposerGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 7) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Telegram's panel glass: regular, a white tint of 2.5 % (dark) or 10 %
    /// (light), interactive. Before iOS 26, its drawn stand-in in the theme's
    /// colors: a translucent fill, a 0.8-pt inner line and a soft shadow.
    @ViewBuilder
    func composerGlass<S: InsettableShape>(_ shape: S, theme: Theme) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(.white.opacity(theme.isDark ? 0.025 : 0.1)).interactive(), in: shape)
        } else {
            background {
                shape.fill(theme.isDark ? theme.raised.opacity(0.85) : theme.background.opacity(0.7))
                    .overlay(shape.strokeBorder(.white.opacity(theme.isDark ? 0.15 : 0.6), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.045), radius: 15)
                    .shadow(color: .black.opacity(0.04), radius: 20, y: 1)
            }
        }
    }
}

// MARK: - Closing

extension WorkspaceController {
    /// Puts the message field's keyboard away at once: it goes without
    /// sliding, the field down to one line without a transition (its text stays as the draft).
    func closeCompose() {
        guard composing != nil else { return }
        UIView.performWithoutAnimation {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { composing = nil }
    }
}
