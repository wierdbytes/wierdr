import Foundation
import HerdrCore

// MARK: ls

func listCommand(_ options: Options, _ args: [String]) async throws {
    let connection = try await connect(options)
    defer { Task { await connection.close() } }
    let list = try await connection.listTerminals(all: args.contains("--all"))
    var rows = [["ADDRESS", "NAME", "STATE", "STATUS", "TITLE", "SPACE", "TAB"]]
    for t in list.terminals {
        rows.append([
            t.address, t.name ?? "", t.isLive ? "live" : "\(t.state) (\(t.reason ?? "?"))",
            t.status.map { [$0.app, $0.state].compactMap { $0 }.joined(separator: ":") } ?? "",
            String(t.title.prefix(40)), t.labels["herdr.space"] ?? "", t.labels["herdr.tab"] ?? "",
        ])
    }
    printTable(rows)
    if list.hiddenFinished > 0 { print("(\(list.hiddenFinished) finished hidden; --all shows them)") }
    for m in list.machines { print("machine \(m.name): \(m.state) \(m.target) \(m.version)") }
}

func printTable(_ rows: [[String]]) {
    guard let header = rows.first else { return }
    let widths = header.indices.map { i in rows.map { $0[i].count }.max() ?? 0 }
    for row in rows {
        let line = row.enumerated().map { i, cell in
            i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
        }
        print(line.joined(separator: "  "))
    }
}

// MARK: doc

func docCommand(_ options: Options, _ args: [String]) async throws {
    var name = "herdr-app"
    var machine: String?
    var it = args.makeIterator()
    while let a = it.next() {
        if a == "--on" { machine = it.next() } else { name = a }
    }
    let connection = try await connect(options)
    defer { Task { await connection.close() } }
    let doc = try await connection.getDoc(name, on: machine)
    print("// \(machine.map { "\($0)/" } ?? "")\(name) version \(doc.version)")
    print(doc.value.jsonString(pretty: true))
}

// MARK: events

func eventsCommand(_ options: Options, _ args: [String]) async throws {
    var params = SubscribeParams()
    var json = false
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--terminal": params.terminal = it.next()
        case "--label":
            guard let kv = it.next(), let eq = kv.firstIndex(of: "=") else { throw CLIError.usage("--label K=V") }
            params.labels = (params.labels ?? [:]).merging([String(kv[..<eq]): String(kv[kv.index(after: eq)...])]) { $1 }
        case "--json": json = true
        default: throw CLIError.usage("unknown events option \(a)")
        }
    }
    let connection = try await connect(options)
    let subscription = try await connection.subscribe(params)
    print("snapshot seq \(subscription.seq): \(subscription.terminals.count) terminals on channel \(subscription.channel)")
    for await event in subscription.events {
        if json {
            print(event.params.jsonString())
        } else {
            print(String(format: "%6llu %-8@ %@", event.seq, (event.terminal ?? event.machine ?? "-") as NSString,
                         describe(event.kind) as NSString))
        }
    }
    print("subscription ended: \(await connection.waitUntilClosed())")
}

func describe(_ kind: CoreEvent.Kind) -> String {
    switch kind {
    case .created(let t): "created \(t.argv.joined(separator: " "))"
    case .lost(let e): "lost \(e.reason ?? "")"
    case .restarted: "restarted"
    case .keep(let k): "keep \(k)"
    case .finished(let e): "finished \(e.reason ?? "") code=\(e.exitCode.map(String.init) ?? "-")"
    case .removed: "removed"
    case .status(let s, _, _): "status \(s.map { "\($0.state) \($0.msg ?? "")" } ?? "cleared")"
    case .turn(let t, let s): "turn \(t) \(s ?? "")"
    case .title(let t): "title \(t)"
    case .labels(let l, _): "labels \(l.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
    case .size(let c, let r): "size \(c)x\(r)"
    case .foreground(let f): "foreground \(f.map { "\($0.name) \($0.cwd)" } ?? "none")"
    case .doc(let name, let version): "doc \(name) v\(version)"
    case .heartbeat: "heartbeat"
    case .missed(let ts): "missed (\(ts.count) terminals)"
    case .unknown(let type, let data): "\(type) \(data.jsonString())"
    }
}

// MARK: attach

func attachCommand(_ options: Options, _ args: [String]) async throws {
    var terminal: String?
    var interactive = false
    var history = 0
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--interactive", "-i": interactive = true
        case "--observe": interactive = false
        case "--history": history = it.next().flatMap { Int($0) } ?? 0
        default: terminal = a
        }
    }
    guard let terminal else { throw CLIError.usage("attach needs a terminal") }
    let tty = isatty(STDIN_FILENO) == 1
    if interactive && !tty { throw CLIError.usage("--interactive needs a terminal on stdin") }

    let connection = try await connect(options)
    let record = try await connection.getTerminal(terminal)
    let size = windowSize() ?? (record.cols, record.rows)
    let stream = try await connection.attach(AttachParams(
        terminal: terminal, cols: UInt16(clamping: size.0), rows: UInt16(clamping: size.1),
        history: history, observe: !interactive, resizeNotifications: !interactive))

    var restore: termios?
    if interactive {
        restore = enterRawMode()
        FileHandle.standardError.write(Data("[attached to \(terminal); ctrl-] detaches]\r\n".utf8))
        forwardInput(to: stream)
        watchWindowSize(stream)
    }
    var ending: JSONValue?
    for await event in stream.output {
        switch event {
        case .data(let bytes):
            FileHandle.standardOutput.write(bytes)
            stream.consumed(bytes.count)
        case .resize: break
        case .closed(let reason): ending = reason
        }
    }
    if var restore { tcsetattr(STDIN_FILENO, TCSANOW, &restore) }
    FileHandle.standardError.write(Data("\r\n[detached: \(ending?.jsonString() ?? "by us")]\n".utf8))
    await connection.close()
}

func windowSize() -> (Int, Int)? {
    var w = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 else { return nil }
    return (Int(w.ws_col), Int(w.ws_row))
}

func enterRawMode() -> termios? {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    return original
}

/// Stdin → DATA; ctrl-] (0x1d) detaches.
func forwardInput(to stream: AttachStream) {
    FileHandle.standardInput.readabilityHandler = { handle in
        let bytes = handle.availableData
        if bytes.isEmpty {
            handle.readabilityHandler = nil
            stream.close()
            return
        }
        if let i = bytes.firstIndex(of: 0x1D) {
            stream.send(bytes[bytes.startIndex..<i])
            handle.readabilityHandler = nil
            stream.close()
            return
        }
        stream.send(bytes)
    }
}

nonisolated(unsafe) var windowSource: DispatchSourceSignal?

func watchWindowSize(_ stream: AttachStream) {
    signal(SIGWINCH, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGWINCH)
    source.setEventHandler {
        if let (cols, rows) = windowSize() { stream.resize(cols: cols, rows: rows) }
    }
    source.resume()
    windowSource = source
}

// MARK: call

func callCommand(_ options: Options, _ args: [String]) async throws {
    guard let method = args.first else { throw CLIError.usage("call needs a method") }
    let params = try args.count > 1 ? JSONValue(parsing: args[1]) : .object([:])
    let connection = try await connect(options)
    defer { Task { await connection.close() } }
    do {
        let result = try await connection.call(method, params: params)
        print(result.jsonString(pretty: true))
    } catch let error as CoreError {
        print("error \(error.code) [\(error.kind ?? "-")]: \(error.message)\(error.hint.map { " (hint: \($0))" } ?? "")")
        throw error
    }
}
