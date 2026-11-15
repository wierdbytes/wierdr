import SwiftUI
import UIKit
import WierdrModel

/// Subscription limits at the bottom of the sidebar, like the desktop's
/// `limits` mod in its sidebar: one row per account
/// (provider icon, name, plan); open, every limit under it as a 3 pt bar with
/// a tick where the window's time stands, its share used colored by pace, and
/// when it resets. Closed, the account shows its headline limit (the pinned
/// one, else the one that runs out first). Data: `Workspace.limits`, from the
/// `limits` documents pi-herdr writes on each machine.
///
/// Tap an account to open or close it; tap a limit to pin it as the
/// account's headline (again: unpin). Both are remembered on this device.
/// A closed account's row reads like an open one's limits (bar with its tick,
/// share, reset), and their columns line up.
///
/// The iPhone's list has them as rings in its header instead (`PhoneLimits`),
/// its popover drawn with the parts here in the `large` sizes.
struct LimitsPanel: View {
    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @AppStorage("limits.closed") private var closedRaw = ""
    @AppStorage("limits.pinned") private var pinnedRaw = ""
    /// What's closed, as shown. A state of its own so opening and closing
    /// animate (an `AppStorage` write doesn't carry `withAnimation`); saved to
    /// `closedRaw`, and follows it when the other sidebar (docked or overlay) changes it.
    @State private var closedShown: Set<String>?
    @State private var width: CGFloat = 0

    var body: some View {
        let accounts = controller.workspace.limits
        if !accounts.isEmpty {
            // Countdowns and pace move without new readings.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        AccountView(account: account, now: context.date, size: size,
                                    multi: accounts.filter { $0.provider == account.provider }.count > 1,
                                    open: !closed.contains(account.id),
                                    pinned: pinned[account.id],
                                    stacked: width > 0 && width < 276,
                                    toggle: { toggle(account.id) },
                                    pin: { pin(account.id, $0) })
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: closedRaw) { _, raw in
                let set = Self.parse(raw)
                if set != closedShown { closedShown = set }
            }
            .background(theme.chrome)
            .overlay(alignment: .top) { Hairline() }
        }
    }

    private var size: Size { .regular }

    // MARK: Remembered state

    private var closed: Set<String> { closedShown ?? Self.parse(closedRaw) }

    private static func parse(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }

    private var pinned: [String: String] {
        var out: [String: String] = [:]
        for pair in pinnedRaw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    private func toggle(_ id: String) {
        var set = closed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation(.easeInOut(duration: 0.22)) { closedShown = set }
        closedRaw = set.sorted().joined(separator: ",")
    }

    private func pin(_ account: String, _ window: String) {
        var map = pinned
        map[account] = map[account] == window ? nil : window
        pinnedRaw = map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    // MARK: Sizes

    struct Size {
        var row: CGFloat, limit: CGFloat, limitStacked: CGFloat
        var name: CGFloat, text: CGFloat, small: CGFloat, icon: CGFloat
        var label: CGFloat, pct: CGFloat, reset: CGFloat
        /// Room the head's chevron takes at the trailing edge (with its spacing):
        /// limit rows leave it free so their columns line up with a closed head's.
        var chevron: CGFloat { icon * 0.62 }
        var trailing: CGFloat { chevron + 6 }
        /// The bar line under a stacked row's numbers.
        var stackedBar: CGFloat { 13 }

        static let regular = Size(row: 28, limit: 20, limitStacked: 30, name: 12.5, text: 11.5, small: 10.5, icon: 13,
                                  label: 52, pct: 42, reset: 46)
        /// The iPhone header's popover (`PhoneLimits`).
        static let large = Size(row: 40, limit: 30, limitStacked: 40, name: 15, text: 13.5, small: 12.5, icon: 17,
                                label: 64, pct: 50, reset: 58)
    }
}

// MARK: - One account

private struct AccountView: View {
    var account: LimitAccount
    var now: Date
    var size: LimitsPanel.Size
    var multi: Bool
    var open: Bool
    var pinned: String?
    var stacked: Bool
    var toggle: () -> Void
    var pin: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let windows = Limits.shown(account)
        let top = Limits.headline(account, pinned: pinned, now: now)
        let rowHeight = stacked ? size.limitStacked : size.limit
        let bodyHeight = (windows.isEmpty ? size.limit : CGFloat(windows.count) * rowHeight) + 4
        VStack(spacing: 0) {
            head(top)
            // Always laid out: closing animates its height to 0 (clipped) instead of
            // inserting and removing rows, so the panel and the list above move together.
            VStack(spacing: 0) {
                if windows.isEmpty {
                    Text("No limits reported")
                        .font(.ui(size.text))
                        .foregroundStyle(theme.dim)
                        .frame(maxWidth: .infinity, minHeight: size.limit, alignment: .leading)
                }
                // In a fixed order (the headline is the bright one), so rows never jump.
                ForEach(windows) { w in
                    LimitRow(window: w, now: now, size: size, stacked: stacked,
                             isTop: w.id == top?.id, isPinned: w.id == pinned) { pin(w.id) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .frame(height: open ? bodyHeight : 0, alignment: .top)
            .clipped()
            .opacity(open ? 1 : 0)
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
        }
    }

    /// Icon, name and plan; closed, the headline limit as an open limit row
    /// shows it (bar, share, reset); the chevron.
    private func head(_ top: LimitWindow?) -> some View {
        Button(action: toggle) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    identity.layoutPriority(1)
                    if !open, let top {
                        // Short of room the countdown gives way first, as in the desktop mod.
                        ViewThatFits(in: .horizontal) {
                            summary(top, resets: true)
                            summary(top, resets: false)
                        }
                        .transition(.opacity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Icon("chevron-right", size: size.chevron, color: theme.dim)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(height: size.row)
                if let top, stacked {
                    LimitBar(window: top, now: now)
                        .padding(.bottom, 4)
                        .frame(height: open ? 0 : size.stackedBar, alignment: .top)
                        .clipped()
                        .opacity(open ? 0 : 1)
                }
            }
            .padding(.horizontal, 4)
            .background(hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .hoverEffect(.highlight)
        .accessibilityLabel(accessibility(top))
        .accessibilityHint(open ? "Hides its limits" : "Shows every limit")
    }

    /// A closed account's headline, in an open limit row's columns: bar (inline
    /// only; stacked, it's the line below), share, reset.
    private func summary(_ top: LimitWindow, resets: Bool) -> some View {
        HStack(spacing: 6) {
            if stacked {
                Spacer(minLength: 0)
            } else {
                LimitBar(window: top, now: now)
            }
            Percent(window: top, now: now, size: size, minWidth: size.pct)
            if resets { Resets(window: top, now: now, size: size) }
        }
    }

    private var identity: some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: account.provider, size: size.icon)
            Text(multi ? "\(Limits.providerName(account.provider)) · \(Limits.accountName(account))"
                       : Limits.providerName(account.provider))
                .font(.ui(size.name))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            if let plan = Limits.planName(account.provider, account.plan) {
                PlanBadge(text: plan, size: size)
            }
        }
    }

    private func accessibility(_ top: LimitWindow?) -> String {
        var parts = [Limits.providerName(account.provider)]
        if multi { parts.append(Limits.accountName(account)) }
        if let plan = Limits.planName(account.provider, account.plan) { parts.append(plan) }
        if let top { parts.append(Limits.spoken(top, now: now)) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - One limit

private struct LimitRow: View {
    var window: LimitWindow
    var now: Date
    var size: LimitsPanel.Size
    var stacked: Bool
    var isTop: Bool
    var isPinned: Bool
    var action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if stacked {
                    VStack(spacing: 4) {
                        HStack(spacing: 6) {
                            label.frame(maxWidth: .infinity, alignment: .leading)
                            Percent(window: window, now: now, size: size, minWidth: size.pct)
                            Resets(window: window, now: now, size: size)
                        }
                        .padding(.trailing, size.trailing)
                        LimitBar(window: window, now: now)
                    }
                    .frame(height: size.limitStacked)
                } else {
                    HStack(spacing: 6) {
                        label.frame(width: size.label, alignment: .leading)
                        LimitBar(window: window, now: now)
                        Percent(window: window, now: now, size: size, minWidth: size.pct)
                        Resets(window: window, now: now, size: size)
                    }
                    .padding(.trailing, size.trailing)
                    .frame(height: size.limit)
                }
            }
            .background(hovering ? theme.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .accessibilityLabel(Limits.spoken(window, now: now))
        .accessibilityHint(isPinned ? "Unpins it" : "Shows it on the closed account")
        .accessibilityAddTraits(isPinned ? .isSelected : [])
    }

    private var label: some View {
        Text(window.label)
            .font(.ui(size.text, isTop ? .semibold : .regular))
            .foregroundStyle(isPinned ? theme.accent : isTop ? theme.foreground : theme.muted)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - Parts

/// Time to the window's reset, in its fixed-width column (empty once reset).
struct Resets: View {
    var window: LimitWindow
    var now: Date
    var size: LimitsPanel.Size

    @Environment(\.theme) private var theme

    var body: some View {
        let text = !Limits.isReset(window, now: now) ? window.resetsAt.map { Limits.span($0.timeIntervalSince(now)) } : nil
        Text(text ?? "")
            .font(.mono(size.small))
            .foregroundStyle(theme.dim)
            .lineLimit(1)
            .frame(width: size.reset, alignment: .trailing)
    }
}

/// The share used in its pace color, with › / ›› when running ahead.
struct Percent: View {
    var window: LimitWindow
    var now: Date
    var size: LimitsPanel.Size
    var minWidth: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        let (tone, speed) = Limits.tone(window, now: now)
        let color = theme.limitColor(tone)
        HStack(spacing: 2) {
            if speed > 0 {
                Text(Limits.chevrons(speed))
                    .font(.ui(size.text, .semibold))
                    .foregroundStyle(color)
            }
            Text(tone == .reset ? "–" : Limits.percent(window.used))
                .font(.mono(size.text))
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(minWidth: minWidth, alignment: .trailing)
    }
}

/// A 3 pt track: the used share filled in its pace color, a tick where the
/// window's time stands.
struct LimitBar: View {
    var window: LimitWindow
    var now: Date

    @Environment(\.theme) private var theme

    var body: some View {
        let reset = Limits.isReset(window, now: now)
        let used = reset ? 0 : min(100, max(0, window.used)) / 100
        let tick = reset ? nil : Limits.elapsed(window, now: now)
        let color = theme.limitColor(Limits.tone(window, now: now).tone)
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.raised).frame(height: 3)
                if used > 0 {
                    Capsule().fill(color).frame(width: max(2, w * used), height: 3)
                }
                if let tick {
                    Rectangle().fill(theme.foreground.opacity(0.5)).frame(width: 1, height: 9).offset(x: min(w - 1, w * tick))
                }
            }
            .frame(width: w, height: geo.size.height, alignment: .leading)
        }
        .frame(minWidth: 20, maxWidth: .infinity)
        .frame(height: 9)
        .accessibilityHidden(true)
    }
}

struct PlanBadge: View {
    var text: String
    var size: LimitsPanel.Size
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.ui(size.small))
            .foregroundStyle(theme.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.raised, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// The provider's program icon (`program.claude`, `program.codex`), else its initial on a tile.
struct ProviderIcon: View {
    var provider: String
    var size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        if UIImage(named: "program.\(provider)") != nil {
            Image("program.\(provider)")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: provider == "codex" ? 3 : 0))
        } else {
            Text(String(provider.prefix(1)).uppercased())
                .font(.ui(size * 0.7, .semibold))
                .foregroundStyle(theme.foreground)
                .frame(width: size, height: size)
                .background(theme.raised, in: RoundedRectangle(cornerRadius: 3))
        }
    }
}

extension Limits {
    /// A limit as VoiceOver reads it: "5 hours 37%, resets in 16m".
    static func spoken(_ w: LimitWindow, now: Date) -> String {
        if isReset(w, now: now) { return "\(w.label), reset" }
        var text = "\(w.label) \(percent(w.used))"
        if let at = w.resetsAt { text += ", resets in \(span(at.timeIntervalSince(now)))" }
        return text
    }
}

extension Theme {
    /// Pace colors, as the desktop mod's (ansi2 / ansi3 / ansi1; dim once reset).
    func limitColor(_ tone: Limits.Tone) -> Color {
        switch tone {
        case .reset: return dim
        case .ok: return ansi(2)
        case .ahead: return ansi(3)
        case .danger: return ansi(1)
        }
    }
}
