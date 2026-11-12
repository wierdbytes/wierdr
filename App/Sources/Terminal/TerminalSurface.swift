import SwiftUI
import UIKit

/// A terminal in a pane card: the session's emulator view with the pane
/// padding on the theme background, plus a state overlay
/// (connecting / reconnecting / process exited / error).
///
/// - `isFocused`: the pane is the focused one on this screen. Becoming focused
///   gives the terminal the keyboard only when another terminal had it
///   already (it follows the focus). A click with a pointer does too
///   (`WierdrTerminalView.tapsTakeKeyboard`); a finger's tap doesn't: the
///   keyboard comes from the key panel's swipe or puck (`KeyPanelLayer`).
/// - `onTap`: the user tapped/clicked the terminal (focus the pane).
struct TerminalSurface: View {
    let session: TerminalSession
    var isFocused: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        TerminalSurfaceRepresentable(session: session, isFocused: isFocused, onTap: onTap)
            .overlay { TerminalStateOverlay(session: session) }
    }
}

struct TerminalSurfaceRepresentable: UIViewRepresentable {
    let session: TerminalSession
    var isFocused: Bool
    var onTap: (() -> Void)?

    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerminalSurfaceHost {
        let host = TerminalSurfaceHost()
        host.show(session)
        return host
    }

    func updateUIView(_ host: TerminalSurfaceHost, context: Context) {
        if host.session !== session { host.show(session) }
        session.onTap = onTap
        let c = context.coordinator
        let view = session.terminalView
        if isFocused && !c.wasFocused {
            let takeKeyboard = WierdrTerminalView.keyboardOwner != nil && WierdrTerminalView.keyboardOwner !== view
            if takeKeyboard {
                DispatchQueue.main.async {
                    if view.window != nil { view.requestKeyboard() }
                }
            }
        } else if !isFocused && c.wasFocused && view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
        c.wasFocused = isFocused
    }

    static func dismantleUIView(_ host: TerminalSurfaceHost, coordinator: Coordinator) {
        host.release()
    }
}

/// Hosts a session's container. A session's view can move between hosts
/// (pane moves): the newest host wins, an old host lets go only of its own.
final class TerminalSurfaceHost: UIView {
    private(set) weak var session: TerminalSession?

    func show(_ s: TerminalSession) {
        if let old = session, old !== s, old.container.superview === self { old.container.removeFromSuperview() }
        session = s
        let c = s.container
        c.frame = bounds
        c.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(c)
        backgroundColor = s.theme.backgroundColor
    }

    func release() {
        if let c = session?.container, c.superview === self { c.removeFromSuperview() }
        session = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = session?.container, c.superview === self, c.frame != bounds { c.frame = bounds }
        if let s = session { backgroundColor = s.theme.backgroundColor }
    }
}

/// What the terminal is doing when it is not simply live.
struct TerminalStateOverlay: View {
    let session: TerminalSession

    var body: some View {
        let theme = session.theme
        let fg = Color(theme.foregroundColor)
        let bg = Color(theme.backgroundColor)
        ZStack {
            switch session.state {
            case .idle, .live:
                EmptyView()
            case .connecting:
                badge("Connecting…", fg: fg, bg: bg)
            case .reconnecting:
                badge("Reconnecting…", fg: fg, bg: bg)
            case .ended(let end):
                card(fg: fg, bg: bg) {
                    Text(end.message)
                        .font(.custom("JetBrains Mono", size: 14).weight(.medium))
                        .foregroundStyle(fg)
                }
                .allowsHitTesting(false)
            case .error(let message):
                card(fg: fg, bg: bg) {
                    VStack(spacing: 10) {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(fg)
                            .multilineTextAlignment(.center)
                        Button("Retry") { session.retry() }
                            .buttonStyle(.bordered)
                            .tint(Color(TerminalTheme.uiColor(theme.ansi[4])))
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.state)
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(fg)
                    Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(fg.opacity(0.8))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(bg.opacity(0.92)))
                .overlay(Capsule().stroke(fg.opacity(0.15), lineWidth: 1))
            }
            Spacer()
        }
        .padding(8)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func card<C: View>(fg: Color, bg: Color, @ViewBuilder content: () -> C) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(fg.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(24)
            .transition(.opacity)
    }
}
