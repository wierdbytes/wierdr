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
public struct PushState: Codable, Sendable {
    /// Each lane's spare channel (for the next activity), by lane key.
    public var channels: [String: String] = [:]
    public var running: [String: Planner.Running] = [:]
    public var badTokens: Set<String> = []
    /// Through the relay: each channel's grant (spare and running ones).
    public var channelGrants: [String: String] = [:]
    /// Device grants the relay refused (until the app brings a new one).
    public var badGrants: Set<String> = []

    public init() {}

    enum CodingKeys: String, CodingKey { case channels, running, badTokens, channelGrants, badGrants }

    /// Fields a newer pusher added may be missing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = try c.decodeIfPresent([String: String].self, forKey: .channels) ?? [:]
        running = try c.decodeIfPresent([String: Planner.Running].self, forKey: .running) ?? [:]
        badTokens = try c.decodeIfPresent(Set<String>.self, forKey: .badTokens) ?? []
        channelGrants = try c.decodeIfPresent([String: String].self, forKey: .channelGrants) ?? [:]
        badGrants = try c.decodeIfPresent(Set<String>.self, forKey: .badGrants) ?? []
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
    var engineEnded: Error?
    public var log: (String) -> Void = { print($0) }

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
        } catch {
            log("can't read \(PushRegistry.documentName): \(error)")
        }
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
        let usable = usableDevices(now: now)
        await ensureChannels(for: usable, now: now)
        let summary = ActivityPayload.fitting(ActivitySummary.state(of: workspace, now: now), key: seal)
        let actions = planner.step(now: now, summary: summary, devices: usable, channels: state.channels)
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
            try? await transport.deleteChannel(channel, grant: state.channelGrants[channel], bundle: lane.bundle, env: lane.env)
            state.channelGrants[channel] = nil
        }
        if failed {
            backoff = min(max(backoff * 2, 5), 300)
            pausedUntil = now.addingTimeInterval(backoff)
        } else if !actions.isEmpty {
            backoff = 0
        }
        if state.running != planner.running || !actions.isEmpty {
            state.running = planner.running
            state.save(stateURL)
        }
    }

    /// Devices the pushes can go to: a token APNs didn't refuse and, through the relay, a
    /// grant it didn't refuse and that won't run out within the day.
    func usableDevices(now: Date) -> [String: PushRegistry.Device] {
        devices.filter { _, d in
            guard !state.badTokens.contains(d.startToken) else { return false }
            guard transport.needsGrants else { return true }
            guard let grant = d.relayGrant, !state.badGrants.contains(grant),
                  let expiry = d.relayGrantExpiry, expiry > now.addingTimeInterval(86400) else { return false }
            return true
        }
    }

    /// A spare channel for every lane with devices (kept in the state file); through the
    /// relay, a spare whose grant runs out within two days is replaced (an activity lives 8 hours).
    func ensureChannels(for devices: [String: PushRegistry.Device], now: Date) async {
        for (_, d) in devices.sorted(by: { $0.key < $1.key }) {
            guard let env = APNsEnvironment(rawValue: d.env) else { continue }
            let lane = Lane(bundle: d.bundle, env: env)
            if let spare = state.channels[lane.key], transport.needsGrants,
               (state.channelGrants[spare].flatMap(RelayGrant.expiry) ?? .distantPast) < now.addingTimeInterval(2 * 86400) {
                try? await transport.deleteChannel(spare, grant: state.channelGrants[spare], bundle: lane.bundle, env: lane.env)
                state.channels[lane.key] = nil
                state.channelGrants[spare] = nil
            }
            guard state.channels[lane.key] == nil else { continue }
            do {
                let made = try await transport.createChannel(bundle: lane.bundle, env: lane.env,
                                                            device: d.relayGrant.map { (d.startToken, $0) })
                state.channels[lane.key] = made.id
                if let grant = made.grant { state.channelGrants[made.id] = grant }
                state.save(stateURL)
                log("new channel for \(lane.key): \(made.id)\(transport.needsGrants ? " (through the relay, for \(d.name))" : "")")
            } catch {
                log("can't create a channel for \(lane.key): \(error) (is Broadcast on for the App ID's Push Notifications?)")
                pausedUntil = Date().addingTimeInterval(60)
            }
        }
    }

    /// Sends one push; false when it failed for a reason worth waiting out.
    func perform(_ action: Planner.Action, now: Date) async -> Bool {
        let stale = planner.staleDate(now: now)
        switch action {
        case let .start(lane, channel, device, token, s, alert):
            let payload = ActivityPayload.start(attributes: AgentsActivityAttributes(host: host), state: s,
                                                channel: channel, alert: alert, stale: stale, now: now, key: seal)
            do {
                try await transport.start(token: token, grant: devices[device]?.relayGrant, bundle: lane.bundle,
                                          env: lane.env, payload: payload, priority: 10)
                log("start on \(devices[device]?.name ?? device): \(Self.describe(s))")
                return true
            } catch let r as RelayRefusal where r.isBadGrant {
                log("start on \(devices[device]?.name ?? device): \(r); waiting for Wierdr to bring a new grant")
                if let grant = devices[device]?.relayGrant { state.badGrants.insert(grant) }
                planner.drop(device: device, lane: lane)
                return true
            } catch let e as APNsError where e.isBadToken {
                log("start on \(devices[device]?.name ?? device): \(e); forgetting its token")
                state.badTokens.insert(token)
                planner.drop(device: device, lane: lane)
                return true
            } catch {
                log("start on \(devices[device]?.name ?? device) failed: \(error)")
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

    /// Ends every running activity now and drops the channels (`wierdr-push reset`).
    public func endAll() async {
        let now = Date()
        for r in planner.running.values {
            _ = await perform(.end(lane: r.lane, channel: r.channel, state: r.last), now: now)
            try? await transport.deleteChannel(r.channel, grant: state.channelGrants[r.channel], bundle: r.lane.bundle,
                                               env: r.lane.env)
        }
        planner.running = [:]
        state.running = [:]
        state.badTokens = []
        state.badGrants = []
        // Spare channels too: the next start makes a new one.
        for (key, channel) in state.channels {
            let parts = key.split(separator: " ")
            guard parts.count == 2, let env = APNsEnvironment(rawValue: String(parts[1])) else { continue }
            try? await transport.deleteChannel(channel, grant: state.channelGrants[channel], bundle: String(parts[0]), env: env)
        }
        state.channels = [:]
        state.channelGrants = [:]
        state.save(stateURL)
    }
}
