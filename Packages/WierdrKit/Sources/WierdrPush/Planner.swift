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
        /// Nothing active for this long ends the activity; the devices show the idle
        /// state meanwhile. Long, because a start must carry an alert (ActivityKit drops
        /// a push-to-start without one), and that buzzes the phone: while it's up, an
        /// agent set to work is a plain update.
        public var endDelay: TimeInterval = 2 * 3600
        /// A start for done agents only waits this long: one another client looks at
        /// right away (or a blip) starts nothing.
        public var doneStartDelay: TimeInterval = 5
        /// ActivityKit ends an activity after 8 hours; start a fresh one a bit before.
        public var maxAge: TimeInterval = 7.75 * 3600
        /// Updates that change no status (titles, models) at most this often (priority 5).
        public var minInterval: TimeInterval = 5
        /// The shown ages (`28m`) are refreshed at most this often, when one would change.
        public var tickInterval: TimeInterval = 60
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
        /// Device id → when it was started there (a later "no activity" means it's gone).
        public var startedOn: [String: Double]?
    }

    /// A device's activity counts as gone when the app says so this long after its start
    /// (the start may still be on its way when the app writes).
    static let goneGrace: TimeInterval = 15

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
    /// Since when only done agents are active (the start waits `doneStartDelay`).
    var doneSince: Double?

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

        // Only done agents and nothing running: wait a moment before starting.
        let doneOnly = active && summary.working == 0 && summary.blocked == 0
        if !doneOnly { doneSince = nil } else if doneSince == nil { doneSince = t }

        for key in lanes.keys.sorted() {
            let (lane, laneDevices) = lanes[key]!
            guard var r = running[key] else {
                guard active, let channel = channels[key] else { continue }
                if doneOnly, t - (doneSince ?? t) < settings.doneStartDelay { continue }
                actions += start(lane: lane, devices: laneDevices, channel: channel, summary: summary,
                                 host: host, now: t, sound: summary.blocked > 0)
                continue
            }
            if active {
                r.inactiveSince = nil
            } else {
                let since = r.inactiveSince ?? t
                if t - since >= settings.endDelay {
                    actions.append(.end(lane: lane, channel: r.channel, state: summary))
                    running[key] = nil
                    continue
                }
                r.inactiveSince = since
            }
            if t - r.startedAt >= settings.maxAge, !active || channels[key].map({ $0 != r.channel }) == true {
                // Before ActivityKit ends it: a fresh one (on a channel of its own) while
                // agents are at it, else just the end.
                actions.append(.end(lane: lane, channel: r.channel, state: summary))
                running[key] = nil
                if active, let fresh = channels[key] {
                    actions += start(lane: lane, devices: laneDevices, channel: fresh, summary: summary,
                                     host: host, now: t, sound: false)
                }
                continue
            }
            // Devices that registered since (or got a new token), or where it's gone
            // (dismissed, the app reinstalled: the app wrote so after the start): start it there.
            r.devices = r.devices.filter { laneDevices[$0.key] != nil }
            for id in laneDevices.keys.sorted() where active {
                let d = laneDevices[id]!
                let gone = d.hasActivity == false && d.updated > (r.startedOn?[id] ?? r.startedAt) + Self.goneGrace
                guard r.devices[id] != d.startToken || gone else { continue }
                actions.append(.start(lane: lane, channel: r.channel, device: id, token: d.startToken,
                                      state: summary, alert: startAlert(summary, host: host, sound: false)))
                r.devices[id] = d.startToken
                r.startedOn = (r.startedOn ?? [:]).merging([id: t]) { $1 }
            }
            if let update = update(from: r, to: summary, now: t) {
                actions.append(.update(lane: lane, channel: r.channel, state: summary,
                                       priority: update.priority, alert: update.alert))
                r.last = summary
                r.lastSentAt = t
                r.dirty = false
            }
            running[key] = r
        }
        return actions
    }

    /// Whether to update a running activity now, and how: a status change (also to
    /// nothing active, so another client's look shows at once) or an alert right
    /// away with priority 10; other changes coalesced with priority 5; a refresh when
    /// a shown age would change; a heartbeat.
    private func update(from r: Running, to summary: State, now t: Double)
        -> (priority: Int, alert: ActivityPayload.Alert?)? {
        let elapsed = t - r.lastSentAt
        if r.dirty || !summary.sameContent(as: r.last) {
            let alert = Self.alert(from: r.last, to: summary)
            if alert != nil || Self.statusChanged(from: r.last, to: summary) { return (10, alert) }
            return elapsed >= settings.minInterval || r.dirty ? (5, nil) : nil
        }
        if elapsed >= settings.tickInterval,
           Self.ticks(summary, at: t) != Self.ticks(r.last, at: r.lastSentAt) {
            return (5, nil)
        }
        return elapsed >= settings.heartbeat ? (5, nil) : nil
    }

    /// Counts, or which agents show with which status, differ.
    static func statusChanged(from old: State, to new: State) -> Bool {
        [old.blocked, old.done, old.working, old.idle] != [new.blocked, new.done, new.working, new.idle]
            || old.agents.map { "\($0.id) \($0.status.rawValue)" } != new.agents.map { "\($0.id) \($0.status.rawValue)" }
    }

    /// The shown ages, without seconds.
    static func ticks(_ s: State, at t: Double) -> [String?] {
        let now = Date(timeIntervalSince1970: t)
        return s.agents.map { AgentAge.tick(since: $0.sinceDate, now: now) }
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
            r.startedOn = (r.startedOn ?? [:]).merging([id: t]) { $1 }
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
