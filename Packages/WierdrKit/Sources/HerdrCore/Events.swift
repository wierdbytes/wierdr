import Foundation

/// One notification from an event subscription.
///
/// Apply terminal events to your snapshot with `Terminal.apply(_:)`, drop
/// events whose `seq` is not above the latest snapshot's (`missed` brings a
/// fresh one), and refetch documents after `doc` events and after `missed`.
public struct CoreEvent: Sendable {
    /// Rises by one per event; heartbeats repeat the current value. Restarts with each core process.
    public var seq: UInt64
    /// The terminal it concerns (`t7` or `lf/t7`); nil for doc, heartbeat and missed.
    public var terminal: String?
    /// For `doc` events from an added machine: this core's name for it.
    public var machine: String?
    public var kind: Kind
    /// The notification's whole `params` (for logging, or fields not modeled yet).
    public var params: JSONValue

    public enum Kind: Sendable {
        /// A new terminal (the whole record). Also re-sent when an added machine's line comes back.
        case created(Terminal)
        /// A kept terminal lost its program; it stays live waiting for a new shell.
        case lost(TerminalEnd)
        /// A kept terminal got its new shell: replace the record and reattach.
        case restarted(Terminal)
        case keep(Bool)
        /// The program ended for good.
        case finished(TerminalEnd)
        /// The record is gone.
        case removed
        /// Root status (nil when cleared), every record by key, and whether it ever reported.
        case status(status: TerminalStatus?, records: JSONValue?, reported: Bool)
        /// A turn ended: the counter after it, and the word it ended on.
        case turn(turn: UInt64, state: String?)
        case title(String)
        /// All labels now; `record` when the terminal newly matches a label filter.
        case labels([String: String], record: Terminal?)
        case size(cols: Int, rows: Int)
        /// What runs in it now, nil when nothing (finished/lost).
        case foreground(Foreground?)
        /// A document changed (no value; call `getDoc`, with `on: machine` when set).
        case doc(name: String, version: UInt64)
        /// Alive; `seq` is current.
        case heartbeat
        /// You fell behind: here is a fresh snapshot; refetch documents too.
        case missed(terminals: [Terminal])
        /// A type this client does not know, or a known one whose data did not decode.
        case unknown(type: String, data: JSONValue)
    }

    /// Parses one notification line (`{"jsonrpc":"2.0","method":...,"params":...}`).
    /// Never fails for well-formed JSON-RPC: unknown shapes become `.unknown`.
    static func parse(_ message: JSONValue) -> CoreEvent? {
        guard let method = message["method"]?.string else { return nil }
        let params = message["params"] ?? .null
        let seq = params["seq"]?.uint64 ?? 0
        var event = CoreEvent(seq: seq, terminal: params["terminal"]?.string, machine: params["machine"]?.string,
                              kind: .unknown(type: method, data: params), params: params)
        switch method {
        case "heartbeat":
            event.kind = .heartbeat
        case "missed":
            if let terminals = try? (params["terminals"] ?? .array([])).decode([Terminal].self) {
                event.kind = .missed(terminals: terminals)
            }
        case "event":
            let type = params["type"]?.string ?? ""
            let data = params["data"] ?? .null
            event.kind = Self.kind(type: type, data: data) ?? .unknown(type: type, data: data)
        default:
            break
        }
        return event
    }

    private static func kind(type: String, data: JSONValue) -> Kind? {
        switch type {
        case "created": return (try? data.decode(Terminal.self)).map(Kind.created)
        case "restarted": return (try? data.decode(Terminal.self)).map(Kind.restarted)
        case "lost": return .lost(TerminalEnd(data))
        case "finished": return .finished(TerminalEnd(data))
        case "removed": return .removed
        case "keep": return data["keep"]?.bool.map(Kind.keep)
        case "status":
            let status = data["status"].flatMap { $0.isNull ? nil : try? $0.decode(TerminalStatus.self) }
            let records = data["records"].flatMap { $0.isNull ? nil : $0 }
            return .status(status: status, records: records, reported: data["reported"]?.bool ?? false)
        case "turn":
            guard let turn = data["turn"]?.uint64 else { return nil }
            return .turn(turn: turn, state: data["state"]?.string)
        case "title": return data["title"]?.string.map(Kind.title)
        case "labels":
            guard let labels = try? (data["labels"] ?? .object([:])).decode([String: String].self) else { return nil }
            let record = data["record"].flatMap { try? $0.decode(Terminal.self) }
            return .labels(labels, record: record)
        case "size":
            guard let cols = data["cols"]?.int, let rows = data["rows"]?.int else { return nil }
            return .size(cols: cols, rows: rows)
        case "foreground":
            if data.isNull { return .foreground(nil) }
            return (try? data.decode(Foreground.self)).map { .foreground($0) }
        case "doc":
            guard let name = data["name"]?.string else { return nil }
            return .doc(name: name, version: data["version"]?.uint64 ?? 0)
        default: return nil
        }
    }
}

/// How a program ended (`finished`, `lost`, and attach CLOSE reasons).
public struct TerminalEnd: Sendable, Hashable {
    /// `exited`, `killed`, `server_stop`, `host_shutdown`, `holder_lost`,
    /// `stopped_by_restart`; for kept terminals also `signaled`.
    public var reason: String?
    public var exitCode: Int?
    public var signal: Int?
    public var finishedMs: UInt64?

    public init(reason: String? = nil, exitCode: Int? = nil, signal: Int? = nil, finishedMs: UInt64? = nil) {
        self.reason = reason
        self.exitCode = exitCode
        self.signal = signal
        self.finishedMs = finishedMs
    }

    /// From `{reason, exit_code, signal, finished_ms}`.
    public init(_ json: JSONValue) {
        reason = json["reason"]?.string
        exitCode = json["exit_code"]?.int
        signal = json["signal"]?.int
        finishedMs = json["finished_ms"]?.uint64
    }
}

extension Terminal {
    /// Applies a terminal event to this record, as the README describes.
    /// `created`/`restarted` replace the record; `removed`, `doc`, `heartbeat`,
    /// `missed` and unknown kinds leave it unchanged (handle them at list level).
    public mutating func apply(_ kind: CoreEvent.Kind) {
        switch kind {
        case .created(let t), .restarted(let t):
            self = t
        case .lost(let end):
            reason = end.reason
            exitCode = end.exitCode
            signal = end.signal
            finishedMs = end.finishedMs
            pid = nil
            foreground = nil
        case .finished(let end):
            state = "finished"
            reason = end.reason
            exitCode = end.exitCode
            signal = end.signal
            finishedMs = end.finishedMs
            foreground = nil
        case .keep(let k):
            keep = k
        case .status(let s, let r, let rep):
            // The event carries no `status_ms`; the core sets it when the state
            // changes, and so do we, with when we heard of it.
            if s?.state != status?.state { statusMs = UInt64(Date().timeIntervalSince1970 * 1000) }
            status = s
            records = r
            reported = rep
        case .turn(let t, _):
            turn = t
        case .title(let t):
            title = t
        case .labels(let l, _):
            labels = l
        case .size(let c, let r):
            cols = c
            rows = r
        case .foreground(let f):
            foreground = f
        case .removed, .doc, .heartbeat, .missed, .unknown:
            break
        }
    }
}

/// A live event subscription (`events.subscribe`): the snapshot it started
/// from and the notifications after it, on its own framed channel.
///
/// `events` finishes when the subscription is cancelled, the core closes the
/// channel, or the connection ends (watch `CoreConnection.states` for why).
public final class EventSubscription: Sendable {
    /// The channel carrying the notifications.
    public let channel: UInt32
    /// `seq` at the snapshot.
    public let seq: UInt64
    /// Matching terminals at subscribe time.
    public let terminals: [Terminal]
    /// Notifications in order. Single consumer.
    public let events: AsyncStream<CoreEvent>

    let sink: EventSink

    init(channel: UInt32, seq: UInt64, terminals: [Terminal], sink: EventSink) {
        self.channel = channel
        self.seq = seq
        self.terminals = terminals
        self.sink = sink
        events = sink.stream
    }

    /// Ends the subscription (sends CLOSE; `events` finishes once the core confirms).
    public func cancel() { sink.cancel() }
}
