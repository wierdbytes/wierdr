import Foundation

/// The `wierdr-push` document in herdr-core on the computer the phone connects
/// to: the devices that want the agents Live Activity and how to start it there.
/// The app writes its own entry (compare-and-swap) whenever it connects and its
/// push-to-start token changes; `wierdr-push` on that computer reads it.
public struct PushRegistry: Codable, Hashable, Sendable {
    public static let documentName = "wierdr-push"
    public static let currentSchema = 1

    public var schema: Int
    /// By device id (`identifierForVendor`).
    public var devices: [String: Device]

    public init(schema: Int = PushRegistry.currentSchema, devices: [String: Device] = [:]) {
        self.schema = schema; self.devices = devices
    }

    public struct Device: Codable, Hashable, Sendable {
        /// Shown in the pusher's log.
        public var name: String
        /// The app's bundle id: the APNs topic is `<bundle>.push-type.liveactivity`.
        public var bundle: String
        /// APNs environment of the app's signature: `development` (sandbox) or `production`.
        public var env: String
        /// ActivityKit push-to-start token, hex.
        public var startToken: String
        /// When the app wrote it (UNIX seconds).
        public var updated: Double
        /// Whether the device showed a Wierdr activity when the app wrote it (nil: unknown).
        /// `false` after a start means it's gone (dismissed, the app reinstalled): the
        /// pusher starts it there again.
        public var hasActivity: Bool?

        public init(name: String, bundle: String, env: String, startToken: String, updated: Double,
                    hasActivity: Bool? = nil) {
            self.name = name; self.bundle = bundle; self.env = env
            self.startToken = startToken; self.updated = updated; self.hasActivity = hasActivity
        }

        enum CodingKeys: String, CodingKey {
            case name, bundle, env, updated
            case startToken = "start_token"
            case hasActivity = "has_activity"
        }

        /// The same registration, whenever written.
        public func same(as other: Device) -> Bool {
            name == other.name && bundle == other.bundle && env == other.env && startToken == other.startToken
                && hasActivity == other.hasActivity
        }
    }

    /// Decodes a document's JSON (`nil`/`null`/garbage → empty).
    public static func decode(_ data: Data?) -> PushRegistry {
        guard let data, let r = try? JSONDecoder().decode(PushRegistry.self, from: data) else { return PushRegistry() }
        return r
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}

extension Data {
    /// Lowercase hex (APNs device tokens).
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
