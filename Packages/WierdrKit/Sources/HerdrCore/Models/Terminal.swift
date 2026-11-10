import Foundation

/// A terminal record as the core reports it (`terminal.list`, `terminal.get`,
/// `created`/`restarted` events, ...). Decoding is tolerant: only `address`
/// is required; anything missing or of an unexpected type gets its default.
public struct Terminal: Codable, Sendable, Hashable, Identifiable {
    /// `t7` here, `lf/t7` for a terminal on an added machine. Unique per connection.
    public var address: String
    /// Unique name among live terminals, if given.
    public var name: String?
    public var argv: [String]
    /// Start folder.
    public var cwd: String
    /// `live` or `finished`.
    public var state: String
    public var labels: [String: String]
    public var createdMs: UInt64
    public var finishedMs: UInt64?
    public var cols: Int
    public var rows: Int
    /// Program pid (nil once lost/finished on some paths).
    public var pid: Int?
    /// What runs in it now, and its folder. Nil when finished or unknown.
    public var foreground: Foreground?
    /// Window title set by the program ("" when none).
    public var title: String
    /// Root status from OSC 7501, nil when none or cleared.
    public var status: TerminalStatus?
    /// Every status record by key (`{key: Status}`), kept opaque. Often absent.
    public var records: JSONValue?
    /// Whether it ever reported a status.
    public var reported: Bool
    public var statusMs: UInt64?
    /// Turn counter (a turn ends when the program goes from working to not).
    public var turn: UInt64
    /// Kept: lost programs are replaced with a shell.
    public var keep: Bool
    /// Parent terminal address.
    public var parent: String?
    /// How it ended (`exited`, `killed`, `server_stop`, ...) or why it waits (`signaled`, `spawn_pending`).
    public var reason: String?
    public var exitCode: Int?
    public var signal: Int?
    /// Terminal identity it runs as (`ghostty`, ...).
    public var identity: String
    /// Screen fidelity (`exact`, ...).
    public var screen: String?
    public var template: String?
    public var notify: Bool
    public var rm: Bool
    public var dieWithParent: Bool
    public var pasteGapMs: UInt64?
    public var stop: String?
    public var submit: String?
    /// Opaque `first_message` (templates).
    public var firstMessage: JSONValue?

    public var id: String { address }
    public var isLive: Bool { state == "live" }
    public var isFinished: Bool { state == "finished" }

    /// The machine part of a qualified address (`lf` for `lf/t7`), nil for this core.
    public var machine: String? {
        guard let slash = address.lastIndex(of: "/") else { return nil }
        return String(address[..<slash])
    }

    /// The address on its own machine (`t7` for `lf/t7`).
    public var localAddress: String {
        guard let slash = address.lastIndex(of: "/") else { return address }
        return String(address[address.index(after: slash)...])
    }

    public init(address: String, argv: [String] = [], cwd: String = "", state: String = "live",
                labels: [String: String] = [:], createdMs: UInt64 = 0, cols: Int = 0, rows: Int = 0) {
        self.address = address
        self.argv = argv
        self.cwd = cwd
        self.state = state
        self.labels = labels
        self.createdMs = createdMs
        self.cols = cols
        self.rows = rows
        title = ""
        reported = false
        turn = 0
        keep = false
        identity = ""
        notify = false
        rm = false
        dieWithParent = false
    }

    enum CodingKeys: String, CodingKey {
        case address, name, argv, cwd, state, labels
        case createdMs = "created_ms", finishedMs = "finished_ms"
        case cols, rows, pid, foreground, title, status, records, reported
        case statusMs = "status_ms"
        case turn, keep, parent, reason
        case exitCode = "exit_code"
        case signal, identity, screen, template, notify, rm
        case dieWithParent = "die_with_parent"
        case pasteGapMs = "paste_gap_ms"
        case stop, submit
        case firstMessage = "first_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        name = c.lenient(String.self, .name)
        argv = c.lenient([String].self, .argv) ?? []
        cwd = c.lenient(String.self, .cwd) ?? ""
        state = c.lenient(String.self, .state) ?? "live"
        labels = c.lenient([String: String].self, .labels) ?? [:]
        createdMs = c.lenient(UInt64.self, .createdMs) ?? 0
        finishedMs = c.lenient(UInt64.self, .finishedMs)
        cols = c.lenient(Int.self, .cols) ?? 0
        rows = c.lenient(Int.self, .rows) ?? 0
        pid = c.lenient(Int.self, .pid)
        foreground = c.lenient(Foreground.self, .foreground)
        title = c.lenient(String.self, .title) ?? ""
        status = c.lenient(TerminalStatus.self, .status)
        records = c.lenient(JSONValue.self, .records)
        reported = c.lenient(Bool.self, .reported) ?? false
        statusMs = c.lenient(UInt64.self, .statusMs)
        turn = c.lenient(UInt64.self, .turn) ?? 0
        keep = c.lenient(Bool.self, .keep) ?? false
        parent = c.lenient(String.self, .parent)
        reason = c.lenient(String.self, .reason)
        exitCode = c.lenient(Int.self, .exitCode)
        signal = c.lenient(Int.self, .signal)
        identity = c.lenient(String.self, .identity) ?? ""
        screen = c.lenient(String.self, .screen)
        template = c.lenient(String.self, .template)
        notify = c.lenient(Bool.self, .notify) ?? false
        rm = c.lenient(Bool.self, .rm) ?? false
        dieWithParent = c.lenient(Bool.self, .dieWithParent) ?? false
        pasteGapMs = c.lenient(UInt64.self, .pasteGapMs)
        stop = c.lenient(String.self, .stop)
        submit = c.lenient(String.self, .submit)
        firstMessage = c.lenient(JSONValue.self, .firstMessage)
    }
}

/// What runs in a terminal now: its foreground process group's leader.
public struct Foreground: Codable, Sendable, Hashable {
    public var pid: Int
    /// Process name (`node`, `zsh`, ...).
    public var name: String
    public var argv: [String]
    /// Its current folder.
    public var cwd: String

    public init(pid: Int, name: String, argv: [String], cwd: String) {
        self.pid = pid
        self.name = name
        self.argv = argv
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey { case pid, name, argv, cwd }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = c.lenient(Int.self, .pid) ?? 0
        name = c.lenient(String.self, .name) ?? ""
        argv = c.lenient([String].self, .argv) ?? []
        cwd = c.lenient(String.self, .cwd) ?? ""
    }
}

/// A status a program reported through OSC 7501 (`idle`, `working`, `done`, `blocked`, `error`, ...).
public struct TerminalStatus: Codable, Sendable, Hashable {
    public var state: String
    /// Reporting app (`pi`, `claude`, ...).
    public var app: String?
    /// Sub-kind, e.g. `question` for a blocked prompt.
    public var kind: String?
    public var msg: String?
    /// 0-100 when reported.
    public var progress: Int?
    public var title: String?

    public init(state: String, app: String? = nil, kind: String? = nil, msg: String? = nil,
                progress: Int? = nil, title: String? = nil) {
        self.state = state
        self.app = app
        self.kind = kind
        self.msg = msg
        self.progress = progress
        self.title = title
    }

    enum CodingKeys: String, CodingKey { case state, app, kind, msg, progress, title }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.lenient(String.self, .state) ?? ""
        app = c.lenient(String.self, .app)
        kind = c.lenient(String.self, .kind)
        msg = c.lenient(String.self, .msg)
        progress = c.lenient(Int.self, .progress)
        title = c.lenient(String.self, .title)
    }
}
