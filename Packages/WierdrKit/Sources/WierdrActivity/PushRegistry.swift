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
        /// The id of the seal key (`SealDocument`) the app keeps for the widget, if any:
        /// without it the activity there shows the counts but not the agents.
        public var sealKid: String?
        /// The push relay's grant for `startToken` (`g1.<expiry>.<mac>`, from the app's App
        /// Attest registration): a pusher going through the relay starts the activity here
        /// and makes channels with it.
        public var relayGrant: String?

        public init(name: String, bundle: String, env: String, startToken: String, updated: Double,
                    hasActivity: Bool? = nil, sealKid: String? = nil, relayGrant: String? = nil) {
            self.name = name; self.bundle = bundle; self.env = env
            self.startToken = startToken; self.updated = updated; self.hasActivity = hasActivity
            self.sealKid = sealKid; self.relayGrant = relayGrant
        }

        /// When `relayGrant` runs out (nil without one or when it can't be read).
        public var relayGrantExpiry: Date? { relayGrant.flatMap(RelayGrant.expiry) }

        enum CodingKeys: String, CodingKey {
            case name, bundle, env, updated
            case startToken = "start_token"
            case hasActivity = "has_activity"
            case sealKid = "seal_kid"
            case relayGrant = "relay_grant"
        }

        /// The same registration, whenever written.
        public func same(as other: Device) -> Bool {
            name == other.name && bundle == other.bundle && env == other.env && startToken == other.startToken
                && hasActivity == other.hasActivity && sealKid == other.sealKid && relayGrant == other.relayGrant
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

/// The push relay's grants (`Relay/src/grants.ts`): `g2.<expiry unix seconds>.<owner>.<mac>`
/// (`owner`: the App Attest key it was given to); `g1.<expiry>.<mac>` before.
public enum RelayGrant {
    public static func expiry(_ grant: String) -> Date? {
        let parts = grant.split(separator: ".")
        guard (parts.count == 4 && parts[0] == "g2") || (parts.count == 3 && parts[0] == "g1"),
              let t = Double(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}

extension Data {
    /// Lowercase hex (APNs device tokens).
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
