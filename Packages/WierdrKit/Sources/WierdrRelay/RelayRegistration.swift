import CryptoKit
import Foundation

/// This iPhone's grant on Wierdr's push relay (`Relay/`, docs/relay.md): the right for
/// the Mac's `wierdrd` to start the agents Live Activity on its push-to-start token
/// through the relay. The relay hands it only to a genuine copy of Wierdr: App Attest
/// makes a key in the Secure Enclave, Apple attests it once (the relay keeps its public
/// key), and each registration is an assertion signed with it over the request.
///
/// The grant lasts 30 days. When Wierdr connects it asks the relay whether the grant
/// still holds (a new relay secret, a revoked key void it) and renews it when the relay
/// says so or within 10 days of its end; a new token gets one at once.
///
/// What goes wrong is bounded: two rounds at most per call; a key Apple or the relay
/// refused, or the relay revoked, isn't replaced for a day (Apple limits attestations, and
/// many of them read as fraud); a key the Secure Enclave lost (`invalidKey`) or the relay
/// doesn't know (`key_unknown`) is replaced at once. An attestation Apple made is kept
/// until the relay took it (sent again later, with its challenge, if the relay couldn't be
/// reached); while Apple's service is down the key and its challenge are kept and asked again.
@MainActor
public final class RelayRegistration {
    public enum Failure: Error, Equatable {
        case unsupported
        case refused(status: Int, code: String)
        /// A refused attestation a moment ago: not again for a day.
        case resting
        case gaveUp
    }

    let attest: AppAttesting
    let http: RelayHTTP
    let store: RegistrationStore
    let now: () -> Date
    public var log: (String) -> Void = { print("[relay] \($0)") }
    private var running: [String: Task<String?, Never>] = [:]

    public init(attest: AppAttesting, http: RelayHTTP, store: RegistrationStore, now: @escaping () -> Date = Date.init) {
        self.attest = attest
        self.http = http
        self.store = store
        self.now = now
    }

    /// The grant kept for `token`, while it's good (for `within` seconds more).
    public func kept(token: String, env: String, within: TimeInterval = 0) -> String? {
        guard let g = store.grant, g.token == token, g.env == env,
              g.expires > now().timeIntervalSince1970 + within else { return nil }
        return g.grant
    }

    /// A grant for `token`: the kept one while it holds (`check`: asking the relay; else
    /// while it's good for 10 more days), else a new one (the kept one if that fails).
    /// Nil without App Attest (the simulator) or when the relay can't be had.
    public func grant(token: String, env: String, check: Bool) async -> String? {
        let key = "\(env)/\(token)"
        if let task = running[key] { return await task.value }
        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            return await self.resolve(token: token, env: env, check: check)
        }
        running[key] = task
        defer { running[key] = nil }
        return await task.value
    }

    private func resolve(token: String, env: String, check: Bool) async -> String? {
        if let g = kept(token: token, env: env) {
            if !check {
                if kept(token: token, env: env, within: 10 * 86400) != nil { return g }
            } else {
                switch await verdict(on: g, token: token, env: env) {
                case .holds: return g
                case .renew, .unknown: break
                case .void: store.grant = nil
                }
            }
        }
        do {
            let g = try await register(token: token, env: env)
            store.grant = g
            return g.grant
        } catch {
            log("registration: \(error)")
            return kept(token: token, env: env)
        }
    }

    enum Verdict { case holds, renew, void, unknown }

    /// What the relay says of a kept grant.
    private func verdict(on grant: String, token: String, env: String) async -> Verdict {
        let body = (try? JSONSerialization.data(withJSONObject: ["env": env, "token": token, "grant": grant])) ?? Data()
        guard let r = try? await http.post("v1/grants/check", body: body, headers: [:]) else { return .unknown }
        if r.status == 200 { return r.json["renew"] as? Bool == true ? .renew : .holds }
        let code = r.json["error"] as? String ?? ""
        switch code {
        case "key_revoked":
            dropKey()
            store.attestRefusedAt = now() // as on registering: not a new key for a day
        case "key_unknown":
            dropKey()
        default:
            break
        }
        return ["bad_grant", "grant_expired", "key_revoked", "key_unknown"].contains(code) ? .void : .unknown
    }

    // MARK: Registering

    private func register(token: String, env: String) async throws -> RegistrationStore.Grant {
        guard attest.isSupported else { throw Failure.unsupported }
        for _ in 0..<2 {
            let key = try await attestedKey()
            let challenge = try await self.challenge()
            // `op`: what the assertion is for, signed with it.
            let body = try JSONSerialization.data(withJSONObject: ["challenge": challenge, "key_id": key, "token": token,
                                                                   "env": env, "op": "devices"], options: [.sortedKeys])
            let assertion: Data
            do {
                assertion = try await attest.generateAssertion(key, clientDataHash: Data(SHA256.hash(data: body)))
            } catch AppAttestFailure.invalidKey {
                dropKey() // the Secure Enclave lost it (a restored backup, another device): a new one
                continue
            }
            let r = try await http.post("v1/devices", body: body, headers: ["x-wierdr-assertion": assertion.base64EncodedString()])
            if r.status == 200, let grant = r.json["grant"] as? String, let expires = r.json["expires"] as? Double {
                return .init(token: token, env: env, grant: grant, expires: expires)
            }
            let code = r.json["error"] as? String ?? "status \(r.status)"
            switch code {
            case "key_unknown":
                dropKey() // the relay forgot it (its database was reset): a new key, attested
                continue
            case "key_revoked":
                dropKey()
                store.attestRefusedAt = now()
                throw Failure.refused(status: r.status, code: code)
            default:
                throw Failure.refused(status: r.status, code: code)
            }
        }
        throw Failure.gaveUp
    }

    /// The App Attest key, attested with the relay (once per install).
    private func attestedKey() async throws -> String {
        if let key = store.keyId, store.attested { return key }
        if let at = store.attestRefusedAt, now().timeIntervalSince(at) < 86400 { throw Failure.resting }
        let key: String
        if let k = store.keyId {
            key = k
        } else {
            key = try await attest.generateKey()
            store.keyId = key
            store.attested = false
            store.pending = nil
        }
        // A challenge kept for this key (Apple was down) or attested already (the relay was
        // out of reach) is used again within a day; else a new one.
        var pending = store.pending.flatMap { $0.key == key && now().timeIntervalSince($0.at) < 23 * 3600 ? $0 : nil }
        if pending == nil {
            pending = PendingAttestation(key: key, challenge: try await self.challenge(), attestation: nil, at: now())
            store.pending = pending
        }
        var p = pending!
        if p.attestation == nil {
            do {
                p.attestation = try await attest.attestKey(key, clientDataHash: Data(SHA256.hash(data: Data(p.challenge.utf8))))
                store.pending = p
            } catch AppAttestFailure.serverUnavailable {
                throw AppAttestFailure.serverUnavailable // Apple's service is down: the key and challenge stay, later
            } catch {
                // Apple: a key whose attestation failed otherwise is no good; the next call makes another.
                dropKey()
                throw error
            }
        }
        let body = try JSONSerialization.data(withJSONObject: ["challenge": p.challenge, "key_id": key,
                                                               "attestation": p.attestation!.base64EncodedString()])
        let r: (status: Int, json: [String: Any])
        r = try await http.post("v1/attest", body: body, headers: [:]) // no reply: the attestation stays for next time
        guard r.status == 200 else {
            let code = r.json["error"] as? String ?? "status \(r.status)"
            if r.status == 403 || r.status == 409 {
                dropKey()
                store.attestRefusedAt = now()
            } else if code == "bad_challenge" {
                dropKey() // kept too long: a new key (attesting one key twice isn't Apple's way)
            }
            throw Failure.refused(status: r.status, code: code)
        }
        store.attested = true
        store.pending = nil
        store.attestRefusedAt = nil
        return key
    }

    private func dropKey() {
        store.keyId = nil
        store.attested = false
        store.pending = nil
    }

    private func challenge() async throws -> String {
        let r = try await http.post("v1/challenge", body: Data("{}".utf8), headers: [:])
        guard r.status == 200, let c = r.json["challenge"] as? String else {
            throw Failure.refused(status: r.status, code: r.json["error"] as? String ?? "no challenge")
        }
        return c
    }
}

// MARK: - What it runs on

/// App Attest (`DCAppAttestService` in the app), its errors as these.
public protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

public enum AppAttestFailure: Error, Equatable {
    /// The key is no good (`DCError.invalidKey`).
    case invalidKey
    /// Apple's App Attest service can't be reached now (`DCError.serverUnavailable`).
    case serverUnavailable
}

/// The relay's JSON over HTTPS: a status and the JSON reply (throws only when there's no reply).
public protocol RelayHTTP: Sendable {
    func post(_ path: String, body: Data, headers: [String: String]) async throws -> (status: Int, json: [String: Any])
}

/// What registration keeps between launches (UserDefaults in the app).
@MainActor
public protocol RegistrationStore: AnyObject {
    typealias Grant = KeptGrant
    var grant: KeptGrant? { get set }
    var keyId: String? { get set }
    var attested: Bool { get set }
    var attestRefusedAt: Date? { get set }
    /// An attestation under way: its challenge, and what Apple attested once it did.
    var pending: PendingAttestation? { get set }
}

public struct PendingAttestation: Codable, Equatable, Sendable {
    public var key: String
    public var challenge: String
    public var attestation: Data?
    public var at: Date

    public init(key: String, challenge: String, attestation: Data?, at: Date) {
        self.key = key; self.challenge = challenge; self.attestation = attestation; self.at = at
    }
}

public struct KeptGrant: Codable, Equatable, Sendable {
    public var token: String
    public var env: String
    public var grant: String
    public var expires: Double

    public init(token: String, env: String, grant: String, expires: Double) {
        self.token = token; self.env = env; self.grant = grant; self.expires = expires
    }
}

/// `RelayHTTP` over URLSession.
public struct URLSessionRelayHTTP: RelayHTTP {
    public let base: URL
    public init(base: URL) { self.base = base }

    public func post(_ path: String, body: Data, headers: [String: String]) async throws -> (status: Int, json: [String: Any]) {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }
}

/// `RegistrationStore` in UserDefaults.
@MainActor
public final class DefaultsRegistrationStore: RegistrationStore {
    let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var grant: KeptGrant? {
        get { defaults.data(forKey: "relay.grant").flatMap { try? JSONDecoder().decode(KeptGrant.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "relay.grant") }
    }
    public var keyId: String? {
        get { defaults.string(forKey: "relay.appAttestKey") }
        set { defaults.set(newValue, forKey: "relay.appAttestKey") }
    }
    public var attested: Bool {
        get { defaults.bool(forKey: "relay.appAttestKeyAttested") }
        set { defaults.set(newValue, forKey: "relay.appAttestKeyAttested") }
    }
    public var attestRefusedAt: Date? {
        get { defaults.object(forKey: "relay.attestRefusedAt") as? Date }
        set { defaults.set(newValue, forKey: "relay.attestRefusedAt") }
    }
    public var pending: PendingAttestation? {
        get { defaults.data(forKey: "relay.pendingAttestation").flatMap { try? JSONDecoder().decode(PendingAttestation.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "relay.pendingAttestation") }
    }
}
