import Foundation

/// Typed wrappers for the methods the app uses. Terminals are addressed as
/// `t7`, a name, or `machine/t7`. Anything not wrapped: `call(_:params:)`.
extension CoreConnection {
    // MARK: Terminals

    /// `terminal.list`: live terminals (all, with finished ones, when `all`), optionally filtered by labels.
    public func listTerminals(all: Bool = false, labels: [String: String] = [:]) async throws -> TerminalList {
        var params: JSONValue = ["all": .bool(all)]
        if !labels.isEmpty { params["labels"] = .object(JSONObject(labels.mapValues(JSONValue.string))) }
        return try await call("terminal.list", params)
    }

    /// `terminal.get`.
    public func getTerminal(_ terminal: String) async throws -> Terminal {
        try await call("terminal.get", ["terminal": JSONValue.string(terminal)] as JSONValue)
    }

    /// `terminal.run`: starts a program (or the machine's shell) in a new terminal.
    public func runTerminal(_ params: RunParams) async throws -> RunResult {
        let result = try await call("terminal.run", params: JSONValue(data: Self.encode(params)))
        let terminal = try Self.decode(Terminal.self, result, method: "terminal.run")
        return RunResult(terminal: terminal, output: result["output"]?.string,
                         wait: result["wait"].flatMap { $0.isNull ? nil : $0 })
    }

    /// `terminal.kill`: ends its program (final, even when kept).
    @discardableResult
    public func killTerminal(_ terminal: String) async throws -> Terminal {
        try await call("terminal.kill", ["terminal": JSONValue.string(terminal)] as JSONValue)
    }

    /// `terminal.rm`: removes a finished terminal's record. Returns the removed address.
    @discardableResult
    public func removeTerminal(_ terminal: String) async throws -> String {
        let result = try await call("terminal.rm", params: ["terminal": .string(terminal)])
        return result["removed"]?.string ?? terminal
    }

    /// `terminal.label`: sets labels; an empty value removes that label.
    @discardableResult
    public func labelTerminal(_ terminal: String, _ labels: [String: String]) async throws -> Terminal {
        let params: JSONValue = ["terminal": .string(terminal), "labels": .object(JSONObject(labels.mapValues(JSONValue.string)))]
        return try await call("terminal.label", params)
    }

    /// `terminal.keep`: keep (replace lost programs with a shell) or not.
    @discardableResult
    public func keepTerminal(_ terminal: String, _ keep: Bool) async throws -> Terminal {
        try await call("terminal.keep", ["terminal": .string(terminal), "keep": .bool(keep)] as JSONValue)
    }

    /// `terminal.read`: the screen as text, plus `lines` of history above it.
    public func readTerminal(_ terminal: String, lines: Int = 0) async throws -> ReadResult {
        try await call("terminal.read", ["terminal": .string(terminal), "lines": .int(Int64(lines))] as JSONValue)
    }

    /// `terminal.send`: pastes `text` and submits it with Enter (agent prompts).
    /// `force` types even when the program is blocked on a dialog.
    @discardableResult
    public func sendText(_ terminal: String, _ text: String, force: Bool = false) async throws -> SendResult {
        try await call("terminal.send", ["terminal": .string(terminal), "text": .string(text), "force": .bool(force)] as JSONValue)
    }

    /// `terminal.keys`: presses named keys (`enter`, `esc`, `ctrl+c`, `up`, ...).
    @discardableResult
    public func sendKeys(_ terminal: String, _ keys: [String]) async throws -> KeysResult {
        try await call("terminal.keys", ["terminal": .string(terminal), "keys": .array(keys.map(JSONValue.string))] as JSONValue)
    }

    /// `terminal.interrupt`: interrupts the program and watches up to `timeout` seconds for an effect.
    @discardableResult
    public func interrupt(_ terminal: String, timeout: Double? = nil) async throws -> InterruptResult {
        var params: JSONValue = ["terminal": .string(terminal)]
        if let timeout { params["timeout"] = .double(timeout) }
        return try await call("terminal.interrupt", params)
    }

    // MARK: Documents

    /// `doc.get`: a document's value (key order preserved) and version; `on` reads another machine's.
    public func getDoc(_ name: String, on machine: String? = nil) async throws -> Document {
        var params: JSONValue = ["name": .string(name)]
        if let machine { params["on"] = .string(machine) }
        let result = try await call("doc.get", params: params)
        guard let version = result["version"]?.uint64 else {
            throw ConnectionError.decoding(method: "doc.get", message: "no version")
        }
        return Document(value: result["value"] ?? .null, version: version)
    }

    /// `doc.set`: writes `value` if the document is still at `version`; returns
    /// the new version. Writing `.null` deletes the value (the version stays).
    /// Throws `DocConflict` when someone else wrote first.
    @discardableResult
    public func setDoc(_ name: String, value: JSONValue, version: UInt64, on machine: String? = nil) async throws -> UInt64 {
        var params: JSONValue = ["name": .string(name), "value": value, "version": .uint(version)]
        if version <= UInt64(Int64.max) { params["version"] = .int(Int64(version)) }
        if let machine { params["on"] = .string(machine) }
        do {
            let result = try await call("doc.set", params: params)
            guard let newVersion = result["version"]?.uint64 else {
                throw ConnectionError.decoding(method: "doc.set", message: "no version")
            }
            return newVersion
        } catch let error as CoreError where error.isConflict {
            throw DocConflict(name: name, expectedVersion: version, error: error)
        }
    }

    // MARK: Machines, files, server

    /// `machine.list`: machines this core added, with their line state.
    public func listMachines() async throws -> [Machine] {
        let result = try await call("machine.list", params: [:])
        return try Self.decode([Machine].self, result["machines"] ?? .array([]), method: "machine.list")
    }

    /// `machine.exec`: runs a program to completion; output base64-decoded.
    public func exec(_ params: ExecParams) async throws -> ExecResult {
        let r = try await call("machine.exec", params: JSONValue(data: Self.encode(params)))
        func bytes(_ key: String) -> Data { r[key]?.string.flatMap { Data(base64Encoded: $0) } ?? Data() }
        return ExecResult(code: r["code"]?.int, signal: r["signal"]?.int, stdout: bytes("stdout"),
                          stderr: bytes("stderr"), truncated: r["truncated"]?.bool ?? false,
                          timedOut: r["timed_out"]?.bool ?? false, ms: r["ms"]?.uint64 ?? 0)
    }

    /// `file.read`: a text file, optionally lines `offset...` (from 1), at most `limit` lines.
    public func readFile(_ path: String, cwd: String? = nil, offset: Int? = nil, limit: Int? = nil,
                         on machine: String? = nil) async throws -> FileReadResult {
        var params: JSONValue = ["path": .string(path)]
        if let cwd { params["cwd"] = .string(cwd) }
        if let offset { params["offset"] = .int(Int64(offset)) }
        if let limit { params["limit"] = .int(Int64(limit)) }
        if let machine { params["on"] = .string(machine) }
        return try await call("file.read", params)
    }

    /// `templates.list`.
    public func listTemplates() async throws -> [TemplateInfo] {
        let result = try await call("templates.list", params: [:])
        return try Self.decode([TemplateInfo].self, result["templates"] ?? .array([]), method: "templates.list")
    }

    /// `server.status`.
    public func serverStatus() async throws -> ServerStatus {
        try await call("server.status", JSONValue.object([:]))
    }
}
