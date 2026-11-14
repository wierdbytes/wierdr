import ActivityKit
import SwiftUI
import WidgetKit
import WierdrActivity

/// The agents Live Activity: counts by status and the most urgent agents, on the
/// Lock Screen (and the Watch's Smart Stack) and in the Dynamic Island. Started,
/// updated and ended by `wierdr-push` on the computer; a tap on an agent opens
/// its pane in Wierdr.
struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Palette.background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(context.state.agents.first.map { AgentLink.url(address: $0.id) })
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        AppMark(size: 16)
                        Text("Wierdr")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counts(state: s, size: 13)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ForEach(s.agents.prefix(2)) { agent in
                            Link(destination: AgentLink.url(address: agent.id)) { AgentLine(agent: agent) }
                        }
                        if s.agents.isEmpty {
                            Text(context.isStale ? "Not updated lately" : "Nothing running")
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.dim)
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                if let top = s.top {
                    HStack(spacing: 4) {
                        StatusMark(status: top, size: 13)
                        Text("\(s.count(top))").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Palette.color(top))
                    }
                } else {
                    AppMark(size: 14)
                }
            } compactTrailing: {
                if let next = AgentStatusWord.urgent.first(where: { $0 != s.top && s.count($0) > 0 }) {
                    HStack(spacing: 4) {
                        StatusMark(status: next, size: 11)
                        Text("\(s.count(next))").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Palette.color(next))
                    }
                } else {
                    AppMark(size: 15)
                }
            } minimal: {
                if let top = s.top { StatusMark(status: top, size: 13) } else { AppMark(size: 14) }
            }
            .widgetURL(s.agents.first.map { AgentLink.url(address: $0.id) })
            .keylineTint(s.top.map(Palette.color) ?? Palette.dim)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    var state: AgentsActivityAttributes.ContentState
    var stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                AppMark(size: 16)
                Text("Wierdr")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if stale {
                    Text("Not updated")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.dim)
                } else {
                    Counts(state: state, size: 13)
                }
            }
            // Three two-line rows fit the Lock Screen's ~160 pt; the counts above tell the rest.
            VStack(spacing: 7) {
                ForEach(state.agents.prefix(3)) { agent in
                    Link(destination: AgentLink.url(address: agent.id)) { AgentLine(agent: agent) }
                }
                if state.agents.isEmpty {
                    Text(state.idle > 0 ? "\(state.idle) idle" : "No agents")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(stale ? 0.7 : 1)
    }
}

// MARK: - Pieces

/// One agent, in two lines as in the sidebar: status and title; under the title its
/// space · model and how long in this status (no program icons: too busy).
private struct AgentLine: View {
    var agent: AgentsActivityAttributes.Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                StatusMark(status: agent.status, size: 12)
                    .frame(width: 14)
                Text(agent.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(place)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Counts by itself on the device (minutes only while locked); no pushes.
                // A fixed width: a self-updating text takes all the room it's offered,
                // and with `.fixedSize()` the card renders empty. Fits `23 min, 36 secs`.
                if let since = agent.sinceDate {
                    Text(since, style: .relative)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 104, alignment: .trailing)
                }
            }
            .padding(.leading, 22)
        }
    }

    /// `space · model`, the machine first for an agent on an added one.
    private var place: String {
        ([agent.machine, agent.space, agent.model].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · ")
    }
}

/// Counts by status: `! 1  ● 2  ◔ 3`.
private struct Counts: View {
    var state: AgentsActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        HStack(spacing: 9) {
            ForEach(AgentStatusWord.urgent, id: \.self) { status in
                let n = state.count(status)
                if n > 0 {
                    HStack(spacing: 4) {
                        StatusMark(status: status, size: size - 2)
                        Text("\(n)")
                            .font(.system(size: size, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.color(status))
                    }
                }
            }
        }
    }
}

/// The app's status marks: a filled dot (needs you, done), Herdr's spinner (a ring with
/// a quarter arc), an empty ring.
private struct StatusMark: View {
    var status: AgentStatusWord
    var size: CGFloat

    var body: some View {
        let color = Palette.color(status)
        switch status {
        case .blocked, .done:
            Circle().fill(color).frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
        case .working:
            let k = size / 24
            ZStack {
                Circle().stroke(color.opacity(0.28), lineWidth: 3.2 * k)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.2 * k, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18.8 * k, height: 18.8 * k)
            .frame(width: size, height: size)
        case .idle:
            Circle().strokeBorder(color, lineWidth: 1.5).frame(width: size * 0.6, height: size * 0.6)
                .frame(width: size, height: size)
        }
    }
}

/// Wierdr's icon (the app icon, small), rounded like one.
private struct AppMark: View {
    var size: CGFloat

    var body: some View {
        Image("WierdrIcon")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

/// Atom One Dark, as the app's dark theme (the Lock Screen card is always dark).
enum Palette {
    static let background = Color(red: 0x21 / 255, green: 0x25 / 255, blue: 0x2b / 255)
    static let working = Color(red: 0xe5 / 255, green: 0xc0 / 255, blue: 0x7b / 255)
    static let blocked = Color(red: 0xe0 / 255, green: 0x6c / 255, blue: 0x75 / 255)
    static let done = Color(red: 0x98 / 255, green: 0xc3 / 255, blue: 0x79 / 255)
    static let idle = Color(red: 0x6f / 255, green: 0x71 / 255, blue: 0x75 / 255)
    static let foreground = Color(red: 0xee / 255, green: 0xee / 255, blue: 0xef / 255)
    static let muted = Color(red: 0x9c / 255, green: 0x9e / 255, blue: 0xa1 / 255)
    static let dim = Color(red: 0x6f / 255, green: 0x71 / 255, blue: 0x75 / 255)
    static let accent = Color(red: 0x61 / 255, green: 0xaf / 255, blue: 0xef / 255)

    static func color(_ s: AgentStatusWord) -> Color {
        switch s {
        case .blocked: return blocked
        case .done: return done
        case .working: return working
        case .idle: return idle
        }
    }
}
