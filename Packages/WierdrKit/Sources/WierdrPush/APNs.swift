import Foundation
import Crypto

/// APNs environment: where an app's tokens and channels live (a development-signed
/// app gets sandbox tokens).
public enum APNsEnvironment: String, Codable, Hashable, Sendable {
    case development, production

    var pushHost: String { self == .development ? "api.sandbox.push.apple.com" : "api.push.apple.com" }
    var manageURL: String {
        self == .development ? "https://api-manage-broadcast.sandbox.push.apple.com:2195"
                             : "https://api-manage-broadcast.push.apple.com:2196"
    }
}

/// Token-based APNs authentication: the team's `.p8` key signs a JWT (ES256)
/// that is reused for 50 minutes (APNs wants it renewed within an hour, and not
/// more often than every 20 minutes).
public final class APNsSigner: @unchecked Sendable {
    public let keyID: String
    public let teamID: String
    private let key: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var cached: (token: String, at: Date)?

    public init(p8 pem: String, keyID: String, teamID: String) throws {
        self.key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        self.keyID = keyID
        self.teamID = teamID
    }

    public func token(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < 50 * 60 { return cached.token }
        let header = Self.base64URL(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = Self.base64URL(Data(#"{"iss":"\#(teamID)","iat":\#(Int(now.timeIntervalSince1970))}"#.utf8))
        let input = "\(header).\(claims)"
        let signature = (try? key.signature(for: Data(input.utf8)))?.rawRepresentation ?? Data()
        let token = "\(input).\(Self.base64URL(signature))"
        cached = (token, now)
        return token
    }

    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// An APNs rejection: HTTP status and `reason` (`BadDeviceToken`, `InvalidProviderToken` …).
public struct APNsError: Error, CustomStringConvertible, Sendable {
    public var status: Int
    public var reason: String

    public var description: String { "APNs \(status) \(reason)" }

    /// The device token is no good (app deleted, token rotated, wrong environment).
    public var isBadToken: Bool {
        status == 410 || ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].contains(reason)
    }
    /// The channel is gone (deleted, other environment).
    public var isBadChannel: Bool {
        ["BadChannelId", "ChannelNotRegistered", "InvalidChannelId", "BadPath"].contains(reason) || status == 404
    }
}

/// Sends Live Activity pushes: push-to-start to a device token, updates and ends
/// broadcast on a channel, and channel creation. HTTP/2 through `URLSession`.
public final class APNsClient: Sendable {
    let signer: APNsSigner
    let session: URLSession

    public init(signer: APNsSigner, session: URLSession = .shared) {
        self.signer = signer
        self.session = session
    }

    /// How long APNs keeps a start for a phone that's off line. Without `apns-expiration` it
    /// keeps it by its own policy, and a phone back hours later would start an activity
    /// with a stale state on a channel long ended; the pusher starts it again instead.
    static let startLifetime: TimeInterval = 600

    /// Starts a Live Activity on a device (`event: start` payload with `input-push-channel`).
    public func start(token: String, bundle: String, env: APNsEnvironment, payload: Data, priority: Int = 10) async throws {
        _ = try await send(startRequest(token: token, bundle: bundle, env: env, payload: payload, priority: priority,
                                        now: Date()))
    }

    /// The request `start` sends (tests read it).
    func startRequest(token: String, bundle: String, env: APNsEnvironment, payload: Data, priority: Int,
                      now: Date) -> URLRequest {
        var r = request("https://\(env.pushHost)/3/device/\(token)")
        r.setValue("\(bundle).push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        r.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        r.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        r.setValue(String(Int(now.timeIntervalSince1970 + Self.startLifetime)), forHTTPHeaderField: "apns-expiration")
        r.httpBody = payload
        return r
    }

    /// Sends an update or end on a channel. The channel stores nothing: a device
    /// that's offline gets the next one (`apns-expiration: 0`, which such a channel requires).
    public func broadcast(channel: String, bundle: String, env: APNsEnvironment, payload: Data,
                          priority: Int) async throws {
        var r = request("https://\(env.pushHost)/4/broadcasts/apps/\(bundle)")
        r.setValue(channel, forHTTPHeaderField: "apns-channel-id")
        r.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        r.setValue(String(priority), forHTTPHeaderField: "apns-priority")
        r.setValue("0", forHTTPHeaderField: "apns-expiration")
        r.httpBody = payload
        _ = try await send(r)
    }

    /// A new channel for Live Activity broadcasts. It stores no messages: a channel
    /// that keeps the most recent one has a much smaller publishing budget (APNs
    /// answered 429 TooManyRequests after ~20 updates in 13 minutes).
    public func createChannel(bundle: String, env: APNsEnvironment) async throws -> String {
        var r = request("\(env.manageURL)/1/apps/\(bundle)/channels")
        r.httpBody = Data(#"{"message-storage-policy":0,"push-type":"LiveActivity"}"#.utf8)
        let response = try await send(r)
        guard let id = response.value(forHTTPHeaderField: "apns-channel-id"), !id.isEmpty else {
            throw APNsError(status: response.statusCode, reason: "NoChannelId")
        }
        return id
    }

    /// Deletes a channel (best effort).
    public func deleteChannel(_ channel: String, bundle: String, env: APNsEnvironment) async throws {
        var r = request("\(env.manageURL)/1/apps/\(bundle)/channels")
        r.httpMethod = "DELETE"
        r.setValue(channel, forHTTPHeaderField: "apns-channel-id")
        _ = try await send(r)
    }

    private func request(_ url: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("bearer \(signer.token())", forHTTPHeaderField: "authorization")
        return r
    }

    private func send(_ r: URLRequest) async throws -> HTTPURLResponse {
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw APNsError(status: 0, reason: "NoResponse") }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            throw APNsError(status: http.statusCode, reason: reason ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return http
    }
}
