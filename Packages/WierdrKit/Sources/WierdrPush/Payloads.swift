import Foundation
import WierdrActivity

/// ActivityKit push payloads (`aps` with `event`, `timestamp`, `content-state` …).
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
                             alert: Alert, stale: Date, now: Date) -> Data {
        var aps = base(event: "start", state: state, now: now)
        aps["input-push-channel"] = channel
        aps["attributes-type"] = AgentsActivityAttributes.typeName
        aps["attributes"] = json(attributes)
        aps["alert"] = alertJSON(alert)
        aps["stale-date"] = Int(stale.timeIntervalSince1970)
        return data(aps)
    }

    public static func update(state: State, alert: Alert?, stale: Date, now: Date) -> Data {
        var aps = base(event: "update", state: state, now: now)
        if let alert { aps["alert"] = alertJSON(alert) }
        aps["stale-date"] = Int(stale.timeIntervalSince1970)
        return data(aps)
    }

    /// Ends it; the Lock Screen keeps it until `dismissal` (in the past: at once).
    public static func end(state: State, dismissal: Date, now: Date) -> Data {
        var aps = base(event: "end", state: state, now: now)
        aps["dismissal-date"] = Int(dismissal.timeIntervalSince1970)
        return data(aps)
    }

    /// The state with as many agents as fit in `limit` bytes of `content-state`
    /// (pushes are at most 4 KB in all; the rest of `aps` is small).
    public static func fitting(_ state: State, limit: Int = 3000) -> State {
        var s = state
        while !s.agents.isEmpty, ((try? JSONEncoder().encode(s))?.count ?? 0) > limit { s.agents.removeLast() }
        return s
    }

    private static func base(event: String, state: State, now: Date) -> [String: Any] {
        ["timestamp": Int(now.timeIntervalSince1970), "event": event, "content-state": json(state)]
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
