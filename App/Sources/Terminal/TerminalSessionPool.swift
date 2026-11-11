import UIKit
import Observation
import HerdrCore

/// All terminal sessions of the app, one per terminal address.
///
/// ```swift
/// let pool = TerminalSessionPool(dark: colorScheme == .dark)
/// pool.setConnection(core)              // after `start()`; nil when disconnected
/// TerminalSurface(session: pool.session(for: "t5w"), isFocused: focused) { focus(pane) }
/// pool.terminalRestarted("t5w")         // from the `restarted` event
/// pool.remove("t5w")                    // from the `removed` event
/// ```
///
/// Sessions attach when shown. Unlike the desktop (every tab stays attached),
/// a session that has been off screen for `idleDetachAfter` is detached, and
/// at most `maxAttached` stay attached (least recently shown go first);
/// showing it again reattaches (the core repaints screen + history).
@MainActor
@Observable
final class TerminalSessionPool {
    private(set) var sessions: [String: TerminalSession] = [:]
    private(set) var isDark: Bool
    private(set) var fontSize: CGFloat
    /// Metal renderer (SwiftTerm `setUseMetal`); CoreGraphics when false.
    private(set) var useMetal: Bool

    @ObservationIgnored var idleDetachAfter: TimeInterval = 60
    @ObservationIgnored var maxAttached = 12
    @ObservationIgnored private(set) var connection: CoreConnection?
    @ObservationIgnored private var sweeper: Task<Void, Never>?

    init(dark: Bool = true, fontSize: CGFloat = TerminalFonts.defaultSize, useMetal: Bool = TerminalSessionPool.defaultUseMetal) {
        isDark = dark
        self.fontSize = fontSize
        self.useMetal = useMetal
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.sweep()
            }
        }
    }

    /// Metal unless `-terminal-metal NO`.
    nonisolated static var defaultUseMetal: Bool {
        UserDefaults.standard.object(forKey: "terminal-metal") == nil ? true : UserDefaults.standard.bool(forKey: "terminal-metal")
    }

    var theme: TerminalTheme { .for(dark: isDark) }

    /// The session for a terminal address (`t5w`, `lf/t1`), created on first use.
    func session(for address: String) -> TerminalSession {
        if let s = sessions[address] { return s }
        let s = TerminalSession(address: address, theme: theme, fontSize: fontSize, useMetal: useMetal)
        s.setConnection(connection)
        s.onStateChange = { [weak self] _ in self?.enforceLimit() }
        sessions[address] = s
        return s
    }

    /// The current core connection; nil = disconnected. A new connection makes
    /// every attached (or waiting) session reattach on it.
    func setConnection(_ newConnection: CoreConnection?) {
        guard newConnection !== connection else { return }
        connection = newConnection
        for s in sessions.values { s.setConnection(newConnection) }
    }

    func setAppearance(dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        for s in sessions.values { s.apply(theme: theme, fontSize: fontSize) }
    }

    func setFontSize(_ size: CGFloat) {
        let size = min(max(size, 8), 32)
        guard size != fontSize else { return }
        fontSize = size
        for s in sessions.values { s.apply(theme: theme, fontSize: size) }
    }

    func setUseMetal(_ on: Bool) {
        guard on != useMetal else { return }
        useMetal = on
        for s in sessions.values { s.setUseMetal(on) }
    }

    /// A kept terminal got its new shell (`restarted` event).
    func terminalRestarted(_ address: String) {
        sessions[address]?.terminalRestarted()
    }

    /// The terminal was removed: drop its session.
    func remove(_ address: String) {
        sessions.removeValue(forKey: address)?.close()
    }

    /// Drops sessions for terminals that no longer exist.
    func retain(only addresses: Set<String>) {
        for a in sessions.keys where !addresses.contains(a) { remove(a) }
    }

    // MARK: Idle detach

    private func sweep() {
        let now = Date()
        for s in sessions.values where !s.isVisible && s.isAttached && now.timeIntervalSince(s.lastVisible) > idleDetachAfter {
            s.detach()
        }
        enforceLimit()
    }

    private func enforceLimit() {
        let attached = sessions.values.filter { $0.isAttached && !$0.isVisible }
        let visible = sessions.values.filter { $0.isAttached && $0.isVisible }.count
        let excess = attached.count + visible - maxAttached
        guard excess > 0 else { return }
        for s in attached.sorted(by: { $0.lastVisible < $1.lastVisible }).prefix(excess) { s.detach() }
    }
}
