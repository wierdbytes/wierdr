import Foundation
import HerdrCore
import WierdrActivity
import WierdrModel

/// `~/.config/wierdr/push.json`: the APNs key that signs the pushes.
public struct PushConfig: Codable, Sendable {
    /// Path to the `.p8` key (APNs, of the team that signs the app); `~` allowed.
    public var keyFile: String
    public var keyID: String
    public var teamID: String
    /// The computer's name on the activity (default: this Mac's name).
    public var host: String?

    enum CodingKeys: String, CodingKey {
        case keyFile = "key_file", keyID = "key_id", teamID = "team_id", host
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

    public init() {}

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

/// The Mac side of the agents Live Activity: mirrors the local core's workspace
/// (read-only `WorkspaceEngine`), reads the devices from the `wierdr-push`
/// document, and pushes what the `Planner` says through APNs.
@MainActor
public final class Pusher {
    public let workspace = Workspace()
    let engine: WorkspaceEngine
    let apns: APNsClient
    let host: String
    let stateURL: URL
    var state: PushState
    var planner: Planner
    var devices: [String: PushRegistry.Device] = [:]
    var registryReadAt = Date.distantPast
    /// After an APNs failure: no pushes until then (5 s, doubling to 5 min).
    var pausedUntil = Date.distantPast
    var backoff: TimeInterval = 0
    var engineEnded: Error?
    public var log: (String) -> Void = { print($0) }

    public init(apns: APNsClient, host: String, stateURL: URL = PushState.defaultURL, settings: Planner.Settings = .init()) {
        self.apns = apns
        self.host = host
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
                let names = registry.devices.values.map { "\($0.name) (\($0.env))" }.sorted()
                log("devices: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
            }
            devices = registry.devices
        } catch {
            log("can't read \(PushRegistry.documentName): \(error)")
        }
    }

    func tick(now: Date) async {
        guard now >= pausedUntil else { return }
        let usable = devices.filter { !state.badTokens.contains($0.value.startToken) }
        await ensureChannels(for: usable)
        let summary = ActivityPayload.fitting(ActivitySummary.state(of: workspace, now: now))
        let actions = planner.step(now: now, summary: summary, host: host, devices: usable, channels: state.channels)
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
            try? await apns.deleteChannel(channel, bundle: lane.bundle, env: lane.env)
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

    /// A spare channel for every lane with devices (kept in the state file).
    func ensureChannels(for devices: [String: PushRegistry.Device]) async {
        for d in devices.values {
            guard let env = APNsEnvironment(rawValue: d.env) else { continue }
            let lane = Lane(bundle: d.bundle, env: env)
            guard state.channels[lane.key] == nil else { continue }
            do {
                let id = try await apns.createChannel(bundle: lane.bundle, env: lane.env)
                state.channels[lane.key] = id
                state.save(stateURL)
                log("new channel for \(lane.key): \(id)")
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
                                                channel: channel, alert: alert, stale: stale, now: now)
            do {
                try await apns.start(token: token, bundle: lane.bundle, env: lane.env, payload: payload)
                log("start on \(devices[device]?.name ?? device): \(Self.describe(s))")
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
            let payload = ActivityPayload.update(state: s, alert: alert, stale: stale, now: now)
            do {
                try await apns.broadcast(channel: channel, bundle: lane.bundle, env: lane.env, payload: payload,
                                         priority: priority, expiration: stale)
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
            let payload = ActivityPayload.end(state: s, dismissal: now.addingTimeInterval(-1), now: now)
            do {
                try await apns.broadcast(channel: channel, bundle: lane.bundle, env: lane.env, payload: payload,
                                         priority: 10, expiration: now.addingTimeInterval(3600))
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

    /// Ends every running activity now (`wierdr-push reset`).
    public func endAll() async {
        let now = Date()
        for r in planner.running.values {
            _ = await perform(.end(lane: r.lane, channel: r.channel, state: r.last), now: now)
            try? await apns.deleteChannel(r.channel, bundle: r.lane.bundle, env: r.lane.env)
        }
        planner.running = [:]
        state.running = [:]
        state.badTokens = []
        state.save(stateURL)
    }
}
