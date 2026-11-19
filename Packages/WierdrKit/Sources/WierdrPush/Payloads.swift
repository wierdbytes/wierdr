import Foundation
import WierdrActivity

/// ActivityKit push payloads (`aps` with `event`, `timestamp`, `content-state` …),
/// sealed with `key` (see `ActivitySeal`): the attributes whole, the state's agents.
public enum ActivityPayload {
    public typealias State = AgentsActivityAttributes.ContentState

    /// What lights the phone up: the expanded island or a banner, with a sound or not.
    public struct Alert: Hashable, Sendable {
        public var title: String
        public var body: String
        public var sound: Bool

        public init(title: String, body: String, sound: Bool) {
            self.title = title; self.body = body; self.sound = sound
        }
    }

    /// Starts the activity on a device and subscribes it to `channel` (iOS 18).
    /// ActivityKit requires an alert with a start.
    public static func start(attributes: AgentsActivityAttributes, state: State, channel: String,
                             alert: Alert, stale: Date, now: Date, key: ActivitySealKey?) -> Data {
        var aps = base(event: "start", state: state, now: now, key: key)
        aps["input-push-channel"] = channel
        aps["attributes-type"] = AgentsActivityAttributes.typeName
        // The name is the Mac's to choose: kept short, so the sealed attributes stay small.
        let attributes = AgentsActivityAttributes(host: String(attributes.host.prefix(100)))
        aps["attributes"] = key.map { sealed(attributes, .attributes, $0, open: [:]) } ?? json(attributes)
        aps["alert"] = alertJSON(alert)
        aps["stale-date"] = Int(stale.timeIntervalSince1970)
        return data(aps)
    }

    public static func update(state: State, alert: Alert?, stale: Date, now: Date, key: ActivitySealKey?) -> Data {
        var aps = base(event: "update", state: state, now: now, key: key)
        if let alert { aps["alert"] = alertJSON(alert) }
        aps["stale-date"] = Int(stale.timeIntervalSince1970)
        return data(aps)
    }

    /// Ends it; the Lock Screen keeps it until `dismissal` (in the past: at once).
    public static func end(state: State, dismissal: Date, now: Date, key: ActivitySealKey?) -> Data {
        var aps = base(event: "end", state: state, now: now, key: key)
        aps["dismissal-date"] = Int(dismissal.timeIntervalSince1970)
        return data(aps)
    }

    /// The state with as many agents as fit in `limit` bytes of `content-state`, as
    /// sent (sealed with `key`): pushes are at most 4 KB in all; the rest of `aps` is small.
    public static func fitting(_ state: State, limit: Int = 3000, key: ActivitySealKey?) -> State {
        var s = state
        func size() -> Int {
            (try? JSONSerialization.data(withJSONObject: contentState(s, key: key)))?.count ?? 0
        }
        while !s.agents.isEmpty, size() > limit { s.agents.removeLast() }
        return s
    }

    private static func base(event: String, state: State, now: Date, key: ActivitySealKey?) -> [String: Any] {
        ["timestamp": Int(now.timeIntervalSince1970), "event": event, "content-state": contentState(state, key: key)]
    }

    /// The state as JSON: plain, or the counts and time open and the agents sealed.
    static func contentState(_ state: State, key: ActivitySealKey?) -> Any {
        guard let key else { return json(state) }
        var open = json(state) as? [String: Any] ?? [:]
        open["agents"] = nil
        let context = ActivitySealKey.agentsContext(blocked: state.blocked, done: state.done, working: state.working,
                                                    idle: state.idle, at: state.at)
        return sealed(state.agents, .agents, key, open: open, context: context)
    }

    /// `open` with `"sealed"` (the value) and `"kid"`.
    private static func sealed<T: Encodable>(_ value: T, _ purpose: ActivitySealKey.Purpose, _ key: ActivitySealKey,
                                             open: [String: Any], context: String = "") -> [String: Any] {
        var out = open
        // Sealing what was just encoded can't fail; an empty seal shows as unreadable.
        out["sealed"] = (try? key.seal(value, purpose, context: context)) ?? ""
        out["kid"] = key.kid
        return out
    }

    private static func alertJSON(_ a: Alert) -> [String: Any] {
        var out: [String: Any] = ["title": a.title, "body": a.body]
        if a.sound { out["sound"] = "default" }
        return out
    }

    /// The value as JSON ActivityKit decodes with a plain `JSONDecoder`.
    static func json<T: Encodable>(_ value: T) -> Any {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private static func data(_ aps: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys])) ?? Data()
    }
}
