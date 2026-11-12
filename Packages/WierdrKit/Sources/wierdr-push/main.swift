// wierdr-push: drives Wierdr's agents Live Activity from this Mac's herdr-core.
//
//   wierdr-push [--hc PATH] [run]   the daemon (scripts/push-agent.sh installs it in launchd)
//   wierdr-push [--hc PATH] status  config, devices, channels, the running activity, the summary now
//   wierdr-push [--hc PATH] reset   end the running activity and forget it (and refused tokens)
//
// Config: ~/.config/wierdr/push.json (`PushConfig`), state: ~/.config/wierdr/push-state.json.
// Devices register themselves in the core's `wierdr-push` document when Wierdr connects.
import Foundation
import HerdrCore
import WierdrActivity
import WierdrModel
import WierdrPush

setvbuf(stdout, nil, _IOLBF, 0)

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

func say(_ s: String) { print("\(stamp()) \(s)") }

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("wierdr-push: \(s)\n".utf8))
    exit(1)
}

var hcPath: String?
var command = "run"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--hc": hcPath = args.isEmpty ? nil : args.removeFirst()
    case "run", "status", "reset": command = a
    case "-h", "--help", "help":
        print("usage: wierdr-push [--hc PATH] [run|status|reset]")
        exit(0)
    default: fail("unknown argument \(a)")
    }
}

func connect() async throws -> CoreConnection {
    let c = CoreConnection(transport: try ProcessTransport(executable: hcPath.map { URL(fileURLWithPath: $0) }))
    try await c.start()
    return c
}

@MainActor
func makePusher() throws -> Pusher {
    let config = try PushConfig.load()
    let host = config.host ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let pusher = Pusher(apns: APNsClient(signer: try config.signer()), host: host)
    pusher.log = say
    return pusher
}

@MainActor
func status() async throws {
    let config = try? PushConfig.load()
    print("config: \(config.map { "key \($0.keyID), team \($0.teamID), \($0.keyFile)" } ?? "missing (\(PushConfig.defaultURL.path))")")
    if let config { _ = try config.signer(); print("key: readable") }
    let state = PushState.load()
    print("channels: \(state.channels.isEmpty ? "none" : state.channels.map { "\($0.key) → \($0.value)" }.sorted().joined(separator: ", "))")
    for r in state.running.values {
        let age = Int(Date().timeIntervalSince1970 - r.startedAt) / 60
        print("running: \(r.lane.key), \(age) min, on \(r.devices.count) device(s): \(ActivitySummary.line(r.last))")
    }
    if state.running.isEmpty { print("running: nothing") }
    if !state.badTokens.isEmpty { print("refused tokens: \(state.badTokens.count)") }
    let c = try await connect()
    let doc = try await c.getDoc(PushRegistry.documentName)
    let registry = doc.value == .null ? PushRegistry() : PushRegistry.decode(try JSONEncoder().encode(doc.value))
    for (id, d) in registry.devices.sorted(by: { $0.key < $1.key }) {
        let when = Date(timeIntervalSince1970: d.updated)
        print("device: \(d.name) \(d.bundle) \(d.env) token \(d.startToken.prefix(12))… (\(id), \(when))")
    }
    if registry.devices.isEmpty { print("devices: none (open Wierdr on the iPhone, connected to this Mac)") }
    let ws = Workspace()
    let engine = WorkspaceEngine(workspace: ws, options: EngineOptions(allowWrites: false, limitsDocument: nil))
    let task = Task { @MainActor in try await engine.run(on: c) }
    let start = Date()
    while ws.phase != .live && Date().timeIntervalSince(start) < 20 { try await Task.sleep(for: .milliseconds(100)) }
    try await Task.sleep(for: .seconds(2))
    let s = ActivitySummary.state(of: ws)
    print("now: \(ActivitySummary.line(s))")
    for a in s.agents { print("  \(a.status.rawValue) \(a.title) — \(a.space) · \(a.model)") }
    task.cancel()
    await c.close()
}

Task { @MainActor in
    do {
        switch command {
        case "status":
            try await status()
        case "reset":
            let pusher = try makePusher()
            await pusher.endAll()
            say("ended")
        default:
            let pusher = try makePusher()
            let c = try await connect()
            try await pusher.run(on: c)
        }
        exit(0)
    } catch {
        fail("\(error)")
    }
}
while true { RunLoop.main.run(until: .distantFuture) }
