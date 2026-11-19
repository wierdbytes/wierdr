// wierdrd: Wierdr's daemon on the Mac. Drives Wierdr's agents Live Activity from this Mac's
// herdr-core.
//
//   wierdrd [--hc PATH] [run]   the daemon (a Homebrew service: `brew services start wierdrd`;
//                               from source: scripts/wierdrd.sh)
//   wierdrd [--hc PATH] status  config, devices, channels, the running activity, the summary now
//   wierdrd [--hc PATH] reset   end the running activity and forget it (and refused tokens)
//   wierdrd --version
//
// Config: ~/.config/wierdr/push.json (`PushConfig`; without it, the relay), state:
// ~/.config/wierdr/push-state.json, the key the pushes are sealed with:
// ~/.config/wierdr/seal-key (made at the first run).
// Devices register themselves in the core's `wierdr-push` document when Wierdr connects,
// and take the seal key from its `wierdr-push-seal` document, which the daemon writes.
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
    FileHandle.standardError.write(Data("wierdrd: \(s)\n".utf8))
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
        print("usage: wierdrd [--hc PATH] [run|status|reset] | wierdrd --version")
        exit(0)
    case "-v", "--version", "version":
        print(wierdrdVersion)
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
    let pusher = Pusher(transport: try config.transport(), host: host, seal: try ActivitySealKey.loadOrCreate())
    pusher.log = say
    return pusher
}

@MainActor
func status() async throws {
    print("wierdrd \(wierdrdVersion)")
    let config: PushConfig?
    do { config = try PushConfig.load() } catch { config = nil; print("config: \(error)") }
    if let config { print("config: \(config.summary)") }
    if let config, config.relay == nil { _ = try config.signer(); print("key: readable") }
    let state = PushState.load()
    print("channels: \(state.channels.isEmpty ? "none" : state.channels.map { "\($0.key) → \($0.value)" }.sorted().joined(separator: ", "))")
    for r in state.running.values {
        let age = Int(Date().timeIntervalSince1970 - r.startedAt) / 60
        print("running: \(r.lane.key), \(age) min, on \(r.devices.count) device(s): \(ActivitySummary.line(r.last))")
    }
    if state.running.isEmpty { print("running: nothing") }
    if !state.badTokens.isEmpty { print("refused tokens: \(state.badTokens.count)") }
    if let oldest = state.pendingDeletes.map(\.since).min() {
        let since = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: oldest))
        print("channels to delete: \(state.pendingDeletes.count) (queued since \(since); the daemon tries again)")
    }
    let seal = (try? Data(contentsOf: ActivitySealKey.defaultURL)).flatMap { ActivitySealKey(base64: String(decoding: $0, as: UTF8.self)) }
    let c = try await connect()
    let sealDoc = try await c.getDoc(SealDocument.documentName)
    let published = sealDoc.value == .null ? nil : SealDocument.decode(try JSONEncoder().encode(sealDoc.value))
    if let seal {
        print("seal: key \(seal.kid) (\(ActivitySealKey.defaultURL.path)), \(published?.kid == seal.kid ? "published" : "not published yet") in \(SealDocument.documentName)")
    } else {
        print("seal: no key yet (the daemon makes \(ActivitySealKey.defaultURL.path) when it starts)")
    }
    let doc = try await c.getDoc(PushRegistry.documentName)
    let registry = doc.value == .null ? PushRegistry() : PushRegistry.decode(try JSONEncoder().encode(doc.value))
    let now = Date()
    for (id, d) in registry.devices.sorted(by: { $0.key < $1.key }) {
        let when = Date(timeIntervalSince1970: d.updated)
        let key = d.sealKid == nil ? "no key" : d.sealKid == seal?.kid ? "key" : "old key \(d.sealKid!)"
        print("device: \(d.name) \(d.bundle) \(d.env) token \(d.startToken.prefix(12))…, \(key), "
            + "\(state.grantSummary(for: d, now: now)) (\(id), \(when))")
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
            say("wierdrd \(wierdrdVersion)")
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
