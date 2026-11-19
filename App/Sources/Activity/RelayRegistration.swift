import CryptoKit
import DeviceCheck
import Foundation

/// This iPhone's grant on Wierdr's push relay (`Relay/`, docs/relay.md): the right for
/// the Mac's `wierdr-push` to start the agents Live Activity on its push-to-start
/// token through the relay. The relay hands it only to a genuine copy of Wierdr:
/// App Attest makes a key in the Secure Enclave, Apple attests it once (the relay keeps
/// its public key), and each registration is an assertion signed with it. The grant
/// lasts 30 days; it's asked again 10 days before, or for a new token.
@MainActor
final class RelayRegistration {
    static let shared = RelayRegistration()

    /// `WierdrRelay` in Info.plist.
    let base: URL? = (Bundle.main.object(forInfoDictionaryKey: "WierdrRelay") as? String).flatMap(URL.init(string:))

    private let defaults = UserDefaults.standard
    private var running: Task<String?, Never>?

    private init() {}

    struct Grant: Codable {
        var token: String
        var env: String
        var grant: String
        var expires: Double
    }

    /// The grant kept for `token`, while it's good (for `within` seconds more).
    func kept(token: String, env: String, within: TimeInterval = 0) -> String? {
        guard let g = stored, g.token == token, g.env == env,
              g.expires > Date().timeIntervalSince1970 + within else { return nil }
        return g.grant
    }

    /// A grant for `token`: the kept one while it's good for 10 more days, else a new one
    /// from the relay (the kept one if that fails); nil when App Attest isn't there (the
    /// simulator) or the relay can't be reached.
    func grant(token: String, env: String) async -> String? {
        if let g = kept(token: token, env: env, within: 10 * 86400) { return g }
        if let running { return await running.value }
        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            do {
                let g = try await self.register(token: token, env: env)
                self.stored = g
                return g.grant
            } catch {
                print("[relay] registration: \(error)")
                return self.kept(token: token, env: env)
            }
        }
        running = task
        defer { running = nil }
        return await task.value
    }

    private var stored: Grant? {
        get { defaults.data(forKey: "relay.grant").flatMap { try? JSONDecoder().decode(Grant.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "relay.grant") }
    }

    // MARK: App Attest

    enum Failure: Error { case noRelay, unsupported, refused(Int, String) }

    private var keyId: String? {
        get { defaults.string(forKey: "relay.appAttestKey") }
        set { defaults.set(newValue, forKey: "relay.appAttestKey") }
    }

    private var attested: Bool {
        get { defaults.bool(forKey: "relay.appAttestKeyAttested") }
        set { defaults.set(newValue, forKey: "relay.appAttestKeyAttested") }
    }

    private func register(token: String, env: String) async throws -> Grant {
        guard base != nil else { throw Failure.noRelay }
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw Failure.unsupported }
        for attempt in 0..<2 {
            let key = try await attestedKey(service, fresh: attempt > 0)
            let challenge = try await challenge()
            let body = try JSONSerialization.data(withJSONObject: ["challenge": challenge, "key_id": key, "token": token,
                                                                   "env": env], options: [.sortedKeys])
            let assertion: Data
            do {
                assertion = try await service.generateAssertion(key, clientDataHash: Data(SHA256.hash(data: body)))
            } catch let e as DCError where e.code == .invalidKey {
                continue // a key the Secure Enclave lost (restored backup): a new one
            }
            do {
                let r = try await post("v1/devices", body: body, headers: ["x-wierdr-assertion": assertion.base64EncodedString()])
                guard let grant = r["grant"] as? String, let expires = r["expires"] as? Double else {
                    throw Failure.refused(200, "no grant")
                }
                return Grant(token: token, env: env, grant: grant, expires: expires)
            } catch Failure.refused(401, _) {
                attested = false // the relay doesn't know the key (its database was reset): attest it again
                continue
            }
        }
        throw Failure.refused(0, "gave up")
    }

    /// The App Attest key, attested with the relay (once per install).
    private func attestedKey(_ service: DCAppAttestService, fresh: Bool) async throws -> String {
        if fresh || keyId == nil {
            keyId = try await service.generateKey()
            attested = false
        }
        let key = keyId!
        guard !attested else { return key }
        let challenge = try await challenge()
        let attestation: Data
        do {
            attestation = try await service.attestKey(key, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        } catch let e as DCError where e.code == .invalidKey {
            keyId = try await service.generateKey()
            return try await attestedKey(service, fresh: false)
        }
        _ = try await post("v1/attest", json: ["challenge": challenge, "key_id": key,
                                               "attestation": attestation.base64EncodedString()])
        attested = true
        return key
    }

    private func challenge() async throws -> String {
        guard let c = try await post("v1/challenge", json: [:])["challenge"] as? String else { throw Failure.refused(200, "no challenge") }
        return c
    }

    // MARK: HTTP

    private func post(_ path: String, json: [String: Any]) async throws -> [String: Any] {
        try await post(path, body: JSONSerialization.data(withJSONObject: json), headers: [:])
    }

    private func post(_ path: String, body: Data, headers: [String: String]) async throws -> [String: Any] {
        guard let base else { throw Failure.noRelay }
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.refused(status, "\(json["error"] ?? "") \(json["message"] ?? "")")
        }
        return json
    }
}
