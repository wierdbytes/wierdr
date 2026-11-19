import Foundation

/// How the pusher's pushes reach APNs: straight, signed with the team's key on this
/// Mac (`APNsClient`, our own builds), or through Wierdr's relay, which signs them
/// (`RelayClient`: what an App Store copy needs, as only our key reaches it). The
/// relay wants grants: a device's (the app got it with App Attest and put it in its
/// `wierdr-push` entry) for a start and for a new channel, a channel's for broadcasts.
public protocol PushTransport: Sendable {
    /// Grants are needed: a device without one can't be started.
    var needsGrants: Bool { get }
    func start(token: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data, priority: Int) async throws
    func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                   priority: Int) async throws
    /// A new channel (and its grant, through the relay), made on behalf of a device of the lane.
    func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?) async throws
        -> (id: String, grant: String?)
    func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws
}

extension APNsClient: PushTransport {
    public var needsGrants: Bool { false }

    public func start(token: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                      priority: Int) async throws {
        try await start(token: token, bundle: bundle, env: env, payload: payload, priority: priority)
    }

    public func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                          priority: Int) async throws {
        try await broadcast(channel: channel, bundle: bundle, env: env, payload: payload, priority: priority)
    }

    public func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?) async throws
        -> (id: String, grant: String?) {
        (try await createChannel(bundle: bundle, env: env), nil)
    }

    public func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws {
        try await deleteChannel(channel, bundle: bundle, env: env)
    }
}

/// The relay refused a grant (`bad_grant`: not ours, another secret; `grant_expired`).
public struct RelayRefusal: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var code: String
    public var message: String

    public var description: String { "relay \(status) \(code)\(message == code ? "" : ": \(message)")" }
    public var isBadGrant: Bool { code == "bad_grant" || code == "grant_expired" }
}

/// Pushes through Wierdr's relay (`Relay/`, docs/relay.md): the same four calls as
/// `APNsClient`, as JSON to `<base>/v1/…`. APNs' own refusals come back as `APNsError`
/// (so a bad token or channel reads as it does straight), the relay's as `RelayRefusal`;
/// a refused channel grant reads as a bad channel (the next activity gets a new one).
public final class RelayClient: PushTransport {
    public let base: URL
    let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public var needsGrants: Bool { true }

    public func start(token: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                      priority: Int) async throws {
        _ = try await post("v1/start", ["env": env.rawValue, "token": token, "grant": grant ?? "",
                                        "payload": String(decoding: payload, as: UTF8.self), "priority": priority])
    }

    public func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                          priority: Int) async throws {
        do {
            _ = try await post("v1/broadcast", ["env": env.rawValue, "channel": channel, "grant": grant ?? "",
                                                "payload": String(decoding: payload, as: UTF8.self), "priority": priority])
        } catch let r as RelayRefusal where r.isBadGrant {
            throw APNsError(status: 404, reason: "BadChannelGrant")
        }
    }

    public func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?) async throws
        -> (id: String, grant: String?) {
        guard let device else { throw RelayRefusal(status: 0, code: "no_device_grant", message: "no device of the lane has a relay grant") }
        let r = try await post("v1/channels", ["env": env.rawValue, "token": device.token, "grant": device.grant])
        guard let id = r["channel"] as? String, let grant = r["grant"] as? String else {
            throw RelayRefusal(status: 200, code: "bad_reply", message: "no channel")
        }
        return (id, grant)
    }

    public func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws {
        _ = try await post("v1/channels/delete", ["env": env.rawValue, "channel": channel, "grant": grant ?? ""])
    }

    /// The request a call makes (tests read it).
    func request(_ path: String, _ body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: try request(path, body))
        guard let http = response as? HTTPURLResponse else { throw RelayRefusal(status: 0, code: "no_response", message: "") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(http.statusCode) { return json }
        throw Self.error(status: http.statusCode, json: json, data: data)
    }

    static func error(status: Int, json: [String: Any], data: Data) -> Error {
        if json["error"] as? String == "apns" {
            return APNsError(status: json["status"] as? Int ?? 0, reason: json["reason"] as? String ?? "")
        }
        let code = json["error"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self)
        return RelayRefusal(status: status, code: code, message: json["message"] as? String ?? code)
    }
}
