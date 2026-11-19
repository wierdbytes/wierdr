import Crypto
import Foundation
import Testing
@testable import WierdrPush
import WierdrActivity

// The pusher through the relay: refusals that hold back a lane rather than every push,
// channels deleted until done, grants kept tidy, starts with their channel's grant.

private let lane = Lane(bundle: "pw.xff.wierdr", env: .development)
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86400

/// A grant as the relay makes them (`g2.<expiry>.<owner>.<mac>`).
private func grant(_ tag: String, expires: Date) -> String {
    "g2.\(Int(expires.timeIntervalSince1970)).owner.\(tag)"
}

private func device(_ token: String, grant: String?) -> PushRegistry.Device {
    PushRegistry.Device(name: "iPhone \(token)", bundle: lane.bundle, env: lane.env.rawValue, startToken: token,
                        updated: 1, hasActivity: true, relayGrant: grant)
}

/// A transport that says what the test tells it to and keeps what it was asked.
private final class ScriptedTransport: PushTransport, @unchecked Sendable {
    enum Call: Equatable {
        case start(token: String, grant: String?, channel: String, channelGrant: String?)
        case broadcast(channel: String, grant: String?, event: String)
        case create(grant: String?)
        case delete(channel: String, grant: String?)
    }

    let needsGrants: Bool
    var calls: [Call] = []
    var made = 0
    var onStart: () throws -> Void = {}
    var onCreate: (_ grant: String?) throws -> Void = { _ in }
    var onDelete: (_ channel: String) throws -> Void = { _ in }

    init(relay: Bool = true) { needsGrants = relay }

    func start(token: String, grant: String?, channel: String, channelGrant: String?, bundle: String,
               env: APNsEnvironment, payload: Data, priority: Int) async throws {
        calls.append(.start(token: token, grant: grant, channel: channel, channelGrant: channelGrant))
        try onStart()
    }

    func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                   priority: Int) async throws {
        let aps = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["aps"] as? [String: Any]
        calls.append(.broadcast(channel: channel, grant: grant, event: aps?["event"] as? String ?? "?"))
    }

    func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?) async throws
        -> (id: String, grant: String?) {
        calls.append(.create(grant: device?.grant))
        try onCreate(device?.grant)
        made += 1
        return ("NEW\(made)==", needsGrants ? grant("new\(made)", expires: now.addingTimeInterval(30 * day)) : nil)
    }

    func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws {
        calls.append(.delete(channel: channel, grant: grant))
        try onDelete(channel)
    }

    var creates: Int { calls.filter { if case .create = $0 { true } else { false } }.count }
    var deletes: [String] { calls.compactMap { if case let .delete(c, _) = $0 { c } else { nil } } }
    var events: [String] { calls.compactMap { if case let .broadcast(_, _, e) = $0 { e } else { nil } } }
}

private final class Lines { var all: [String] = [] }

@MainActor
private func pusher(_ t: ScriptedTransport, url: URL? = nil) -> (Pusher, Lines) {
    let url = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("push-state-\(UUID().uuidString).json")
    let p = Pusher(transport: t, host: "mac", seal: .generate(), stateURL: url)
    let lines = Lines()
    p.log = { lines.all.append($0) }
    return (p, lines)
}

@MainActor
private func running(_ channel: String, devices: [String: String] = ["d": "aa"]) -> Planner.Running {
    Planner.Running(lane: lane, channel: channel, startedAt: now.timeIntervalSince1970 - 60, devices: devices,
                    last: .init(working: 1), lastSentAt: now.timeIntervalSince1970 - 1)
}

@MainActor @Suite struct PusherRelayTests {
    // MARK: Making channels

    @Test func aRefusedDeviceGrantWaitsForANewOneAndPausesNothing() async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        let longer = grant("a", expires: now.addingTimeInterval(20 * day))
        let shorter = grant("b", expires: now.addingTimeInterval(10 * day))
        t.onCreate = { if $0 == longer { throw RelayRefusal(status: 403, code: "bad_grant", message: "bad_grant") } }
        p.devices = ["a": device("aa", grant: longer), "b": device("bb", grant: shorter)]

        await p.tick(now: now)
        #expect(t.calls == [.create(grant: longer)], "the grant that lasts longest goes first")
        #expect(p.state.badGrants == [longer])
        #expect(p.pausedUntil == .distantPast)
        #expect(p.laneRetryAt.isEmpty)

        await p.tick(now: now.addingTimeInterval(1))
        #expect(t.calls.last == .create(grant: shorter), "the next tick, another device of the lane")
        #expect(p.state.channels[lane.key] == "NEW1==")
        #expect(p.state.channelGrants["NEW1=="] != nil)
    }

    @Test(arguments: [("channel_quota", 429), ("channel_limit", 429), ("channels_full", 503)])
    func theRelaysChannelLimitsHoldBackOnlyTheirLane(code: String, status: Int) async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        var limited = true
        t.onCreate = { _ in if limited { throw RelayRefusal(status: status, code: code, message: code) } }
        let g = grant("a", expires: now.addingTimeInterval(20 * day))
        p.devices = ["d": device("aa", grant: g)]
        p.planner.running[lane.key] = running("RUN==")
        p.state.channelGrants["RUN=="] = grant("run", expires: now.addingTimeInterval(20 * day))

        await p.tick(now: now)
        let retry = try! #require(p.laneRetryAt[lane.key])
        #expect(retry >= now.addingTimeInterval(300) && retry <= now.addingTimeInterval(900))
        #expect(p.state.badGrants.isEmpty)
        #expect(p.pausedUntil == .distantPast)
        #expect(t.events == ["update"], "the running activity's update went out all the same")

        // A minute on: no new channel asked for, but the lane's pushes go on.
        p.planner.resend(lane: lane)
        await p.tick(now: now.addingTimeInterval(60))
        #expect(t.creates == 1)
        #expect(t.events == ["update", "update"])

        limited = false
        await p.tick(now: now.addingTimeInterval(901))
        #expect(t.creates == 2)
        #expect(p.state.channels[lane.key] == "NEW1==")
        #expect(p.laneRetryAt[lane.key] == nil)
    }

    @Test func anyOtherFailureWaitsAMinute() async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        t.onCreate = { _ in throw URLError(.timedOut) }
        p.devices = ["d": device("aa", grant: grant("a", expires: now.addingTimeInterval(20 * day)))]
        await p.tick(now: now)
        #expect(p.laneRetryAt[lane.key] == now.addingTimeInterval(60))
        await p.tick(now: now.addingTimeInterval(30))
        #expect(t.creates == 1)
        await p.tick(now: now.addingTimeInterval(61))
        #expect(t.creates == 2)
    }

    @Test func refusalsReadAsWhatTheyMean() {
        for code in ["bad_grant", "grant_expired", "key_revoked"] {
            #expect(RelayRefusal(status: 403, code: code, message: code).isBadGrant)
        }
        for code in ["channel_quota", "channel_limit", "channels_full"] {
            #expect(RelayRefusal(status: 429, code: code, message: code).isChannelLimit)
            #expect(!RelayRefusal(status: 429, code: code, message: code).isBadGrant)
        }
        #expect(!RelayRefusal(status: 429, code: "rate_limited", message: "").isChannelLimit)
    }

    // MARK: The spare

    @Test func aSpareRunningOutIsReplacedTheNewOneFirst() async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        let old = grant("spare", expires: now.addingTimeInterval(1 * day))
        p.devices = ["d": device("aa", grant: grant("a", expires: now.addingTimeInterval(20 * day)))]
        p.state.channels[lane.key] = "SPARE=="
        p.state.channelGrants["SPARE=="] = old

        await p.tick(now: now)
        #expect(t.calls.first == .create(grant: p.devices["d"]!.relayGrant))
        #expect(t.calls.contains(.delete(channel: "SPARE==", grant: old)))
        #expect(p.state.channels[lane.key] == "NEW1==")
        #expect(p.state.channelGrants["SPARE=="] == nil)
        #expect(p.state.pendingDeletes.isEmpty)
    }

    @Test func aSpareStaysWhenItsReplacementFails() async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        t.onCreate = { _ in throw URLError(.notConnectedToInternet) }
        p.devices = ["d": device("aa", grant: grant("a", expires: now.addingTimeInterval(20 * day)))]
        p.state.channels[lane.key] = "SPARE=="
        p.state.channelGrants["SPARE=="] = grant("spare", expires: now.addingTimeInterval(1 * day))

        await p.tick(now: now)
        #expect(t.deletes.isEmpty)
        #expect(p.state.channels[lane.key] == "SPARE==")
        #expect(p.state.pendingDeletes.isEmpty)
        // Still good for a start for now.
        #expect(p.startableSpares(now: now)[lane.key] == "SPARE==")
        #expect(p.startableSpares(now: now.addingTimeInterval(1 * day - 60))[lane.key] == nil)
    }

    @Test func aSpareMadeStraightIsForgottenThroughTheRelay() async {
        let t = ScriptedTransport()
        let (p, lines) = pusher(t)
        p.devices = ["d": device("aa", grant: grant("a", expires: now.addingTimeInterval(20 * day)))]
        p.state.channels[lane.key] = "DIRECT=="

        await p.tick(now: now)
        #expect(t.deletes.isEmpty, "the relay can't delete it without a grant")
        #expect(p.state.channels[lane.key] == "NEW1==")
        #expect(p.state.pendingDeletes.isEmpty)
        #expect(lines.all.contains { $0.contains("DIRECT==") && $0.contains("wierdr-push reset") })
    }

    // MARK: Deleting channels

    @Test func aDeletionIsTriedAgainLaterThenGivenUp() async {
        let t = ScriptedTransport()
        let (p, lines) = pusher(t)
        t.onDelete = { _ in throw URLError(.timedOut) }
        p.state.channelGrants["OLD=="] = "g2.1.o.old"
        p.retire("OLD==", lane: lane, now: now, why: "test")
        #expect(p.state.pendingDeletes.count == 1)
        #expect(p.state.pendingDeletes.first?.grant == "g2.1.o.old")
        #expect(p.state.channelGrants["OLD=="] == nil)

        var clock = now
        await p.deletePending(now: clock)
        #expect(p.state.pendingDeletes.first?.attempts == 1)
        await p.deletePending(now: clock.addingTimeInterval(30))
        #expect(t.deletes.count == 1, "not before its wait is over")
        while let next = p.state.pendingDeletes.first?.next {
            clock = Date(timeIntervalSince1970: next)
            await p.deletePending(now: clock)
        }
        #expect(t.deletes.count == Pusher.deleteTries)
        #expect(clock.timeIntervalSince(now) > 86400, "the waits grow")
        #expect(lines.all.contains { $0.contains("gave up deleting channel OLD==") })
    }

    @Test func aDeletionQueuedLongAgoIsGivenUpAtItsNextFailure() async {
        let t = ScriptedTransport(relay: false)
        let (p, lines) = pusher(t)
        t.onDelete = { _ in throw URLError(.timedOut) }
        let since = now.timeIntervalSince1970 - 8 * day
        p.state.pendingDeletes = [.init(channel: "OLD==", bundle: lane.bundle, env: lane.env, grant: nil, since: since, next: since)]
        await p.deletePending(now: now)
        #expect(p.state.pendingDeletes.isEmpty)
        #expect(lines.all.contains { $0.contains("gave up") })
    }

    @Test func aDeletionEndsWhenTheChannelIsGoneOrTheRelayWontEver() async {
        let t = ScriptedTransport()
        let (p, lines) = pusher(t)
        t.onDelete = {
            if $0 == "GONE==" { throw APNsError(status: 400, reason: "BadChannelId") }
            if $0 == "REFUSED==" { throw RelayRefusal(status: 403, code: "key_revoked", message: "key_revoked") }
        }
        for c in ["GONE==", "REFUSED==", "FINE=="] {
            p.state.channelGrants[c] = "g2.1.o.\(c)"
            p.retire(c, lane: lane, now: now, why: "test")
        }
        await p.deletePending(now: now)
        #expect(t.deletes == ["GONE==", "REFUSED==", "FINE=="])
        #expect(p.state.pendingDeletes.isEmpty)
        #expect(lines.all.contains { $0.contains("gave up deleting channel REFUSED==") })
        #expect(!lines.all.contains { $0.contains("gave up deleting channel GONE==") })
    }

    @Test func aFewDeletionsATick() async {
        let t = ScriptedTransport(relay: false)
        let (p, _) = pusher(t)
        for i in 0..<7 { p.retire("C\(i)==", lane: lane, now: now, why: "test") }
        await p.deletePending(now: now)
        #expect(t.deletes.count == Pusher.deletesPerTick)
        #expect(p.state.pendingDeletes.count == 7 - Pusher.deletesPerTick)
        await p.deletePending(now: now, force: true)
        #expect(p.state.pendingDeletes.isEmpty)
    }

    @Test func anEndedActivitysChannelIsDeletedThroughTheQueue() async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        t.onDelete = { _ in throw URLError(.timedOut) }
        let g = grant("run", expires: now.addingTimeInterval(20 * day))
        p.planner.running[lane.key] = running("RUN==")
        p.state.channelGrants["RUN=="] = g
        // No devices left: the planner ends it.
        await p.tick(now: now)
        #expect(t.events == ["end"])
        #expect(t.calls.contains(.delete(channel: "RUN==", grant: g)))
        #expect(p.state.pendingDeletes.map(\.channel) == ["RUN=="])
        #expect(p.state.pendingDeletes.first?.grant == g)
        #expect(PushState.load(p.stateURL).pendingDeletes.map(\.channel) == ["RUN=="], "kept in the state file")
    }

    @Test func aBadChannelIsDroppedAndQueuedForDeletion() async {
        final class Refusing: PushTransport, @unchecked Sendable {
            var needsGrants: Bool { true }
            func start(token: String, grant: String?, channel: String, channelGrant: String?, bundle: String,
                       env: APNsEnvironment, payload: Data, priority: Int) async throws {}
            func broadcast(channel: String, grant: String?, bundle: String, env: APNsEnvironment, payload: Data,
                           priority: Int) async throws { throw APNsError(status: 404, reason: "BadChannelGrant") }
            func createChannel(bundle: String, env: APNsEnvironment, device: (token: String, grant: String)?)
                async throws -> (id: String, grant: String?) { ("X==", "g") }
            func deleteChannel(_ channel: String, grant: String?, bundle: String, env: APNsEnvironment) async throws {
                throw URLError(.timedOut)
            }
        }
        let p = Pusher(transport: Refusing(), host: "mac", seal: .generate(),
                       stateURL: FileManager.default.temporaryDirectory.appendingPathComponent("push-state-\(UUID()).json"))
        p.log = { _ in }
        let g = grant("run", expires: now.addingTimeInterval(-60))
        p.planner.running[lane.key] = running("RUN==")
        p.state.channelGrants["RUN=="] = g
        let ok = await p.perform(.update(lane: lane, channel: "RUN==", state: .init(working: 2), priority: 10, alert: nil), now: now)
        #expect(ok)
        #expect(p.planner.running[lane.key] == nil)
        #expect(p.state.pendingDeletes.map(\.channel) == ["RUN=="])
        #expect(p.state.pendingDeletes.first?.grant == g, "the relay deletes with a grant run out")
    }

    // MARK: Reset

    @Test func endAllThroughTheRelay() async {
        let t = ScriptedTransport()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("push-state-\(UUID().uuidString).json")
        let (p, _) = pusher(t, url: url)
        t.onDelete = { if $0 == "SPARE==" { throw URLError(.timedOut) } }
        let run = grant("run", expires: now.addingTimeInterval(20 * day))
        let spare = grant("spare", expires: now.addingTimeInterval(20 * day))
        p.planner.running[lane.key] = running("RUN==")
        p.state.channelGrants = ["RUN==": run, "SPARE==": spare]
        p.state.channels[lane.key] = "SPARE=="
        p.state.badGrants = ["g2.1.o.x"]

        await p.endAll()
        #expect(t.calls == [.broadcast(channel: "RUN==", grant: run, event: "end"),
                            .delete(channel: "RUN==", grant: run), .delete(channel: "SPARE==", grant: spare)])
        #expect(p.planner.running.isEmpty)
        #expect(p.state.channels.isEmpty)
        #expect(p.state.badGrants.isEmpty)
        #expect(p.state.channelGrants.isEmpty)
        let saved = PushState.load(url)
        #expect(saved.pendingDeletes.map(\.channel) == ["SPARE=="], "what failed waits for the daemon")
        #expect(saved.pendingDeletes.first?.grant == spare)
        #expect(saved.pendingDeletes.first?.attempts == 1)
    }

    // MARK: Grants

    @Test func aGrantRunningOutDoesntEndTheActivity() async {
        for expires in [now.addingTimeInterval(3600), now.addingTimeInterval(-3600)] {
            let t = ScriptedTransport()
            let (p, _) = pusher(t)
            p.devices = ["d": device("aa", grant: grant("a", expires: expires))]
            p.planner.running[lane.key] = running("RUN==")
            p.state.channelGrants["RUN=="] = grant("run", expires: now.addingTimeInterval(20 * day))
            p.state.channels[lane.key] = "SPARE=="
            p.state.channelGrants["SPARE=="] = grant("spare", expires: now.addingTimeInterval(20 * day))

            #expect(p.usableDevices(now: now).keys.sorted() == ["d"])
            await p.tick(now: now)
            #expect(!t.events.contains("end"))
            #expect(p.planner.running[lane.key]?.channel == "RUN==")
        }
    }

    @Test func refusedGrantsAndChannelGrantsAreKeptOnlyWhileNamed() {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        p.devices = ["d": device("aa", grant: "g2.9.o.new")]
        p.state.badGrants = ["g2.9.o.new", "g2.9.o.old"]
        #expect(p.pruneBadGrants())
        #expect(p.state.badGrants == ["g2.9.o.new"])
        #expect(!p.pruneBadGrants())

        p.state.channels[lane.key] = "SPARE=="
        p.planner.running[lane.key] = running("RUN==")
        p.state.pendingDeletes = [.init(channel: "DEL==", bundle: lane.bundle, env: lane.env, grant: "g", since: 0, next: 0)]
        p.state.channelGrants = ["SPARE==": "a", "RUN==": "b", "DEL==": "c", "STALE==": "d"]
        p.pruneChannelGrants()
        #expect(p.state.channelGrants.keys.sorted() == ["DEL==", "RUN==", "SPARE=="])
    }

    // MARK: Starts

    @Test func aStartCarriesItsChannelAndTheChannelsGrant() async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        let deviceGrant = grant("d", expires: now.addingTimeInterval(20 * day))
        let channelGrant = grant("run", expires: now.addingTimeInterval(20 * day))
        p.devices = ["d": device("aa", grant: deviceGrant)]
        p.state.channelGrants["RUN=="] = channelGrant
        let start = Planner.Action.start(lane: lane, channel: "RUN==", device: "d", token: "aa", state: .init(working: 1),
                                         alert: .init(title: "Wierdr", body: "1 working", sound: false))
        #expect(await p.perform(start, now: now))
        #expect(t.calls == [.start(token: "aa", grant: deviceGrant, channel: "RUN==", channelGrant: channelGrant)])

        // The device's grant refused: it waits for a new one.
        t.onStart = { throw RelayRefusal(status: 403, code: "key_revoked", message: "key_revoked") }
        #expect(await p.perform(start, now: now))
        #expect(p.state.badGrants == [deviceGrant])

        // The channel's grant refused (the relay says so): a new activity, the device's grant kept.
        p.state.badGrants = []
        p.planner.running[lane.key] = running("RUN==")
        t.onStart = { throw RelayRefusal(status: 403, code: "bad_grant", message: "channel grant: bad_grant") }
        #expect(await p.perform(start, now: now))
        #expect(p.state.badGrants.isEmpty)
        #expect(p.planner.running[lane.key] == nil)
        #expect(p.state.pendingDeletes.map(\.channel) == ["RUN=="])
    }

    @Test func noStartThroughTheRelayOnAChannelWithoutAGrant() async {
        let t = ScriptedTransport()
        let (p, _) = pusher(t)
        p.devices = ["d": device("aa", grant: grant("d", expires: now.addingTimeInterval(20 * day)))]
        p.planner.running[lane.key] = running("DIRECT==")
        let start = Planner.Action.start(lane: lane, channel: "DIRECT==", device: "d", token: "aa", state: .init(working: 1),
                                         alert: .init(title: "Wierdr", body: "1 working", sound: false))
        #expect(await p.perform(start, now: now))
        #expect(t.calls.isEmpty)
        #expect(p.planner.running[lane.key] == nil)
        #expect(p.state.badGrants.isEmpty)
    }

    // MARK: The state file

    @Test func theStateFileKeepsTheQueueAndReadsWithoutIt() throws {
        let old = #"{"channels": {}, "running": {}, "badTokens": [], "channelGrants": {"C==": "g"}, "badGrants": []}"#
        #expect(try JSONDecoder().decode(PushState.self, from: Data(old.utf8)).pendingDeletes.isEmpty)
        var s = PushState()
        s.pendingDeletes = [.init(channel: "C==", bundle: lane.bundle, env: .production, grant: "g", attempts: 2, since: 1, next: 2)]
        let back = try JSONDecoder().decode(PushState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    // MARK: APNs straight

    @Test func aStartStraightToAPNsExpiresInTenMinutes() throws {
        let key = P256.Signing.PrivateKey()
        let client = APNsClient(signer: try APNsSigner(p8: key.pemRepresentation, keyID: "KEY1234567", teamID: "AUL4CCB2XY"))
        let r = client.startRequest(token: "aa", bundle: "pw.xff.wierdr", env: .development, payload: Data("{}".utf8),
                                    priority: 10, now: now)
        #expect(r.value(forHTTPHeaderField: "apns-expiration") == "1800000600")
        #expect(r.value(forHTTPHeaderField: "apns-topic") == "pw.xff.wierdr.push-type.liveactivity")
    }
}

// MARK: RelayClient on the wire

/// Answers `RelayClient`'s requests in place of the relay and keeps their bodies.
private final class RelayStub: URLProtocol {
    nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var reply: (String) -> (Int, [String: Any]) = { _ in (200, [:]) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.bodies[path] = (try? JSONSerialization.jsonObject(with: Self.body(of: request))) as? [String: Any] ?? [:]
        let (status, json) = Self.reply(path)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite(.serialized) struct RelayClientWireTests {
    let relay: RelayClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RelayStub.self]
        return RelayClient(base: URL(string: "https://relay.example")!, session: URLSession(configuration: config))
    }()

    @Test func everyCallNamesTheAppAndAStartItsChannel() async throws {
        RelayStub.bodies = [:]
        RelayStub.reply = { path in path == "/v1/channels" ? (200, ["channel": "NEW==", "grant": "g2.1.o.c", "expires": 1]) : (200, ["ok": true]) }
        try await relay.start(token: "aa", grant: "gd", channel: "CH==", channelGrant: "gc", bundle: "pw.xff.wierdr",
                              env: .development, payload: Data("{}".utf8), priority: 10)
        try await relay.broadcast(channel: "CH==", grant: "gc", bundle: "pw.xff.wierdr", env: .development,
                                  payload: Data("{}".utf8), priority: 5)
        let made = try await relay.createChannel(bundle: "pw.xff.wierdr", env: .development, device: ("aa", "gd"))
        try await relay.deleteChannel("CH==", grant: "gc", bundle: "pw.xff.wierdr", env: .development)

        #expect(made.id == "NEW==" && made.grant == "g2.1.o.c")
        let start = try #require(RelayStub.bodies["/v1/start"])
        #expect(start["channel"] as? String == "CH==")
        #expect(start["channel_grant"] as? String == "gc")
        #expect(start["grant"] as? String == "gd")
        for path in ["/v1/start", "/v1/broadcast", "/v1/channels", "/v1/channels/delete"] {
            #expect(RelayStub.bodies[path]?["bundle"] as? String == "pw.xff.wierdr", "\(path)")
        }
    }

    @Test func theRelaysRefusalsReadAsTheyShould() async {
        RelayStub.reply = { path in
            switch path {
            case "/v1/start": (403, ["error": "key_revoked", "message": "key_revoked"])
            case "/v1/broadcast": (403, ["error": "key_revoked", "message": "key_revoked"])
            default: (503, ["error": "channels_full", "message": "the app's channels are full"])
            }
        }
        do {
            try await relay.start(token: "aa", grant: "gd", channel: "CH==", channelGrant: "gc", bundle: "pw.xff.wierdr",
                                  env: .development, payload: Data("{}".utf8), priority: 10)
            Issue.record("no refusal")
        } catch {
            #expect((error as? RelayRefusal)?.isBadGrant == true)
        }
        do {
            try await relay.broadcast(channel: "CH==", grant: "gc", bundle: "pw.xff.wierdr", env: .development,
                                      payload: Data("{}".utf8), priority: 5)
            Issue.record("no refusal")
        } catch {
            #expect((error as? APNsError)?.isBadChannel == true, "a channel's refused grant reads as a bad channel")
        }
        do {
            _ = try await relay.createChannel(bundle: "pw.xff.wierdr", env: .development, device: ("aa", "gd"))
            Issue.record("no refusal")
        } catch {
            #expect((error as? RelayRefusal)?.isChannelLimit == true)
        }
    }
}
