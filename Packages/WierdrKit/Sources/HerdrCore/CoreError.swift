import Foundation

/// A JSON-RPC error answered by the core:
/// `{"code":-32000,"message":"no terminal t9","data":{"kind":"not_found","hint":"..."}}`.
public struct CoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// JSON-RPC code (-32000 for core errors, -32601 unknown method, -32602 bad params, ...).
    public var code: Int
    public var message: String
    /// Stable machine-readable kind from `data.kind` (`not_found`, `conflict`,
    /// `unavailable`, `invalid_params`, `unknown_method`, ...).
    public var kind: String?
    /// What to do about it, from `data.hint`.
    public var hint: String?
    /// The whole `data` member, for anything else it carries.
    public var data: JSONValue?

    public init(code: Int, message: String, kind: String? = nil, hint: String? = nil, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.kind = kind
        self.hint = hint
        self.data = data
    }

    /// From a JSON-RPC `error` member; tolerant of missing pieces.
    public init(json: JSONValue) {
        self.init(
            code: json["code"]?.int ?? 0,
            message: json["message"]?.string ?? json.jsonString(),
            kind: json["data"]?["kind"]?.string,
            hint: json["data"]?["hint"]?.string,
            data: json["data"]
        )
    }

    public var isNotFound: Bool { kind == "not_found" }
    public var isConflict: Bool { kind == "conflict" }
    public var isUnavailable: Bool { kind == "unavailable" }

    public var description: String {
        var s = message
        if let kind { s += " [\(kind)]" }
        if let hint, !hint.isEmpty { s += " (\(hint))" }
        return s
    }
}

/// `doc.set` lost a race: the document is no longer at the version you read.
/// Read it again (`getDoc`) and retry on top of what is there now.
public struct DocConflict: Error, Sendable, Equatable, CustomStringConvertible {
    public var name: String
    /// The version you wrote against.
    public var expectedVersion: UInt64
    /// The current version, when the core's message names it.
    public var currentVersion: UInt64?
    public var error: CoreError

    public var description: String { "document \(name) changed: \(error.message)" }

    init(name: String, expectedVersion: UInt64, error: CoreError) {
        self.name = name
        self.expectedVersion = expectedVersion
        self.error = error
        // "document \"x\" is at version 3, not 99"
        currentVersion = error.message.range(of: "is at version ").flatMap { r in
            UInt64(error.message[r.upperBound...].prefix { $0.isNumber })
        }
    }
}

/// The connection itself failed or is not usable (as opposed to a call the core refused).
public enum ConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `start()` has not completed yet.
    case notStarted
    /// `start()` was called twice.
    case alreadyStarted
    /// `close()` was called; the connection is over.
    case closed
    /// The pipe ended or failed (the core went away, the SSH session dropped, ...).
    case disconnected(String)
    /// The core sent something that is not the protocol; the connection was dropped.
    case protocolViolation(String)
    /// A reply did not have the expected shape.
    case decoding(method: String, message: String)

    public var description: String {
        switch self {
        case .notStarted: "connection not started"
        case .alreadyStarted: "connection already started"
        case .closed: "connection closed"
        case .disconnected(let why): "disconnected: \(why)"
        case .protocolViolation(let why): "protocol violation: \(why)"
        case .decoding(let method, let message): "unexpected \(method) reply: \(message)"
        }
    }
}
