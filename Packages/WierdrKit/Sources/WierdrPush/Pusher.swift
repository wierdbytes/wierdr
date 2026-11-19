import Foundation
import HerdrCore
import WierdrActivity
import WierdrModel

/// `~/.config/wierdr/push.json`: how the pushes go out. Either Wierdr's relay
/// (`relay`, its URL: it signs them) or straight to APNs, signed with the team's key
/// on this Mac (`key_file`, `key_id`, `team_id`).
public struct PushConfig: Codable, Sendable {
    /// Path to the `.p8` key (APNs, of the team that signs the app); `~` allowed.
    public var keyFile: String?
    public var keyID: String?
    public var teamID: String?
    /// The relay's URL (`https://relay.wierdr.workat.dev`): when set, the pushes go through it.
    public var relay: String?
    /// The computer's name on the activity (default: this Mac's name).
    public var host: String?

    enum CodingKeys: String, CodingKey {
        case keyFile = "key_file", keyID = "key_id", teamID = "team_id", relay, host
    }

    /// The relay, or APNs with the key.
    public func transport() throws -> PushTransport {
        if let relay {
            guard let url = URL(string: relay), url.scheme == "https" else { throw PushError("relay: not an https URL: \(relay)") }
            return RelayClient(base: url)
        }
        return APNsClient(signer: try signer())
    }

    /// What `status` says about it.
    public var summary: String {
        if let relay { return "relay \(relay)" }
        return "key \(keyID ?? "?"), team \(teamID ?? "?"), \(keyFile ?? "?")"
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wierdr/push.json")
    }

    public static func load(_ url: URL = defaultURL) throws -> PushConfig {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw PushError("no config at \(url.path): {\"key_file\": \"~/.config/wierdr/AuthKey_XXXXXXXXXX.p8\", \"key_id\": \"XXXXXXXXXX\", \"team_id\": \"XXXXXXXXXX\"}")
        }
        return try JSONDecoder().decode(PushConfig.self, from: data)
    }

    public func signer() throws -> APNsSigner {
        guard let keyFile, let keyID, let teamID else {
            throw PushError("push.json: set relay, or key_file, key_id and team_id")
        }
        let path = (keyFile as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else { throw PushError("can't read \(path)") }
        return try APNsSigner(p8: pem, keyID: keyID, teamID: teamID)
    }
}

public struct PushError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// What the pusher keeps between runs: channels, the running activities, tokens APNs refused.
public struct PushState: Codable, Sendable, Equatable {
    /// Each lane's spare channel (for the next activity), by lane key.
    public var channels: [String: String] = [:]
    public var running: [String: Planner.Running] = [:]
    public var badTokens: Set<String> = []
    /// Through the relay: each channel's grant (spare and running ones).
    public var channelGrants: [String: String] = [:]
    /// Device grants the relay refused, while the registry still has them (until the app
    /// brings a new one).
    public var badGrants: Set<String> = []
    /// Channels done with, still to delete (APNs keeps a channel until it's deleted, and an
    /// app may have 10,000): tried again with a growing wait, given up in the end.
    public var pendingDeletes: [PendingDelete] = []

    /// A channel to delete.
    public struct PendingDelete: Codable, Hashable, Sendable {
        public var channel: String
        public var bundle: String
        public var env: APNsEnvironment
        /// Its grant, through the relay (which deletes with one run out too).
        public var grant: String?
        /// Tries so far.
        public var attempts: Int
        /// Queued at (UNIX seconds).
        public var since: Double
        /// Not tried again before (UNIX seconds).
        public var next: Double

        public init(channel: String, bundle: String, env: APNsEnvironment, grant: String?, attempts: Int = 0,
                    since: Double, next: Double) {
            self.channel = channel; self.bundle = bundle; self.env = env; self.grant = grant
            self.attempts = attempts; self.since = since; self.next = next
        }
    }

    public init() {}

    enum CodingKeys: String, CodingKey { case channels, running, badTokens, channelGrants, badGrants, pendingDeletes }

    /// Fields a newer pusher added may be missing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = try c.decodeIfPresent([String: String].self, forKey: .channels) ?? [:]
        running = try c.decodeIfPresent([String: Planner.Running].self, forKey: .running) ?? [:]
        badTokens = try c.decodeIfPresent(Set<String>.self, forKey: .badTokens) ?? []
        channelGrants = try c.decodeIfPresent([String: String].self, forKey: .channelGrants) ?? [:]
        badGrants = try c.decodeIfPresent(Set<String>.self, forKey: .badGrants) ?? []
        pendingDeletes = try c.decodeIfPresent([PendingDelete].self, forKey: .pendingDeletes) ?? []
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wierdr/push-state.json")
    }

    public static func load(_ url: URL = defaultURL) -> PushState {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(PushState.self, from: data) else {
            return PushState()
        }
        return s
    }

    public func save(_ url: URL = defaultURL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension ActivitySealKey {
    /// `~/.config/wierdr/seal-key`: the key the pushes are sealed with (base64, 0600).
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wierdr/seal-key")
    }

    /// The key kept at `url`, or a new one written there.
    public static func loadOrCreate(_ url: URL = defaultURL) throws -> ActivitySealKey {
        if let data = try? Data(contentsOf: url) {
            guard let key = ActivitySealKey(base64: String(decoding: data, as: UTF8.self)) else {
                throw PushError("\(url.path) is not a seal key (base64 of 32 bytes); remove it to make a new one")
            }
            return key
        }
        let key = ActivitySealKey.generate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(key.base64.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw PushError("can't write \(url.path)")
        }
        return key
    }
}

/// The Mac side of the agents Live Activity: mirrors the local core's workspace
/// (read-only `WorkspaceEngine`), reads the devices from the `wierdr-push`
/// document, publishes the seal key in `wierdr-push-seal`, and pushes what the
/// `Planner` says through APNs, sealed.
@MainActor
public final class Pusher {
    public let workspace = Workspace()
    let engine: WorkspaceEngine
    let transport: PushTransport
    let host: String
    let seal: ActivitySealKey
    let stateURL: URL
    var state: PushState
    var planner: Planner
    var devices: [String: PushRegistry.Device] = [:]
    var registryReadAt = Date.distantPast
    /// When `wierdr-push-seal` was last found holding the key.
    var sealCheckedAt = Date.distantPast
    /// After an APNs failure: no pushes until then (5 s, doubling to 5 min).
    var pausedUntil = Date.distantPast
    var backoff: TimeInterval = 0
    /// By lane key: no new channel asked for before then (the relay's channel limits, a
    /// failure). Only that lane waits; pushes go on.
    var laneRetryAt: [String: Date] = [:]
    /// Channels without a relay grant already forgotten (said once in the log).
    var forgotten: Set<String> = []
    var engineEnded: Error?
    public var log: (String) -> Void = { print($0) }

    /// A spare channel whose grant runs out sooner than this is replaced (an activity lives 8 hours).
    static let spareMargin: TimeInterval = 2 * 86400
    /// A spare a start may take still has a grant good for this long.
    static let startMargin: TimeInterval = 3600
    /// The wait for a lane's next channel after the relay's channel limits (picked in the range).
    static let channelLimitWait: ClosedRange<TimeInterval> = 300...900
    /// The wait for a lane's next channel after any other failure.
    static let channelFailureWait: TimeInterval = 60
    /// Channel deletions tried a tick (the due ones).
    static let deletesPerTick = 5
    /// A deletion is given up after this many tries, or this long after it was queued.
    static let deleteTries = 10
    static let deleteGiveUp: TimeInterval = 7 * 86400

    /// The wait after a deletion's `attempts`-th failed try: 1 min, 3, 9 …, at most 12 hours.
    static func deleteBackoff(_ attempts: Int) -> TimeInterval {
        min(60 * pow(3, Double(max(attempts - 1, 0))), 12 * 3600)
    }

    public init(transport: PushTransport, host: String, seal: ActivitySealKey, stateURL: URL = PushState.defaultURL,
                settings: Planner.Settings = .init()) {
        self.transport = transport
        self.host = host
        self.seal = seal
        self.stateURL = stateURL
        // A mirror: no writes, no limits; git facts and colors rarely (the activity shows neither).
        engine = WorkspaceEngine(workspace: workspace,
                                 options: EngineOptions(allowWrites: false, refreshInterval: 3600, limitsDocument: nil))
        state = PushState.load(stateURL)
        planner = Planner(settings: settings, running: state.running)
    }

    /// Runs until the connection ends (then throws; launchd starts it again).
    public func run(on connection: CoreConnection) async throws {
        engine.log = { [weak self] in self?.log("[engine] \($0)") }
        engineEnded = nil
        let engineTask = Task { @MainActor [weak self, engine] in
            do { try await engine.run(on: connection); self?.engineEnded = PushError("the engine stopped") } catch {
                self?.engineEnded = error
            }
        }
        defer { engineTask.cancel() }
        log("watching agents for \(host)")
        var liveSince: Date?
        while true {
            if let engineEnded { throw engineEnded }
            try await Task.sleep(for: .seconds(1))
            if Task.isCancelled { throw CancellationError() }
            guard workspace.phase == .live else {
                if case .failed(let message) = workspace.phase { throw PushError("core: \(message)") }
                liveSince = nil
                continue
            }
            // Statuses settle a moment after the first snapshot.
            let now = Date()
            if liveSince == nil { liveSince = now }
            guard now.timeIntervalSince(liveSince!) >= 2 else { continue }
            if now.timeIntervalSince(sealCheckedAt) >= 60 {
                await publishSeal(connection, now: now)
            }
            if now.timeIntervalSince(registryReadAt) >= 5 {
                registryReadAt = now
                await readRegistry(connection)
            }
            await tick(now: now)
        }
    }

    func readRegistry(_ connection: CoreConnection) async {
        do {
            let doc = try await connection.getDoc(PushRegistry.documentName)
            let registry = doc.value == .null ? PushRegistry() : PushRegistry.decode(try JSONEncoder().encode(doc.value))
            if registry.devices != devices {
                let names = registry.devices.values
                    .map { "\($0.name) (\($0.env)\($0.sealKid == seal.kid ? "" : ", no key"))" }.sorted()
                log("devices: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
            }
            // A device that just got the key: show it the agents now, not at the next change.
            for (id, d) in registry.devices where d.sealKid == seal.kid && devices[id]?.sealKid != seal.kid {
                if let env = APNsEnvironment(rawValue: d.env) { planner.resend(lane: Lane(bundle: d.bundle, env: env)) }
            }
            devices = registry.devices
            if pruneBadGrants() { state.save(stateURL) }
        } catch {
            log("can't read \(PushRegistry.documentName): \(error)")
        }
    }

    /// Forgets refused grants the registry no longer has (the app brought new ones); whether
    /// any went. Only after the registry was read: an empty one before that would forget them all.
    @discardableResult
    func pruneBadGrants() -> Bool {
        let kept = state.badGrants.intersection(devices.values.compactMap(\.relayGrant))
        guard kept != state.badGrants else { return false }
        state.badGrants = kept
        return true
    }

    /// Keeps the grants of channels something still names: the spares, the running activities'
    /// and those waiting to be deleted.
    func pruneChannelGrants() {
        let named = Set(state.channels.values).union(planner.running.values.map(\.channel))
            .union(state.pendingDeletes.map(\.channel))
        state.channelGrants = state.channelGrants.filter { named.contains($0.key) }
    }

    /// Writes the key into `wierdr-push-seal` unless it's there (compare-and-swap).
    func publishSeal(_ connection: CoreConnection, now: Date) async {
        let want = SealDocument(seal)
        do {
            let doc = try await connection.getDoc(SealDocument.documentName)
            let have = doc.value == .null ? nil : SealDocument.decode(try JSONEncoder().encode(doc.value))
            if have != want {
                _ = try await connection.setDoc(SealDocument.documentName, value: try JSONValue(data: want.encoded()),
                                                version: doc.version)
                log("seal key \(seal.kid) published in \(SealDocument.documentName)")
            }
            sealCheckedAt = now
        } catch {
            log("can't publish the seal key: \(error)")
            sealCheckedAt = now.addingTimeInterval(-50)
        }
    }

    func tick(now: Date) async {
        guard now >= pausedUntil else { return }
        let before = state
        let usable = usableDevices(now: now)
        await ensureChannels(for: usable, now: now)
        let summary = ActivityPayload.fitting(ActivitySummary.state(of: workspace, now: now), key: seal)
        let actions = planner.step(now: now, summary: summary, devices: usable, channels: startableSpares(now: now))
        var failed = false
        for action in actions {
            if !(await perform(action, now: now)) { failed = true }
        }
        // A spare that a start took is the activity's now: the next start gets a new one.
        for r in planner.running.values where state.channels[r.lane.key] == r.channel {
            state.channels[r.lane.key] = nil
        }
        // An ended activity's channel is done with.
        for case let .end(lane, channel, _) in actions where state.channels[lane.key] != channel {
            retire(channel, lane: lane, now: now, why: "ended")
        }
        await deletePending(now: now)
        if failed {
            backoff = min(max(backoff * 2, 5), 300)
            pausedUntil = now.addingTimeInterval(backoff)
        } else if !actions.isEmpty {
            backoff = 0
        }
        state.running = planner.running
        pruneChannelGrants()
        if state != before { state.save(stateURL) }
    }

    /// The devices of the lanes the planner sees: a token APNs didn't refuse and, through the
    /// relay, a grant it didn't refuse. Not by when the grant runs out: an activity going on
    /// there needs no device grant (broadcasts take the channel's), so it isn't ended for it;
    /// a start with a grant run out is refused, and the grant goes to `badGrants` until the
    /// app brings a new one (it asks 10 days before the end).
    func usableDevices(now: Date) -> [String: PushRegistry.Device] {
        devices.filter { _, d in
            guard !state.badTokens.contains(d.startToken) else { return false }
            guard transport.needsGrants else { return true }
            guard let grant = d.relayGrant, !state.badGrants.contains(grant) else { return false }
            return true
        }
    }

    /// The spares the planner may start on: through the relay, those whose grant is good for
    /// a while more (a start on a channel the relay refuses would read as the device's grant
    /// refused).
    func startableSpares(now: Date) -> [String: String] {
        guard transport.needsGrants else { return state.channels }
        return state.channels.filter { _, channel in
            (state.channelGrants[channel].flatMap(RelayGrant.expiry) ?? .distantPast) > now.addingTimeInterval(Self.startMargin)
        }
    }

    /// The lane's device to make a channel with, through the relay: the one whose grant lasts longest.
    func channelMaker(_ devices: [String: PushRegistry.Device]) -> (id: String, device: PushRegistry.Device, grant: String)? {
        devices.compactMap { id, d in d.relayGrant.map { (id: id, device: d, grant: $0) } }
            .max { a, b in
                let ea = a.device.relayGrantExpiry ?? .distantPast, eb = b.device.relayGrantExpiry ?? .distantPast
                return ea != eb ? ea < eb : a.id > b.id
            }
    }

    /// A spare channel for every lane with devices (kept in the state file). Through the relay
    /// it's made with the grant of the lane's device whose grant lasts longest, and a spare whose
    /// own grant runs out within two days is replaced: the new one first, then the old one to
    /// `pendingDeletes` (so a failure keeps the old one). A failure holds back only its lane:
    /// a refused device grant goes to `badGrants` (another device of the lane next tick), the
    /// relay's channel limits wait 5–15 minutes, anything else a minute.
    func ensureChannels(for devices: [String: PushRegistry.Device], now: Date) async {
        var lanes: [String: (lane: Lane, devices: [String: PushRegistry.Device])] = [:]
        for (id, d) in devices {
            guard let env = APNsEnvironment(rawValue: d.env), !d.startToken.isEmpty, !d.bundle.isEmpty else { continue }
            let lane = Lane(bundle: d.bundle, env: env)
            lanes[lane.key, default: (lane, [:])].devices[id] = d
        }
        for key in lanes.keys.sorted() {
            let (lane, laneDevices) = lanes[key]!
            var replacing: String?
            if let spare = state.channels[key] {
                guard transport.needsGrants else { continue }
                if let grant = state.channelGrants[spare] {
                    guard (RelayGrant.expiry(grant) ?? .distantPast) < now.addingTimeInterval(Self.spareMargin) else { continue }
                    replacing = spare
                } else {
                    // Made straight with the key, before the pusher went through the relay.
                    state.channels[key] = nil
                    forgetUngranted(spare, lane: lane, why: "the spare")
                }
            }
            if let at = laneRetryAt[key], now < at { continue }
            let maker = channelMaker(laneDevices)
            if transport.needsGrants && maker == nil { continue }
            do {
                let made = try await transport.createChannel(bundle: lane.bundle, env: lane.env,
                                                            device: transport.needsGrants ? maker.map { ($0.device.startToken, $0.grant) } : nil)
                laneRetryAt[key] = nil
                state.channels[key] = made.id
                if let grant = made.grant { state.channelGrants[made.id] = grant }
                if let replacing { retire(replacing, lane: lane, now: now, why: "replaced, its grant running out") }
                state.save(stateURL)
                log("new channel for \(key): \(made.id)\(transport.needsGrants ? " (through the relay, for \(maker?.device.name ?? "?"))" : "")")
            } catch let r as RelayRefusal where r.isBadGrant {
                if let maker { state.badGrants.insert(maker.grant) }
                log("can't create a channel for \(key) with \(maker?.device.name ?? "?")'s grant: \(r); waiting for Wierdr to bring a new one")
            } catch let r as RelayRefusal where r.isChannelLimit {
                let wait = TimeInterval.random(in: Self.channelLimitWait)
                laneRetryAt[key] = now.addingTimeInterval(wait)
                log("can't create a channel for \(key): \(r); trying again in \(Int(wait / 60)) min")
            } catch {
                laneRetryAt[key] = now.addingTimeInterval(Self.channelFailureWait)
                let hint = error is APNsError ? " (is Broadcast on for the App ID's Push Notifications?)" : ""
                log("can't create a channel for \(key): \(error)\(hint); trying again in a minute")
            }
        }
    }

    /// Queues a channel done with for deletion (`pendingDeletes`), with its grant.
    func retire(_ channel: String, lane: Lane, now: Date, why: String) {
        let grant = state.channelGrants.removeValue(forKey: channel)
        if transport.needsGrants && grant == nil {
            forgetUngranted(channel, lane: lane, why: why)
            return
        }
        guard !state.pendingDeletes.contains(where: { $0.channel == channel && $0.env == lane.env }) else { return }
        let t = now.timeIntervalSince1970
        state.pendingDeletes.append(.init(channel: channel, bundle: lane.bundle, env: lane.env, grant: grant, since: t, next: t))
    }

    /// A channel made straight with the APNs key, before the pusher went through the relay:
    /// the relay can't delete it without a grant, so it's forgotten, with a word in the log.
    func forgetUngranted(_ channel: String, lane: Lane, why: String) {
        guard forgotten.insert(channel).inserted else { return }
        log("channel \(channel) (\(lane.key), \(why)) was made straight with the APNs key: the relay can't delete it, "
            + "so it's forgotten; it stays one of the app's channels until deleted with the key "
            + "(`wierdr-push reset` with the key in push.json) or by the relay's admin cleanup")
    }

    /// Deletes queued channels: the due ones, at most `deletesPerTick` (`force`: all of them,
    /// due or not). A failure is tried again after a growing wait and given up after
    /// `deleteTries` tries or `deleteGiveUp`; a channel APNs no longer has counts as deleted;
    /// a refusal that won't change (the grant, a bad request) is given up at once.
    func deletePending(now: Date, force: Bool = false) async {
        let t = now.timeIntervalSince1970
        var tried = 0
        for p in state.pendingDeletes {
            guard force || (p.next <= t && tried < Self.deletesPerTick) else { continue }
            tried += 1
            let name = "channel \(p.channel) (\(p.bundle) \(p.env.rawValue))"
            do {
                try await transport.deleteChannel(p.channel, grant: p.grant, bundle: p.bundle, env: p.env)
                dropPending(p)
                log("deleted \(name)")
            } catch let e as APNsError where e.isBadChannel {
                dropPending(p)
                log("\(name) was gone already (\(e))")
            } catch let r as RelayRefusal where r.isBadGrant || r.status == 400 {
                dropPending(p)
                log("gave up deleting \(name): \(r); it stays one of the app's channels until the relay's admin cleanup")
            } catch {
                var q = p
                q.attempts += 1
                if q.attempts >= Self.deleteTries || t - q.since >= Self.deleteGiveUp {
                    dropPending(p)
                    let since = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: q.since))
                    log("gave up deleting \(name) after \(q.attempts) tries since \(since): \(error)")
                } else {
                    q.next = t + Self.deleteBackoff(q.attempts)
                    if let i = state.pendingDeletes.firstIndex(where: { $0.channel == p.channel && $0.env == p.env }) {
                        state.pendingDeletes[i] = q
                    }
                }
            }
        }
    }

    private func dropPending(_ p: PushState.PendingDelete) {
        state.pendingDeletes.removeAll { $0.channel == p.channel && $0.env == p.env }
    }

    /// Sends one push; false when it failed for a reason worth waiting out.
    func perform(_ action: Planner.Action, now: Date) async -> Bool {
        let stale = planner.staleDate(now: now)
        switch action {
        case let .start(lane, channel, device, token, s, alert):
            let name = devices[device]?.name ?? device
            let channelGrant = state.channelGrants[channel]
            if transport.needsGrants && channelGrant == nil {
                // The activity's channel was made straight with the key: the relay won't start on it.
                log("start on \(name): channel \(channel) has no relay grant; a new activity on a new channel")
                planner.drop(lane: lane)
                retire(channel, lane: lane, now: now, why: "the activity's")
                return true
            }
            let payload = ActivityPayload.start(attributes: AgentsActivityAttributes(host: host), state: s,
                                                channel: channel, alert: alert, stale: stale, now: now, key: seal)
            do {
                try await transport.start(token: token, grant: devices[device]?.relayGrant, channel: channel,
                                          channelGrant: channelGrant, bundle: lane.bundle, env: lane.env,
                                          payload: payload, priority: 10)
                log("start on \(name): \(Self.describe(s))")
                return true
            } catch let r as RelayRefusal where r.isBadGrant && r.message.localizedCaseInsensitiveContains("channel") {
                // The channel's grant, not the device's: a new activity on a new channel.
                log("start on \(name): \(r); a new activity on a new channel")
                planner.drop(lane: lane)
                retire(channel, lane: lane, now: now, why: "its grant refused")
                return true
            } catch let r as RelayRefusal where r.isBadGrant {
                log("start on \(name): \(r); waiting for Wierdr to bring a new grant")
                if let grant = devices[device]?.relayGrant { state.badGrants.insert(grant) }
                planner.drop(device: device, lane: lane)
                return true
            } catch let e as APNsError where e.isBadToken {
                log("start on \(name): \(e); forgetting its token")
                state.badTokens.insert(token)
                planner.drop(device: device, lane: lane)
                return true
            } catch {
                log("start on \(name) failed: \(error)")
                planner.drop(device: device, lane: lane)
                return false
            }
        case let .update(lane, channel, s, priority, alert):
            let payload = ActivityPayload.update(state: s, alert: alert, stale: stale, now: now, key: seal)
            do {
                try await transport.broadcast(channel: channel, grant: state.channelGrants[channel], bundle: lane.bundle,
                                              env: lane.env, payload: payload, priority: priority)
                log("update p\(priority): \(Self.describe(s))\(alert.map { " — alert \($0.title): \($0.body)" } ?? "")")
                return true
            } catch let e as APNsError where e.isBadChannel {
                log("update: \(e); a new activity on a new channel")
                planner.drop(lane: lane)
                retire(channel, lane: lane, now: now, why: "refused")
                return true
            } catch {
                log("update failed: \(error)")
                planner.resend(lane: lane)
                return false
            }
        case let .end(lane, channel, s):
            let payload = ActivityPayload.end(state: s, dismissal: now.addingTimeInterval(-1), now: now, key: seal)
            do {
                try await transport.broadcast(channel: channel, grant: state.channelGrants[channel], bundle: lane.bundle,
                                              env: lane.env, payload: payload, priority: 10)
                log("end")
            } catch {
                log("end failed: \(error)")
            }
            return true
        }
    }

    /// `1 done · 1 working [done t9h "Title", working t5w "Title"]` for the log.
    static func describe(_ s: ActivitySummary.State) -> String {
        let agents = s.agents.map { "\($0.status.rawValue) \($0.id) \"\($0.title.prefix(30))\"" }
        return ActivitySummary.line(s) + (agents.isEmpty ? "" : " [\(agents.joined(separator: ", "))]")
    }

    /// The lane a state file's key names (`<bundle> <env>`).
    static func lane(key: String) -> Lane? {
        let parts = key.split(separator: " ")
        guard parts.count == 2, let env = APNsEnvironment(rawValue: String(parts[1])) else { return nil }
        return Lane(bundle: String(parts[0]), env: env)
    }

    /// Ends every running activity now and drops the channels (`wierdr-push reset`): each
    /// deletion is tried at once (with any still queued); those that fail stay queued in the
    /// state file for the daemon's next run.
    public func endAll() async {
        let now = Date()
        for r in planner.running.values {
            _ = await perform(.end(lane: r.lane, channel: r.channel, state: r.last), now: now)
            retire(r.channel, lane: r.lane, now: now, why: "reset")
        }
        planner.running = [:]
        state.running = [:]
        state.badTokens = []
        state.badGrants = []
        // Spare channels too: the next start makes a new one.
        for (key, channel) in state.channels.sorted(by: { $0.key < $1.key }) {
            guard let lane = Self.lane(key: key) else { continue }
            retire(channel, lane: lane, now: now, why: "reset")
        }
        state.channels = [:]
        await deletePending(now: now, force: true)
        pruneChannelGrants()
        state.save(stateURL)
        if !state.pendingDeletes.isEmpty {
            log("\(state.pendingDeletes.count) channel(s) not deleted yet: the daemon tries again")
        }
    }
}
