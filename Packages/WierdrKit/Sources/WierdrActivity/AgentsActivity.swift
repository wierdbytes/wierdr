import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// The agents Live Activity: what the Lock Screen and the Dynamic Island show
/// about the agents on a computer, as the Mac's pusher (`wierdr-push`) sends it
/// through APNs and the widget extension draws it.
///
/// Push payloads carry these as JSON (`attributes` and `content-state`), decoded by
/// ActivityKit with a plain `JSONDecoder`: so no `Date`s here (they would be
/// seconds since 2001), times are UNIX seconds.
public struct AgentsActivityAttributes: Codable, Hashable, Sendable {
    /// The type name a push-to-start payload names (`attributes-type`).
    public static let typeName = "AgentsActivityAttributes"

    /// The computer the agents run on (its name, e.g. `mentoair`).
    public var host: String

    public init(host: String) { self.host = host }

    public struct ContentState: Codable, Hashable, Sendable {
        /// Agents by status, as the iPhone's agents list groups them (an agent counts
        /// where its most urgent sub-agent would put it).
        public var blocked: Int
        public var done: Int
        public var working: Int
        public var idle: Int
        /// The most urgent agents, in the list's order (needs you, done, working; no idle).
        public var agents: [Agent]
        /// When the pusher built it (UNIX seconds).
        public var at: Double

        public init(blocked: Int = 0, done: Int = 0, working: Int = 0, idle: Int = 0,
                    agents: [Agent] = [], at: Double = 0) {
            self.blocked = blocked; self.done = done; self.working = working; self.idle = idle
            self.agents = agents; self.at = at
        }

        /// Agents that need you, are done or are working.
        public var active: Int { blocked + done + working }

        /// The same content, whatever its time (what changed is worth a push).
        public func sameContent(as other: ContentState) -> Bool {
            var a = self, b = other
            a.at = 0; b.at = 0
            return a == b
        }

        public func count(_ status: AgentStatusWord) -> Int {
            switch status {
            case .blocked: return blocked
            case .done: return done
            case .working: return working
            case .idle: return idle
            }
        }

        /// The most urgent status with an agent, if any but idle.
        public var top: AgentStatusWord? {
            AgentStatusWord.urgent.first { count($0) > 0 }
        }
    }

    /// One agent's row.
    public struct Agent: Codable, Hashable, Sendable, Identifiable {
        /// Its terminal's qualified address (`t5w`, `lf/t1`): where a tap goes.
        public var id: String
        /// The row's title (status message, tab name, telling title or program).
        public var title: String
        /// Its space's name.
        public var space: String
        /// Its space's avatar color, `#rrggbb`.
        public var spaceColor: String
        /// Machine name for agents on an added machine, else nil.
        public var machine: String?
        public var status: AgentStatusWord
        /// When its status last changed (UNIX seconds).
        public var since: Double?
        /// Model as the sidebar shows it (`Opus 5.5`), else the program's name.
        public var model: String
        /// Asset name of the program's icon (`program.claude`).
        public var icon: String
        /// One-color glyph (tinted with `color`) or a full-color picture.
        public var tint: Bool
        public var color: String

        public init(id: String, title: String, space: String, spaceColor: String = "#22a99a",
                    machine: String? = nil, status: AgentStatusWord, since: Double? = nil, model: String,
                    icon: String, tint: Bool = true, color: String = "#ffffff") {
            self.id = id; self.title = title; self.space = space; self.spaceColor = spaceColor
            self.machine = machine; self.status = status; self.since = since; self.model = model
            self.icon = icon; self.tint = tint; self.color = color
        }

        public var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }
    }
}

/// An agent's status as the activity spells it.
public enum AgentStatusWord: String, Codable, Hashable, Sendable, CaseIterable {
    case blocked, done, working, idle

    /// Most urgent first.
    public static let urgent: [AgentStatusWord] = [.blocked, .done, .working]

    public var label: String {
        switch self {
        case .blocked: return "needs you"
        case .done: return "done"
        case .working: return "working"
        case .idle: return "idle"
        }
    }
}

#if canImport(ActivityKit) && os(iOS)
extension AgentsActivityAttributes: ActivityAttributes {}
#endif

// MARK: - Opening an agent

/// `wierdr://agent?t=<address>`: the app opens that agent's pane (a tap on its row).
public enum AgentLink {
    public static let scheme = "wierdr"

    public static func url(address: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "agent"
        c.queryItems = [URLQueryItem(name: "t", value: address)]
        return c.url!
    }

    /// The terminal address of a `wierdr://agent?t=…` link.
    public static func address(in url: URL) -> String? {
        guard url.scheme == scheme, url.host == "agent",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return c.queryItems?.first { $0.name == "t" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
