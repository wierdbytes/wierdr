import SwiftUI
import WierdrModel

/// The subscription limits in the iPhone list's header, at its right (the status
/// counts in the middle): per account its provider's icon, then a ring for each of
/// its limits (`LimitRing`), all of them. A tap on an account shows its limits as the
/// sidebar's panel lists them, bar, share and reset, in a popover under it
/// (`PhoneLimitsPopover`). Nothing without limits. Data: `Workspace.limits`, as
/// `LimitsPanel`'s (`7d_oi` isn't shown either).
struct PhoneLimits: View {
    /// The header row's: the accounts' touch areas.
    var height: CGFloat

    @Environment(WorkspaceController.self) private var controller

    var body: some View {
        let accounts = controller.workspace.limits
        if !accounts.isEmpty {
            // Pace moves without new readings.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 10) {
                    ForEach(accounts) { account in
                        PhoneLimitAccount(account: account, now: context.date, height: height,
                                          multi: accounts.filter { $0.provider == account.provider }.count > 1)
                    }
                }
            }
            .transition(.opacity)
        }
    }
}

/// An account: its icon and its rings; a tap shows its limits in a popover.
private struct PhoneLimitAccount: View {
    var account: LimitAccount
    var now: Date
    var height: CGFloat
    var multi: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme
    @State private var showsLimits = false

    var body: some View {
        let windows = Limits.shown(account)
        Button { showsLimits = true } label: {
            HStack(spacing: 3) {
                ProviderIcon(provider: account.provider, size: 16)
                    .padding(.trailing, 1)
                ForEach(windows) { LimitRing(window: $0, now: now) }
            }
            .frame(minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(AttachPressStyle())
        .popover(isPresented: $showsLimits, arrowEdge: .top) {
            PhoneLimitsPopover(id: account.id, multi: multi)
                .environment(controller)
                .environment(\.theme, theme)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(theme.chrome)
        }
        .accessibilityLabel(spoken(windows))
        .accessibilityHint("Shows when they reset")
    }

    private func spoken(_ windows: [LimitWindow]) -> String {
        var parts = [Limits.providerName(account.provider)]
        if multi { parts.append(Limits.accountName(account)) }
        parts += windows.map { Limits.spoken($0, now: now) }
        return parts.joined(separator: ", ")
    }
}

/// One limit as a ring: the sidebar's bar (`LimitBar`) bent round. Its share used is
/// an arc from the top, clockwise, in its pace color (`Theme.limitColor`) over the
/// track; a tick across the ring where the window's time stands. Inside, the
/// limit's mark (`Limits.symbol`: 5 for 5 hours, 7 for 7 days, F for Fable).
struct LimitRing: View {
    var window: LimitWindow
    var now: Date

    @Environment(\.theme) private var theme

    /// The track's middle and its line.
    static let radius: CGFloat = 9.5
    static let line: CGFloat = 2.5
    /// How far the tick reaches past the track on either side.
    static let reach: CGFloat = 1.5
    static var size: CGFloat { 2 * (radius + line / 2 + reach) }

    var body: some View {
        let reset = Limits.isReset(window, now: now)
        let used = reset ? 0 : min(100, max(0, window.used)) / 100
        let tick = reset ? nil : Limits.elapsed(window, now: now)
        let color = theme.limitColor(Limits.tone(window, now: now).tone)
        let track = theme.raised
        let hand = theme.foreground.opacity(0.5)
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = Self.radius
                // From the top, clockwise (angles grow clockwise with y down).
                func arc(_ from: Double, _ to: Double) -> Path {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(360 * from - 90),
                             endAngle: .degrees(360 * to - 90), clockwise: false)
                    return p
                }
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(track), lineWidth: Self.line)
                if used > 0 {
                    ctx.stroke(arc(0, max(0.02, used)), with: .color(color),
                               style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                }
                if let tick {
                    let a = (360 * tick - 90) * .pi / 180
                    let inner = r - Self.line / 2 - Self.reach, outer = r + Self.line / 2 + Self.reach
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
                    p.addLine(to: CGPoint(x: c.x + outer * cos(a), y: c.y + outer * sin(a)))
                    ctx.stroke(p, with: .color(hand), lineWidth: 1.5)
                }
            }
            Text(Limits.symbol(window))
                .font(.ui(10.5, .semibold))
                .foregroundStyle(reset ? theme.dim : theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 2 * (Self.radius - Self.line / 2) - 2)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }
}

/// An account's limits under its rings, as the sidebar's open panel lists them in
/// the iPhone's sizes: icon, name and plan, then each limit's name, bar (`LimitBar`),
/// share in its pace color (`Percent`) and time to its reset (`Resets`). It reads the
/// account afresh, so new readings show while it's open.
private struct PhoneLimitsPopover: View {
    var id: String
    var multi: Bool

    @Environment(WorkspaceController.self) private var controller
    @Environment(\.theme) private var theme

    private let size = LimitsPanel.Size.large

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let account = controller.workspace.limits.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    head(account)
                    let windows = Limits.shown(account)
                    if windows.isEmpty {
                        Text("No limits reported")
                            .font(.ui(size.text))
                            .foregroundStyle(theme.dim)
                            .frame(maxWidth: .infinity, minHeight: size.limit, alignment: .leading)
                    }
                    ForEach(windows) { row($0, now: context.date) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .frame(width: 330)
            }
        }
    }

    private func head(_ account: LimitAccount) -> some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: account.provider, size: size.icon)
            Text(multi ? "\(Limits.providerName(account.provider)) · \(Limits.accountName(account))"
                       : Limits.providerName(account.provider))
                .font(.ui(size.name, .medium))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
            if let plan = Limits.planName(account.provider, account.plan) {
                PlanBadge(text: plan, size: size)
            }
            Spacer(minLength: 0)
        }
        .frame(height: size.row)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ w: LimitWindow, now: Date) -> some View {
        HStack(spacing: 6) {
            Text(w.label)
                .font(.ui(size.text))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: size.label, alignment: .leading)
            LimitBar(window: w, now: now)
            Percent(window: w, now: now, size: size, minWidth: size.pct)
            Resets(window: w, now: now, size: size)
        }
        .frame(height: size.limit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Limits.spoken(w, now: now))
    }
}
