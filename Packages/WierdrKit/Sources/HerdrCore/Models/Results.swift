import Foundation

/// A core's identity.
public struct CoreInfo: Codable, Sendable, Hashable {
    /// Stable id of the core's state.
    public var id: String
    /// Its machine name (`mentoair`).
    public var name: String
}

/// `hello` reply.
public struct HelloResult: Codable, Sendable, Hashable {
    public var generation: UInt32
    /// Core version (`0.1.20`).
    public var version: String
    public var core: CoreInfo
    public var framed: Bool
    public var methods: [String]
    /// What the core supports (`framed`, `attach`, `events`, `resize_notifications`, `automatic_input`, ...).
    public var features: [String]
    public var loginSession: JSONValue?

    enum CodingKeys: String, CodingKey {
        case generation, version, core, framed, methods, features
        case loginSession = "login_session"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = c.lenient(UInt32.self, .generation) ?? 0
        version = c.lenient(String.self, .version) ?? ""
        core = try c.decode(CoreInfo.self, forKey: .core)
        framed = c.lenient(Bool.self, .framed) ?? false
        methods = c.lenient([String].self, .methods) ?? []
        features = c.lenient([String].self, .features) ?? []
        loginSession = c.lenient(JSONValue.self, .loginSession)
    }
}

/// `terminal.list` reply.
public struct TerminalList: Codable, Sendable, Hashable {
    public var terminals: [Terminal]
    /// Finished terminals left out (list with `all: true` to get them).
    public var hiddenFinished: Int
    public var machines: [Machine]

    enum CodingKeys: String, CodingKey {
        case terminals, machines
        case hiddenFinished = "hidden_finished"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminals = try c.decode([Terminal].self, forKey: .terminals)
        hiddenFinished = c.lenient(Int.self, .hiddenFinished) ?? 0
        machines = c.lenient([Machine].self, .machines) ?? []
    }
}

/// A machine this core added (`machine.list`), with its line state.
public struct Machine: Codable, Sendable, Hashable, Identifiable {
    /// This core's name for it; terminals there are addressed `name/t7`.
    public var name: String
    /// SSH target (`user@host`).
    public var target: String
    public var id: String
    public var host: String
    public var version: String
    /// Line state (`connected`, `connecting`, `disconnected`, ...).
    public var state: String
    public var session: String?
    public var sinceMs: UInt64?
    public var temporary: Bool
    public var via: Bool
    /// Why it is not connected, when it isn't.
    public var why: String?

    enum CodingKeys: String, CodingKey {
        case name, target, id, host, version, state, session, temporary, via, why
        case sinceMs = "since_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        target = c.lenient(String.self, .target) ?? ""
        id = c.lenient(String.self, .id) ?? ""
        host = c.lenient(String.self, .host) ?? ""
        version = c.lenient(String.self, .version) ?? ""
        state = c.lenient(String.self, .state) ?? ""
        session = c.lenient(String.self, .session)
        sinceMs = c.lenient(UInt64.self, .sinceMs)
        temporary = c.lenient(Bool.self, .temporary) ?? false
        via = c.lenient(Bool.self, .via) ?? false
        why = c.lenient(String.self, .why)
    }

    public var isConnected: Bool { state == "connected" }
}

/// A document and its version (`doc.get`). An unwritten name is `{value: null, version: 0}`.
public struct Document: Sendable, Hashable {
    /// Opaque JSON, key order preserved.
    public var value: JSONValue
    /// Pass this to `setDoc` to write on top of this read.
    public var version: UInt64

    public init(value: JSONValue, version: UInt64) {
        self.value = value
        self.version = version
    }
}

/// `terminal.run` reply: the new terminal, plus output when run with `wait`.
public struct RunResult: Sendable, Hashable {
    public var terminal: Terminal
    /// Output, when run with `wait: true`.
    public var output: String?
    /// Opaque wait result, when run with `wait: true`.
    public var wait: JSONValue?
}

/// `terminal.read` reply.
public struct ReadResult: Codable, Sendable, Hashable {
    public var text: String
    public var complete: Bool
    /// `screen`, `history`, ...
    public var how: String
    public var why: String?
}

/// `terminal.send` reply.
public struct SendResult: Codable, Sendable, Hashable {
    /// The turn this send started.
    public var turn: UInt64
    public var status: String?
    public var started: Bool?
    public var wait: JSONValue?
}

/// `terminal.put` reply.
public struct PutResult: Codable, Sendable, Hashable {
    /// Where it landed, as the terminal's machine sees it.
    public var path: String
    public var bytes: UInt64
}

/// `terminal.keys` reply.
public struct KeysResult: Codable, Sendable, Hashable {
    public var turn: UInt64
    public var status: String?
}

/// `terminal.interrupt` reply.
public struct InterruptResult: Codable, Sendable, Hashable {
    /// `stopped`, `exited`, `still_working`, `unknown`.
    public var outcome: String
    /// The key it sent.
    public var key: String
}

/// `machine.exec` reply, output already base64-decoded.
public struct ExecResult: Sendable, Hashable {
    /// Exit code, nil when killed by a signal or timed out.
    public var code: Int?
    public var signal: Int?
    public var stdout: Data
    public var stderr: Data
    public var truncated: Bool
    public var timedOut: Bool
    public var ms: UInt64

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// `file.read` reply: lines `first...last` of `lines` total.
public struct FileReadResult: Codable, Sendable, Hashable {
    public var text: String
    public var first: Int
    public var last: Int
    public var lines: Int
}

/// A template (`templates.list`).
public struct TemplateInfo: Codable, Sendable, Hashable {
    public var name: String
    public var description: String?
    public var command: String
    /// Why it is unusable, if it is.
    public var error: String?
}

/// A terminal holder process (`server.status`).
public struct HolderInfo: Codable, Sendable, Hashable {
    public var pid: Int
    public var instance: String
    public var current: Bool
    public var terminals: Int
}

/// `server.status` reply.
public struct ServerStatus: Codable, Sendable, Hashable {
    public var core: CoreInfo
    public var version: String
    public var pid: Int
    public var uptimeMs: UInt64
    public var live: Int
    public var finished: Int
    public var holder: HolderInfo?
    public var holders: [HolderInfo]
    public var installedBy: String?

    enum CodingKeys: String, CodingKey {
        case core, version, pid, live, finished, holder, holders
        case uptimeMs = "uptime_ms"
        case installedBy = "installed_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        core = try c.decode(CoreInfo.self, forKey: .core)
        version = c.lenient(String.self, .version) ?? ""
        pid = c.lenient(Int.self, .pid) ?? 0
        uptimeMs = c.lenient(UInt64.self, .uptimeMs) ?? 0
        live = c.lenient(Int.self, .live) ?? 0
        finished = c.lenient(Int.self, .finished) ?? 0
        holder = c.lenient(HolderInfo.self, .holder)
        holders = c.lenient([HolderInfo].self, .holders) ?? []
        installedBy = c.lenient(String.self, .installedBy)
    }
}
