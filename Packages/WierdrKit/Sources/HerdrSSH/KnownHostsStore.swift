import Foundation
import Synchronization

/// A trusted server key.
public struct KnownHost: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int
    public var keyType: String
    public var keyBase64: String
    public var fingerprint: String
    public var addedAt: Date

    public init(_ key: HostKeyInfo, addedAt: Date = Date()) {
        self.host = key.host
        self.port = key.port
        self.keyType = key.keyType
        self.keyBase64 = key.keyBase64
        self.fingerprint = key.fingerprint
        self.addedAt = addedAt
    }
}

public enum HostKeyStatus: Sendable, Equatable {
    /// The key matches the one we trusted for this host and port.
    case trusted
    /// Never seen this host (and port) before.
    case unknown
    /// We trusted a different key for this host: possible man in the middle,
    /// or the server was reinstalled.
    case changed(old: KnownHost)
}

/// Trust-on-first-use host keys: one key per host:port, kept in a JSON file
/// (or only in memory). Thread-safe.
public final class KnownHostsStore: Sendable {
    public let fileURL: URL?
    private let hosts: Mutex<[String: KnownHost]>

    /// Backed by `<directory>/known_hosts.json` (directory created on first save).
    public convenience init(directory: URL) {
        self.init(fileURL: directory.appendingPathComponent("known_hosts.json"))
    }

    /// Backed by `fileURL`; nil keeps everything in memory.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        var loaded: [String: KnownHost] = [:]
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let list = try? decoder.decode([KnownHost].self, from: data) {
                for h in list { loaded[Self.key(h.host, h.port)] = h }
            }
        }
        hosts = Mutex(loaded)
    }

    public static func inMemory() -> KnownHostsStore {
        KnownHostsStore(fileURL: nil)
    }

    static func key(_ host: String, _ port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    public func status(of key: HostKeyInfo) -> HostKeyStatus {
        guard let known = hosts.withLock({ $0[Self.key(key.host, key.port)] }) else { return .unknown }
        if known.keyType == key.keyType && known.keyBase64 == key.keyBase64 { return .trusted }
        return .changed(old: known)
    }

    public func knownHost(host: String, port: Int = 22) -> KnownHost? {
        hosts.withLock { $0[Self.key(host, port)] }
    }

    /// All trusted hosts, sorted by host then port.
    public var all: [KnownHost] {
        hosts.withLock { Array($0.values) }.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    /// Trusts `key` for its host and port, replacing any older key.
    public func trust(_ key: HostKeyInfo) throws {
        let snapshot = hosts.withLock { h -> [KnownHost] in
            h[Self.key(key.host, key.port)] = KnownHost(key)
            return Array(h.values)
        }
        try save(snapshot)
    }

    public func remove(host: String, port: Int = 22) throws {
        let snapshot = hosts.withLock { h -> [KnownHost] in
            h.removeValue(forKey: Self.key(host, port))
            return Array(h.values)
        }
        try save(snapshot)
    }

    private func save(_ list: [KnownHost]) throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(list.sorted { ($0.host, $0.port) < ($1.host, $1.port) })
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// Trust on first use: accepts keys the store trusts; for an unknown or changed
/// key asks `confirm` (the app shows an alert with the fingerprint) and, if it
/// says yes, remembers the key.
public struct TOFUHostKeyValidator: HostKeyValidator {
    public enum Prompt: Sendable, Equatable {
        /// First connection to this host.
        case unknown
        /// The host's key differs from the trusted one. Warn loudly.
        case changed(old: KnownHost)
    }

    public let store: KnownHostsStore
    private let confirm: @Sendable (HostKeyInfo, Prompt) async -> Bool

    /// `confirm` runs off the main actor; hop to it for UI
    /// (`await MainActor.run { ... }` or a `@MainActor` function).
    public init(store: KnownHostsStore, confirm: @escaping @Sendable (HostKeyInfo, Prompt) async -> Bool) {
        self.store = store
        self.confirm = confirm
    }

    public func validate(_ key: HostKeyInfo) async -> HostKeyDecision {
        let prompt: Prompt
        switch store.status(of: key) {
        case .trusted: return .accept
        case .unknown: prompt = .unknown
        case .changed(let old): prompt = .changed(old: old)
        }
        guard await confirm(key, prompt) else { return .reject }
        try? store.trust(key)
        return .accept
    }
}
