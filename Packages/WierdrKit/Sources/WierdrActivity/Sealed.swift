import CryptoKit
import Foundation

/// The agents Live Activity, sealed for the phone: APNs and the push relay see the
/// counts but not the agents' titles, spaces, models, machines or addresses, nor the
/// computer's name.
///
/// `wierdr-push` on the Mac makes the key (`ActivitySealKey`), keeps it in
/// `~/.config/wierdr/seal-key` and publishes it in its core's `wierdr-push-seal`
/// document (`SealDocument`); the app reads it there when it connects (over SSH,
/// past APNs) and keeps it as a file in the App Group (`ActivitySeal.store`), where
/// the widget extension reads it: the Live Activity's sandbox on the iPhone has no
/// keychain, but reads the App Group, the locked phone too (see
/// docs/research/push-relay.md).
///
/// A sealed value is `base64(AES-GCM(padded(zlib(JSON))))` (nonce ‖ ciphertext ‖ tag):
/// the compressed JSON after its 4-byte length, zeros up to a multiple of 64 bytes (so
/// the length tells less); authenticated with it are its purpose, the key id and what it
/// goes with in the open (`context`: the agents' seal is bound to the counts and time
/// beside it, so those can't be changed or a seal moved to another push), next to
/// `"kid"` in the payload.
public struct ActivitySealKey: Sendable {
    /// The key's id: the first 8 hex digits of its SHA-256 (which key opens a seal).
    public let kid: String
    public let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
        kid = key.withUnsafeBytes { SHA256.hash(data: Data($0)) }.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// A new random 256-bit key.
    public static func generate() -> ActivitySealKey { ActivitySealKey(key: SymmetricKey(size: .bits256)) }

    public init?(base64: String) {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32 else { return nil }
        self.init(key: SymmetricKey(data: data))
    }

    public var base64: String { key.withUnsafeBytes { Data($0) }.base64EncodedString() }

    /// What a seal is of: a seal of one can't pass for the other.
    public enum Purpose: String, Sendable { case agents, attributes }

    public func seal<T: Encodable>(_ value: T, _ purpose: Purpose, context: String = "") throws -> String {
        let plain = try JSONEncoder().encode(value)
        let packed = try (plain as NSData).compressed(using: .zlib) as Data
        var padded = Data(count: 4)
        padded.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(packed.count).bigEndian, as: UInt32.self) }
        padded += packed
        padded += Data(count: (64 - padded.count % 64) % 64)
        let box = try AES.GCM.seal(padded, using: key, authenticating: Self.aad(purpose, kid, context))
        return box.combined!.base64EncodedString()
    }

    public func open<T: Decodable>(_ type: T.Type, _ text: String, _ purpose: Purpose, context: String = "") -> T? {
        guard let data = Data(base64Encoded: text),
              let box = try? AES.GCM.SealedBox(combined: data),
              let padded = try? AES.GCM.open(box, using: key, authenticating: Self.aad(purpose, kid, context)),
              padded.count >= 4 else { return nil }
        let n = Int(padded.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard n <= padded.count - 4,
              let plain = try? (Data(padded.dropFirst(4).prefix(n)) as NSData).decompressed(using: .zlib) as Data
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: plain)
    }

    private static func aad(_ purpose: Purpose, _ kid: String, _ context: String) -> Data {
        Data("wierdr-activity/\(purpose.rawValue)/\(kid)/\(context)".utf8)
    }

    /// What the agents' seal is bound to: the counts and time in the open beside it
    /// (`at` by its bits, so no formatting can differ).
    public static func agentsContext(blocked: Int, done: Int, working: Int, idle: Int, at: Double) -> String {
        "\(blocked),\(done),\(working),\(idle),\(at.bitPattern)"
    }
}

/// The `wierdr-push-seal` document in the Mac's core: the key the pusher seals with.
/// Only `wierdr-push` writes it; whoever can read the core (and so sees the agents
/// anyway) can read it.
public struct SealDocument: Codable, Hashable, Sendable {
    public static let documentName = "wierdr-push-seal"
    public static let currentSchema = 1

    public var schema: Int
    public var kid: String
    /// The key, base64 (32 bytes).
    public var key: String

    public init(_ key: ActivitySealKey) {
        schema = Self.currentSchema; kid = key.kid; self.key = key.base64
    }

    /// The key it holds, if well formed.
    public var sealKey: ActivitySealKey? {
        guard schema == Self.currentSchema, let k = ActivitySealKey(base64: key), k.kid == kid else { return nil }
        return k
    }

    /// Decodes a document's JSON (`nil`/`null`/garbage → nil).
    public static func decode(_ data: Data?) -> SealDocument? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SealDocument.self, from: data)
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}

/// Where the phone keeps the keys (one per computer it connects to), and how sealed
/// payloads find theirs.
public enum ActivitySeal {
    /// The payload's fields next to the open ones.
    enum Keys: String, CodingKey { case sealed, kid }

    /// `WierdrAppGroup` in the app's and the widget extension's Info.plist.
    static var appGroup: String? { Bundle.main.object(forInfoDictionaryKey: "WierdrAppGroup") as? String }

    static func url(kid: String) -> URL? {
        guard let appGroup, kid.allSatisfy(\.isHexDigit), !kid.isEmpty,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return dir.appendingPathComponent("Seal", isDirectory: true).appendingPathComponent("\(kid).key")
    }

    /// Keeps a key for the widget: a file in the App Group, the owner's only,
    /// readable after the first unlock (the widget draws on the locked phone), not
    /// backed up. False without the App Group.
    @discardableResult
    public static func store(_ key: ActivitySealKey) -> Bool {
        guard var url = url(kid: key.kid) else { return false }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? Data(contentsOf: url)) != Data(key.base64.utf8) {
                try Data(key.base64.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            return false
        }
        lock.withLock { cache[key.kid] = key }
        return true
    }

    /// The key with this id, from the App Group (kept once read).
    public static func key(kid: String) -> ActivitySealKey? {
        if let k = lock.withLock({ cache[kid] }) { return k }
        guard let url = url(kid: kid), let data = try? Data(contentsOf: url),
              let k = ActivitySealKey(base64: String(decoding: data, as: UTF8.self)), k.kid == kid else { return nil }
        lock.withLock { cache[kid] = k }
        return k
    }

    /// Finds the key a payload names (tests put theirs here, per task).
    @TaskLocal public static var lookup: @Sendable (String) -> ActivitySealKey? = { key(kid: $0) }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: ActivitySealKey] = [:]

    /// Opens what a payload sealed, if this phone has its key.
    static func open<T: Decodable>(_ type: T.Type, in decoder: Decoder, _ purpose: ActivitySealKey.Purpose,
                                   context: String = "") throws -> T? {
        let c = try decoder.container(keyedBy: Keys.self)
        let text = try c.decode(String.self, forKey: .sealed)
        let kid = try c.decode(String.self, forKey: .kid)
        return lookup(kid)?.open(type, text, purpose, context: context)
    }

    /// Whether plain (unsealed) agents and attributes are taken: on the Mac (the pusher's
    /// state file keeps them plain), in tests and debug builds (the local demo activity); not
    /// in an iPhone's release build, where every push is sealed.
    public static var takesPlain: Bool {
        #if os(iOS) && !DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Whether a payload is sealed.
    static func isSealed(_ decoder: Decoder) throws -> Bool {
        try decoder.container(keyedBy: Keys.self).contains(.sealed)
    }
}
