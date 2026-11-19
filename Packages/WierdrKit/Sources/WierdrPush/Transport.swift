import Foundation

/// How the pusher's pushes reach APNs: straight, signed with the team's key on this
/// Mac (`APNsClient`, our own builds), or through Wierdr's relay, which signs them
/// (`RelayClient`: what an App Store copy needs, as only our key reaches it). The
/// relay wants grants: a device's (the app got it with App Attest and put it in its
/// `wierdr-push` entry) for a start and for a new channel, a channel's for broadcasts
/// and for a start on it. It renews them on use: a call may come back with a fresh
/// grant (`renewed`), which the pusher keeps instead of the old one.
public protocol PushTransport: Sendable {
    /// Grants are needed: a device without one can't be started.
    var needsGrants: Bool { get }
    /// Push-to-start on `token`, subscribed to `channel` (the payload's `input-push-channel`);
    /// through the relay with the device's grant and the channel's. Returns the device's grant
    /// renewed, when the relay renewed it.
    @discardableResult
    func start(token: String, grant: String?, channel: String, channelGrant: String?, bundle: String,
               env: APNsEnvironment, payload: Data, priority: Int) async throws -> String?
    /// An update or end on a channel. Returns the channel's grant renewed, when the relay renewed it.
    @discardableResult
    func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                   priority: Int) async throws -> String?
    /// A new channel (and its grant, through the relay), made on behalf of a device of the lane;
    /// `renewed`: that device's grant renewed, when the relay renewed it.
    func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?) async throws
        -> (id: String, grant: String?, renewed: String?)
    func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws
}

extension APNsClient: PushTransport {
    public var needsGrants: Bool { false }

    @discardableResult
    public func start(token: String, grant: String?, channel: String, channelGrant: String?, bundle: String,
                      env: APNsEnvironment, payload: Data, priority: Int) async throws -> String? {
        try await start(token: token, bundle: bundle, env: env, payload: payload, priority: priority)
        return nil
    }

    @discardableResult
    public func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                          priority: Int) async throws -> String? {
        try await broadcast(channel: channel, bundle: bundle, env: env, payload: payload, priority: priority)
        return nil
    }

    public func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?) async throws
        -> (id: String, grant: String?, renewed: String?) {
        (try await createChannel(bundle: bundle, env: env), nil, nil)
    }

    public func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws {
        try await deleteChannel(channel, bundle: bundle, env: env)
    }
}

/// Whose grant the relay refused (`"grant"` in its reply): a start carries two.
public enum RelayGrantKind: String, Sendable {
    case device, channel
}

/// The relay said no (`{"error": code, "message", "grant"}`), for a reason of its own rather
/// than APNs'; `bad_reply` when its answer wasn't its JSON (a Cloudflare error page, a proxy).
public struct RelayRefusal: Error, CustomStringConvertible, Sendable, Equatable {
    public var status: Int
    public var code: String
    public var message: String
    /// For a grant refused: whose (nil when the relay didn't say).
    public var grant: RelayGrantKind?

    public init(status: Int, code: String, message: String, grant: RelayGrantKind? = nil) {
        self.status = status; self.code = code; self.message = message; self.grant = grant
    }

    public var description: String {
        let whose = grant.map { " (the \($0.rawValue)'s grant)" } ?? ""
        return "relay \(status) \(code)\(message == code || message.isEmpty ? "" : ": \(message)")\(whose)"
    }

    /// A grant refused: not ours (another secret), run out, or its App Attest key revoked or
    /// unknown to the relay. A device's waits for the app to bring a new one; a channel's ends
    /// its channel.
    public var isBadGrant: Bool { ["bad_grant", "grant_expired", "key_revoked", "key_unknown"].contains(code) }
    /// No new channel for now: the key's daily quota, its live channels, or the app's
    /// ceiling. Worth asking again later, not at once.
    public var isChannelLimit: Bool { ["channel_quota", "channel_limit", "channels_full"].contains(code) }
    /// A refusal asking again won't change: a request the relay won't take (400, 413) or a
    /// forbidden one (403) that isn't about a grant. Not a reason to pause every push.
    public var isPermanent: Bool { !isBadGrant && [400, 403, 413].contains(status) }
}

/// Pushes through Wierdr's relay (`Relay/`, docs/relay.md): the same four calls as
/// `APNsClient`, as JSON to `<base>/v1/…`, each naming the app (`bundle`, which the relay
/// checks against its own). APNs' own refusals come back as `APNsError` (so a bad token or
/// channel reads as it does straight), the relay's as `RelayRefusal`; a refused channel
/// grant on a broadcast reads as a bad channel (the next activity gets a new one).
public final class RelayClient: PushTransport {
    public let base: URL
    let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public var needsGrants: Bool { true }

    @discardableResult
    public func start(token: String, grant: String?, channel: String, channelGrant: String?, bundle: String,
                      env: APNsEnvironment, payload: Data, priority: Int) async throws -> String? {
        let r = try await post("v1/start", ["bundle": bundle, "env": env.rawValue, "token": token, "grant": grant ?? "",
                                            "channel": channel, "channel_grant": channelGrant ?? "",
                                            "payload": String(decoding: payload, as: UTF8.self), "priority": priority])
        return Self.renewed(r)
    }

    @discardableResult
    public func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                          priority: Int) async throws -> String? {
        do {
            let r = try await post("v1/broadcast", ["bundle": bundle, "env": env.rawValue, "channel": channel,
                                                    "grant": grant ?? "",
                                                    "payload": String(decoding: payload, as: UTF8.self), "priority": priority])
            return Self.renewed(r)
        } catch let r as RelayRefusal where r.isBadGrant {
            throw APNsError(status: 404, reason: "BadChannelGrant")
        }
    }

    public func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?) async throws
        -> (id: String, grant: String?, renewed: String?) {
        guard let device else { throw RelayRefusal(status: 0, code: "no_device_grant", message: "no device of the lane has a relay grant") }
        let r = try await post("v1/channels", ["bundle": bundle, "env": env.rawValue, "token": device.token,
                                               "grant": device.grant])
        guard let id = r["channel"] as? String, !id.isEmpty, let grant = r["grant"] as? String, !grant.isEmpty else {
            throw RelayRefusal(status: 200, code: "bad_reply", message: "no channel")
        }
        return (id, grant, Self.renewed(r))
    }

    public func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws {
        _ = try await post("v1/channels/delete", ["bundle": bundle, "env": env.rawValue, "channel": channel,
                                                  "grant": grant ?? ""])
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

    /// The reply's JSON object; anything else (an HTML error page, a proxy's answer) is `bad_reply`.
    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: try request(path, body))
        guard let http = response as? HTTPURLResponse else { throw RelayRefusal(status: 0, code: "no_response", message: "") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(http.statusCode) {
            guard let json else { throw Self.badReply(status: http.statusCode, data: data) }
            return json
        }
        throw Self.error(status: http.statusCode, json: json ?? [:], data: data)
    }

    static func error(status: Int, json: [String: Any], data: Data) -> Error {
        if json["error"] as? String == "apns" {
            return APNsError(status: json["status"] as? Int ?? 0, reason: json["reason"] as? String ?? "")
        }
        guard let code = json["error"] as? String, !code.isEmpty else { return badReply(status: status, data: data) }
        return RelayRefusal(status: status, code: code, message: json["message"] as? String ?? code,
                            grant: (json["grant"] as? String).flatMap(RelayGrantKind.init(rawValue:)))
    }

    /// Not the relay's JSON: the start of what came, on one line, for the log.
    static func badReply(status: Int, data: Data) -> RelayRefusal {
        let text = String(decoding: data.prefix(200), as: UTF8.self)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return RelayRefusal(status: status, code: "bad_reply", message: text)
    }

    /// A renewed grant in a reply, if any.
    static func renewed(_ json: [String: Any]) -> String? {
        (json["renewed"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
