# HerdrCore: the herdr-core client

`HerdrCore` (`Packages/WierdrKit/Sources/HerdrCore`) speaks the herdr-core
API (`hc connect`, protocol generation 1, verified against hc 0.1.20) over any
byte pipe. It is platform-neutral (Foundation + Synchronization). Protocol
reference: `hc schema` / the herdr-core `schema/README.md`. This doc covers the
Swift API and what was verified live.

## Files

| File | What |
|---|---|
| `CoreTransport.swift` | The byte-pipe protocol (implemented by `ProcessTransport`, `SSHTransport`) |
| `CoreConnection.swift` | Handshake, lifecycle, read loop, JSON-RPC calls, `subscribe`, `attach` |
| `CoreConnection+Methods.swift` | Typed wrappers (`listTerminals`, `getDoc`, ...) |
| `AttachStream.swift` | One viewer of a terminal (`AttachEvent`, input, resize, credit) |
| `Events.swift` | `CoreEvent`, `EventSubscription`, `TerminalEnd`, `Terminal.apply(_:)` |
| `Channels.swift` | Outbound queue, channel sinks, credit batching (internal) |
| `Frames.swift` | `Frame`, `FrameKind`, `FrameDecoder` |
| `CoreError.swift` | `CoreError`, `DocConflict`, `ConnectionError` |
| `JSON/*` | `JSONValue`, `JSONObject` (ordered), parser, writer, decoder |
| `Models/*` | `Terminal`, `Foreground`, `TerminalStatus`, results, params |
| `ProcessTransport.swift` | macOS only: spawns `hc connect` |

## Connecting

```swift
import HerdrCore

let transport = try ProcessTransport()          // macOS; on iOS: SSHTransport (HerdrSSH)
let core = CoreConnection(transport: transport)
let hello = try await core.start()              // HelloResult: core.name, version, features, methods
// ... use it ...
await core.close()
```

`CoreConnection` is a `Sendable` final class (internal `Mutex`); call it from
the main actor or any task. `start()` sends `hello {framed: true, generation: 1,
features: CoreConnection.clientFeatures}` as one plain JSON line, reads the
plain reply line, then everything is framed. If the core refuses (e.g.
`unsupported_generation`), `start()` throws the `CoreError` and the connection
is closed.

Lifecycle:

```swift
core.state                       // .idle / .connecting / .open(HelloResult) / .closed(ConnectionError)
for await s in core.states() { } // current state, then changes; finishes after .closed
let why = await core.waitUntilClosed()   // ConnectionError: .closed (we closed) or .disconnected(msg), ...
core.supports("automatic_input") // hello feature check
```

A closed connection stays closed. To reconnect, build a new transport and a new
`CoreConnection`, `start()`, subscribe, and reload snapshots/documents (`seq`
restarts with each core process). On close/drop: all pending calls throw the
`ConnectionError`, event streams finish, attach streams end with
`.closed(reason: {"reason":"disconnected","message":...})`.

## Calls

```swift
// Untyped
let r: JSONValue = try await core.call("terminal.list", params: ["all": true])
// Typed: any Encodable params, any Decodable result
let t: Terminal = try await core.call("terminal.get", ["terminal": "t7"] as JSONValue)
```

Calls run concurrently (ids are matched). Task cancellation abandons the call
(throws `CancellationError`) and sends `$/cancelRequest` to the core.

Errors:
- `CoreError` (`code`, `message`, `kind` from `data.kind`, `hint`, `data`):
  the core refused, e.g. `kind == "not_found"`, `"unavailable"` (kept terminal
  waiting for its new shell; retry after `restarted`), `"invalid_params"`,
  `"unknown_method"`. Helpers: `isNotFound`, `isConflict`, `isUnavailable`.
- `DocConflict` (`name`, `expectedVersion`, `currentVersion?`, `error`): only from `setDoc`.
- `ConnectionError`: `.notStarted`, `.alreadyStarted`, `.closed`,
  `.disconnected(String)`, `.protocolViolation(String)`, `.decoding(method:message:)`.

Typed wrappers (terminal = `t7`, a name, or `machine/t7`):

```swift
func listTerminals(all: Bool = false, labels: [String: String] = [:]) async throws -> TerminalList // terminals, hiddenFinished, machines
func getTerminal(_ terminal: String) async throws -> Terminal
func runTerminal(_ params: RunParams) async throws -> RunResult             // .terminal, .output?, .wait?
func killTerminal(_ terminal: String) async throws -> Terminal
func removeTerminal(_ terminal: String) async throws -> String              // removed address
func labelTerminal(_ terminal: String, _ labels: [String: String]) async throws -> Terminal  // "" value removes
func keepTerminal(_ terminal: String, _ keep: Bool) async throws -> Terminal
func readTerminal(_ terminal: String, lines: Int = 0) async throws -> ReadResult
func sendText(_ terminal: String, _ text: String, force: Bool = false) async throws -> SendResult // paste + Enter
func sendKeys(_ terminal: String, _ keys: [String]) async throws -> KeysResult  // "enter", "ctrl+c", ...
func interrupt(_ terminal: String, timeout: Double? = nil) async throws -> InterruptResult
func getDoc(_ name: String, on machine: String? = nil) async throws -> Document  // value: JSONValue, version: UInt64
func setDoc(_ name: String, value: JSONValue, version: UInt64, on machine: String? = nil) async throws -> UInt64
func listMachines() async throws -> [Machine]
func exec(_ params: ExecParams) async throws -> ExecResult                  // stdout/stderr already base64-decoded
func readFile(_ path: String, cwd: String? = nil, offset: Int? = nil, limit: Int? = nil, on machine: String? = nil) async throws -> FileReadResult
func listTemplates() async throws -> [TemplateInfo]
func serverStatus() async throws -> ServerStatus
```

Anything else: `call(_:params:)`.

### Documents

```swift
let doc = try await core.getDoc("herdr-app")          // unwritten: (.null, 0)
var value = doc.value
value["spaces"] = .array(...)                          // edits keep key order
do {
    try await core.setDoc("herdr-app", value: value, version: doc.version)
} catch let conflict as DocConflict {
    // someone else wrote first: re-read, re-apply, retry
}
// Writing .null deletes the value; the version is kept.
```

## Records

`Terminal` decodes every field in the schema and is tolerant: only `address`
is required; anything missing or ill-typed falls back to a default (so newer or
older cores never break the list). Fields (all `var`): `address`, `name?`,
`argv`, `cwd`, `state` (`live`/`finished`), `labels`, `createdMs`,
`finishedMs?`, `cols`, `rows`, `pid?`, `foreground?` (`Foreground`: `pid`,
`name`, `argv`, `cwd`), `title`, `status?` (`TerminalStatus`: `state`, `app?`,
`kind?`, `msg?`, `progress?`, `title?`), `records?` (`JSONValue`, opaque map of
statuses), `reported`, `statusMs?`, `turn`, `keep`, `parent?`, `reason?`,
`exitCode?`, `signal?`, `identity`, `screen?`, `template?`, `notify`, `rm`,
`dieWithParent`, `pasteGapMs?`, `stop?`, `submit?`, `firstMessage?`.
Helpers: `id` (= address), `isLive`, `isFinished`, `machine` (`lf` for
`lf/t1`, nil here), `localAddress` (`t1`).

herdr-app's labels on terminals: `herdr.space`, `herdr.tab`, `herdr.seen`,
`where`, and agent labels `agent.*` (`agent.app`, `agent.model`, ...).

## Events

```swift
let sub = try await core.subscribe()                 // or SubscribeParams(terminal:, childrenOf:, labels:)
var terminals = Dictionary(uniqueKeysWithValues: sub.terminals.map { ($0.address, $0) })
var seq = sub.seq
// Subscribe first, then read documents (getDoc).
for await e in sub.events {
    switch e.kind {
    case .heartbeat: continue                         // alive; e.seq is current
    case .missed(let fresh):                          // fell behind: replace everything, refetch docs
        terminals = Dictionary(uniqueKeysWithValues: fresh.map { ($0.address, $0) })
        seq = e.seq
        continue
    default: break
    }
    guard e.seq > seq else { continue }               // already in the snapshot
    seq = e.seq
    switch e.kind {
    case .created(let t), .restarted(let t): terminals[t.address] = t
    case .removed: terminals[e.terminal!] = nil
    case .labels(_, let record?): terminals[record.address] = record  // newly matches a label filter
    case .doc(let name, let version): break          // refetch getDoc(name, on: e.machine)
    case .unknown: break
    default: if let a = e.terminal { terminals[a]?.apply(e.kind) }
    }
}
sub.cancel()   // CLOSE; the stream finishes
```

`CoreEvent`: `seq`, `terminal?` (`t7` / `lf/t7`), `machine?` (doc events from
an added machine), `kind`, `params` (raw). `Kind`: `created(Terminal)`,
`lost(TerminalEnd)`, `restarted(Terminal)`, `keep(Bool)`,
`finished(TerminalEnd)`, `removed`, `status(status:records:reported:)`,
`turn(turn:state:)`, `title(String)`, `labels(_, record:)`,
`size(cols:rows:)`, `foreground(Foreground?)`, `doc(name:version:)`,
`heartbeat`, `missed(terminals:)`, `unknown(type:data:)`. A known type whose
data does not decode is delivered as `.unknown` rather than dropped.
`Terminal.apply(_:)` applies a terminal event per the core's rules (finished:
state `finished`, foreground dropped; lost: pid and foreground dropped; ...).

## Attach

```swift
let stream = try await core.attach(AttachParams(
    terminal: "t7", cols: 120, rows: 40,
    history: 0, observe: false,
    display: Display(fg: "#d0d0d0", bg: "#1e1e1e", cursor: "#ffffff", cell: .init(width: 9, height: 18)),
    resizeNotifications: false, resumed: false))

Task {
    for await event in stream.output {
        switch event {
        case .data(let bytes):
            terminalView.feed(bytes)          // first the paint of the current screen, then raw output
            stream.consumed(bytes.count)      // REQUIRED: returns flow-control credit
        case .resize(let cols, let rows):     // observers with confirmed resizeNotifications only
            terminalView.resize(cols, rows)   // apply before the following data (a repaint)
        case .closed(let reason):             // last event
            // nil: we detached. {"reason":"exited","exit_code":0,"signal":null,"finished_ms":...}
            // kept terminal lost: reason "signaled"/...: wait for `restarted`, attach again.
            // {"reason":"disconnected","message":...}: the connection dropped.
            break
        }
    }
}
stream.send(Data("ls\r".utf8))          // keyboard (DATA). Takes size ownership.
stream.sendAutomatic(reply)             // emulator-generated query answers (AUTOMATIC_INPUT when negotiated, else DATA)
stream.resize(cols: 100, rows: 30)
stream.focus(true)                      // gaining focus makes this the active viewer
stream.facts(display)                   // colors / cell size changed
stream.close()                          // CLOSE; output ends with .closed(reason: nil) when the core confirms
```

`AttachStream` (`Sendable` class): `channel`, `terminal` (record at attach),
`automaticInput` (hello feature AND attach reply both true), `resizeNotifications`
(confirmed by the core), `observe`, `isClosed`, `output: AsyncStream<AttachEvent>`
(single consumer). All methods are synchronous, non-blocking, ordered, and
no-ops after close.

Flow control: the core starts each stream with 256 KiB of credit and sends no
more until we return CREDIT. Call `consumed(n)` after the emulator has taken
the bytes; credits are batched (sent at >= 16 KiB pending, far below the
window, so a stream never stalls on batching). If the UI stops consuming, the
core buffers up to 4 MiB, then sends a fresh repaint instead of the backlog.
Our side buffers whatever arrives (bounded by the window), so the read loop
never blocks on a slow view.

## JSONValue

`enum JSONValue { null, bool, int(Int64), uint(UInt64) (only > Int64.max), double(Double), string, array, object(JSONObject) }`.
- Numbers keep their kind: `4.0` stays a double and is written `4.0`; `4` stays an int; `UInt64.max` round-trips.
- `JSONObject` keeps key order (existing keys keep their place, new keys go
  last, `obj[k] = nil` removes). Equality ignores order.
- `JSONValue(data:)`, `JSONValue(parsing:)`, `.data(pretty:)`, `.jsonString(pretty:)`,
  subscripts `v["key"]` (get/set) and `v[0]`, accessors `.string .int .int64 .uint64 .double .bool .object .array .isNull`,
  literals (`["a": 1, "b": [true, "x"]]`; write `.null` for null: it is deliberately
  not `ExpressibleByNilLiteral`, so `nil` always means "absent").
- `value.decode(T.self)` decodes models straight from the parsed value; `JSONValue(encoding:)` encodes.

## Live protocol findings (hc 0.1.20)

- Framed events: `events.subscribe` returns `channel`; notifications arrive on
  that channel as DATA frames carrying newline-terminated JSON-RPC
  notification lines (`event` / `heartbeat` / `missed`). A line can be split
  across frames (16 KiB chunks) and a frame can hold several lines. Nothing
  arrives on channel 0 except replies.
- Event channels are flow-controlled like attach streams (256 KiB window, the
  core waits for CREDIT). HerdrCore credits event bytes itself as it parses them.
- Event channels open unpaused, so an event can arrive before the subscribe
  reply. Attach channels open paused (output only after the reply). HerdrCore
  buffers frames for not-yet-known channels and routes them when the reply arrives.
- The core's CLOSE reason is the bare object
  `{"exit_code":0,"finished_ms":...,"reason":"exited","signal":null}` (no wrapper);
  the CLOSE acknowledging our CLOSE is empty.
- `terminal.attach` confirms `resize_notifications: true` only for `observe`
  viewers; a normal viewer gets `false` even when it asked.
- `automatic_input: true` is returned for local terminals on 0.1.20.
- First paint starts with `CAN` + a mode reset (`ESC[!p`, ...), then the screen,
  then `ESC[?9001l` (win32-input-mode off).
- Documents come back with object keys **sorted** (the core stores serde_json
  maps), whatever order they were written in. Number kinds survive
  (`4.0` stays `4.0`, `0.9999997615814208` exact). So read-modify-write with
  `JSONValue` produces minimal diffs relative to what the core returns.
- doc conflict message: `document "x" is at version 6, not 99` (kind
  `conflict`, hint `read doc.get and retry with its version`); `DocConflict.currentVersion` parses it.
- `doc.set` value null keeps the version; `doc.get` of a never-written name is `{value: null, version: 0}`.
- `terminal.list` has `machines` (same shape as `machine.list`); terminals on
  added machines appear as `lf/t1`. A 0.1.14 remote's records have the same fields.
- `foreground.argv` may contain empty strings (`["pi","",""]`). `records` is
  omitted when empty. `status_ms` can be set while `status` is null.
- Clients' `hello.features` are only used for core-to-core links today; we
  still advertise `framed attach events resize_notifications automatic_input`.
- Careful when testing: `hc run` from inside a herdr terminal makes it a child
  of that terminal (notes get typed into the parent). Use `noParent: true`.

## wierdr-cli

```
wierdr-cli [--hc PATH] ls [--all]
wierdr-cli doc [NAME] [--on MACHINE]          # default herdr-app
wierdr-cli events [--terminal T] [--label K=V] [--json]
wierdr-cli attach T [--interactive] [--history N]   # observe by default; ctrl-] detaches
wierdr-cli call METHOD [JSON]
```

Transports are built in `makeTransport(_:)` (`Sources/wierdr-cli/Transport.swift`);
add `--ssh user@host` there.

## Tests

```
cd Packages/WierdrKit
swift test --scratch-path /tmp/wierdr-core-build --filter HerdrCoreTests
WIERDR_LIVE=1 swift test --scratch-path /tmp/wierdr-core-build --filter HerdrCoreTests   # against the local core
```

Live tests only touch scratch terminals they start (label `wierdr.test=1`,
always killed and removed) and the scratch doc `wierdr-test`; `herdr-app` is read only.
