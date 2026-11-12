import Foundation
import WierdrActivity

/// Where an activity's pushes go: one app (bundle id) in one APNs environment.
/// Every device of a lane shows the same activity, subscribed to the lane's channel.
public struct Lane: Codable, Hashable, Sendable {
    public var bundle: String
    public var env: APNsEnvironment

    public init(bundle: String, env: APNsEnvironment) { self.bundle = bundle; self.env = env }

    public var key: String { "\(bundle) \(env.rawValue)" }
}

/// When to start, update and end the agents Live Activity (pure: tests drive it
/// with a clock). One activity per lane while any agent needs you, is done or is
/// working; it is started on each registered device with push-to-start, then
/// updated and ended by broadcasts on its channel. Each activity gets a channel of
/// its own (the lane's spare, which the pusher replaces once used), so an end, or
/// the channel's stored last message, never reaches the next activity.
public struct Planner: Sendable {
    public typealias State = AgentsActivityAttributes.ContentState

    public struct Settings: Sendable {
        /// Nothing active for this long ends the activity (a short break in a turn doesn't).
        public var endDelay: TimeInterval = 20
        /// ActivityKit ends an activity after 8 hours; start a fresh one a bit before.
        public var maxAge: TimeInterval = 7.75 * 3600
        /// Updates without an alert at most this often (priority 5, coalesced).
        public var minInterval: TimeInterval = 5
        /// An update this often anyway, moving the stale date on.
        public var heartbeat: TimeInterval = 10 * 60
        /// The activity reads stale this long after the last push (the Mac asleep, off line).
        public var staleAfter: TimeInterval = 25 * 60

        public init() {}
    }

    /// A started activity (persisted, so a restarted pusher goes on with it).
    public struct Running: Codable, Hashable, Sendable {
        public var lane: Lane
        public var channel: String
        public var startedAt: Double
        /// Device id → the push-to-start token it was started with.
        public var devices: [String: String]
        /// What the devices show (the last state sent).
        public var last: State
        public var lastSentAt: Double
        /// Since when nothing is active (it ends after `endDelay`).
        public var inactiveSince: Double?
        /// The last update failed: send the state again.
        public var dirty: Bool = false
    }

    public enum Action: Hashable, Sendable {
        /// Push-to-start on one device, subscribed to the channel.
        case start(lane: Lane, channel: String, device: String, token: String, state: State, alert: ActivityPayload.Alert)
        /// Broadcast an update.
        case update(lane: Lane, channel: String, state: State, priority: Int, alert: ActivityPayload.Alert?)
        /// Broadcast the end (dismissed at once).
        case end(lane: Lane, channel: String, state: State)
    }

    public var settings = Settings()
    /// By lane key.
    public var running: [String: Running] = [:]

    public init(settings: Settings = Settings(), running: [String: Running] = [:]) {
        self.settings = settings
        self.running = running
    }

    /// The pushes to send now.
    /// - Parameters:
    ///   - summary: what the activity should show.
    ///   - host: the computer's name (start alerts).
    ///   - devices: registered devices (bad tokens already left out).
    ///   - channels: each lane's spare channel (by lane key) for the next start; lanes without one wait.
    public mutating func step(now: Date, summary: State, host: String,
                              devices: [String: PushRegistry.Device], channels: [String: String]) -> [Action] {
        let t = now.timeIntervalSince1970
        var actions: [Action] = []
        var lanes: [String: (lane: Lane, devices: [String: PushRegistry.Device])] = [:]
        for (id, d) in devices {
            guard let env = APNsEnvironment(rawValue: d.env), !d.startToken.isEmpty, !d.bundle.isEmpty else { continue }
            let lane = Lane(bundle: d.bundle, env: env)
            lanes[lane.key, default: (lane, [:])].devices[id] = d
        }
        let active = summary.active > 0

        // Activities whose devices are all gone: end them.
        for (key, r) in running where lanes[key] == nil {
            actions.append(.end(lane: r.lane, channel: r.channel, state: summary))
            running[key] = nil
        }

        for key in lanes.keys.sorted() {
            let (lane, laneDevices) = lanes[key]!
            if var r = running[key] {
                if !active {
                    let since = r.inactiveSince ?? t
                    if t - since >= settings.endDelay {
                        actions.append(.end(lane: lane, channel: r.channel, state: summary))
                        running[key] = nil
                    } else {
                        r.inactiveSince = since
                        running[key] = r
                    }
                    continue
                }
                r.inactiveSince = nil
                if t - r.startedAt >= settings.maxAge, let fresh = channels[key], fresh != r.channel {
                    // A fresh activity (on a channel of its own) before ActivityKit ends this one.
                    actions.append(.end(lane: lane, channel: r.channel, state: summary))
                    running[key] = nil
                    actions += start(lane: lane, devices: laneDevices, channel: fresh, summary: summary,
                                     host: host, now: t, sound: false)
                    continue
                }
                // Devices that registered since (or got a new token): start it there too.
                var joined: [String: PushRegistry.Device] = [:]
                for (id, d) in laneDevices where r.devices[id] != d.startToken { joined[id] = d }
                r.devices = r.devices.filter { laneDevices[$0.key] != nil }
                if !joined.isEmpty {
                    for id in joined.keys.sorted() {
                        let d = joined[id]!
                        actions.append(.start(lane: lane, channel: r.channel, device: id, token: d.startToken,
                                              state: summary, alert: startAlert(summary, host: host, sound: false)))
                        r.devices[id] = d.startToken
                    }
                }
                if r.dirty || !summary.sameContent(as: r.last) {
                    let alert = Self.alert(from: r.last, to: summary)
                    if alert != nil || t - r.lastSentAt >= settings.minInterval {
                        actions.append(.update(lane: lane, channel: r.channel, state: summary,
                                               priority: alert == nil ? 5 : 10, alert: alert))
                        r.last = summary
                        r.lastSentAt = t
                        r.dirty = false
                    }
                } else if t - r.lastSentAt >= settings.heartbeat {
                    actions.append(.update(lane: lane, channel: r.channel, state: summary, priority: 5, alert: nil))
                    r.last = summary
                    r.lastSentAt = t
                }
                running[key] = r
            } else if active, let channel = channels[key] {
                actions += start(lane: lane, devices: laneDevices, channel: channel, summary: summary,
                                 host: host, now: t, sound: summary.blocked > 0)
            }
        }
        return actions
    }

    private mutating func start(lane: Lane, devices: [String: PushRegistry.Device], channel: String,
                                summary: State, host: String, now t: Double, sound: Bool) -> [Action] {
        var r = Running(lane: lane, channel: channel, startedAt: t, devices: [:], last: summary, lastSentAt: t)
        var actions: [Action] = []
        for id in devices.keys.sorted() {
            let d = devices[id]!
            actions.append(.start(lane: lane, channel: channel, device: id, token: d.startToken,
                                  state: summary, alert: startAlert(summary, host: host, sound: sound)))
            r.devices[id] = d.startToken
        }
        running[lane.key] = r
        return actions
    }

    /// A start's alert (ActivityKit requires one): the computer and the counts.
    func startAlert(_ s: State, host: String, sound: Bool) -> ActivityPayload.Alert {
        ActivityPayload.Alert(title: host, body: ActivitySummary.line(s), sound: sound)
    }

    /// An update's alert: an agent that newly needs you (with a sound), else one
    /// newly done (silent: it only lights the screen and opens the island).
    static func alert(from old: State, to new: State) -> ActivityPayload.Alert? {
        let before = Dictionary(old.agents.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        for (status, title, sound) in [(AgentStatusWord.blocked, "Needs you", true), (.done, "Done", false)] {
            let fresh = new.agents.filter { $0.status == status && before[$0.id] != status }
            guard let first = fresh.first else { continue }
            var body = "\(first.title) — \(first.space)"
            if fresh.count > 1 { body += " and \(fresh.count - 1) more" }
            return ActivityPayload.Alert(title: title, body: body, sound: sound)
        }
        return nil
    }

    /// The stale date for a push sent now.
    public func staleDate(now: Date) -> Date { now.addingTimeInterval(settings.staleAfter) }

    /// Forget a lane's activity (its channel is gone): the next step starts afresh.
    public mutating func drop(lane: Lane) { running[lane.key] = nil }

    /// Forget that a device shows it (its start failed): the next step tries again.
    public mutating func drop(device: String, lane: Lane) { running[lane.key]?.devices[device] = nil }

    /// An update didn't go out: the next step sends the state again.
    public mutating func resend(lane: Lane) { running[lane.key]?.dirty = true }
}
