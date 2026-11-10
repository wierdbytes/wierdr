import Foundation

/// A viewer's colors and cell size, used by the core to answer the program's
/// display queries (OSC 10/11/12, cell size). Colors as `#rrggbb`.
public struct Display: Codable, Sendable, Hashable {
    public var fg: String?
    public var bg: String?
    public var cursor: String?
    /// Cell size in pixels.
    public var cell: CellSize?

    public struct CellSize: Sendable, Hashable {
        public var width: UInt32
        public var height: UInt32
        public init(width: UInt32, height: UInt32) {
            self.width = width
            self.height = height
        }
    }

    public init(fg: String? = nil, bg: String? = nil, cursor: String? = nil, cell: CellSize? = nil) {
        self.fg = fg
        self.bg = bg
        self.cursor = cursor
        self.cell = cell
    }

    enum CodingKeys: String, CodingKey { case fg, bg, cursor, cell }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fg = c.lenient(String.self, .fg)
        bg = c.lenient(String.self, .bg)
        cursor = c.lenient(String.self, .cursor)
        if let wh = c.lenient([UInt32].self, .cell), wh.count == 2 {
            cell = CellSize(width: wh[0], height: wh[1])
        }
    }

    /// Always writes all four members (null when unknown), as the core expects.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fg, forKey: .fg)
        try c.encode(bg, forKey: .bg)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(cell.map { [$0.width, $0.height] }, forKey: .cell)
    }
}

/// `terminal.run` params. Leave fields nil for the core's defaults.
public struct RunParams: Encodable, Sendable, Hashable {
    /// Program and arguments (or a template name and its task). Neither argv nor line: the machine's shell.
    public var argv: [String]?
    /// A shell line instead of argv (`sh -c`).
    public var line: String?
    public var cwd: String?
    /// Unique among live terminals: 1-32 of a-z 0-9 - _ .
    public var name: String?
    public var labels: [String: String]?
    public var env: [String: String]?
    /// Replace a lost program with a shell in place.
    public var keep: Bool?
    /// Remove it right after it exits.
    public var rm: Bool?
    /// Initial size before the program starts (default: the core's headless size, 200x120).
    public var size: InitialSize?
    public var display: Display?
    public var parent: String?
    public var noParent: Bool?
    public var noNotify: Bool?
    public var outliveParent: Bool?
    /// Run on another machine; the address becomes `machine/t7`.
    public var on: String?
    /// Wait until it is not working and return its output.
    public var wait: Bool?
    public var timeout: Double?

    public struct InitialSize: Codable, Sendable, Hashable {
        public var cols: UInt16
        public var rows: UInt16
        public init(cols: UInt16, rows: UInt16) {
            self.cols = cols
            self.rows = rows
        }
    }

    public init(argv: [String]? = nil, line: String? = nil, cwd: String? = nil, name: String? = nil,
                labels: [String: String]? = nil, env: [String: String]? = nil, keep: Bool? = nil,
                rm: Bool? = nil, size: InitialSize? = nil, display: Display? = nil, parent: String? = nil,
                noParent: Bool? = nil, noNotify: Bool? = nil, outliveParent: Bool? = nil, on: String? = nil,
                wait: Bool? = nil, timeout: Double? = nil) {
        self.argv = argv
        self.line = line
        self.cwd = cwd
        self.name = name
        self.labels = labels
        self.env = env
        self.keep = keep
        self.rm = rm
        self.size = size
        self.display = display
        self.parent = parent
        self.noParent = noParent
        self.noNotify = noNotify
        self.outliveParent = outliveParent
        self.on = on
        self.wait = wait
        self.timeout = timeout
    }

    enum CodingKeys: String, CodingKey {
        case argv, line, cwd, name, labels, env, keep, rm, size, display, parent, on, wait, timeout
        case noParent = "no_parent", noNotify = "no_notify", outliveParent = "outlive_parent"
    }
}

/// `terminal.attach` params.
public struct AttachParams: Encodable, Sendable, Hashable {
    /// `t7`, a name, or `machine/t7`.
    public var terminal: String
    /// The viewer's size in cells.
    public var cols: UInt16
    public var rows: UInt16
    /// Scrollback lines to paint first (main screen only).
    public var history: Int
    /// Watch only: never type or resize. Input sent on an observe stream is ignored by the core.
    public var observe: Bool
    /// Colors and cell size for answering display queries.
    public var display: Display
    /// Observers: receive RESIZE + an authoritative repaint when the grid changes.
    /// Confirmed only if `AttachStream.resizeNotifications` is true afterwards.
    public var resizeNotifications: Bool
    /// Back after a dropped line: sets the size only once active again.
    public var resumed: Bool

    public init(terminal: String, cols: UInt16, rows: UInt16, history: Int = 0, observe: Bool = false,
                display: Display = Display(), resizeNotifications: Bool = false, resumed: Bool = false) {
        self.terminal = terminal
        self.cols = cols
        self.rows = rows
        self.history = history
        self.observe = observe
        self.display = display
        self.resizeNotifications = resizeNotifications
        self.resumed = resumed
    }

    enum CodingKeys: String, CodingKey {
        case terminal, cols, rows, history, observe, display, resumed
        case resizeNotifications = "resize_notifications"
    }
}

/// `events.subscribe` filter. Empty: everything (including `doc` events).
public struct SubscribeParams: Encodable, Sendable, Hashable {
    /// Only this terminal.
    public var terminal: String?
    /// Only children of this terminal.
    public var childrenOf: String?
    /// Only terminals carrying all of these labels.
    public var labels: [String: String]?

    public init(terminal: String? = nil, childrenOf: String? = nil, labels: [String: String]? = nil) {
        self.terminal = terminal
        self.childrenOf = childrenOf
        self.labels = labels
    }

    enum CodingKeys: String, CodingKey {
        case terminal, labels
        case childrenOf = "children_of"
    }
}

/// `machine.exec` params: a program run to completion (no terminal).
public struct ExecParams: Encodable, Sendable, Hashable {
    /// Program and arguments, run as given (no shell).
    public var argv: [String]?
    /// A shell line instead of argv.
    public var line: String?
    public var cwd: String?
    public var env: [String: String]?
    /// Bytes for its stdin (sent base64); nil closes stdin.
    public var input: Data?
    public var on: String?
    /// Seconds (default 60, at most 600).
    public var timeout: Double?

    public init(argv: [String]? = nil, line: String? = nil, cwd: String? = nil, env: [String: String]? = nil,
                input: Data? = nil, on: String? = nil, timeout: Double? = nil) {
        self.argv = argv
        self.line = line
        self.cwd = cwd
        self.env = env
        self.input = input
        self.on = on
        self.timeout = timeout
    }

    enum CodingKeys: String, CodingKey { case argv, line, cwd, env, input, on, timeout }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(argv, forKey: .argv)
        try c.encodeIfPresent(line, forKey: .line)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(env, forKey: .env)
        try c.encodeIfPresent(input?.base64EncodedString(), forKey: .input)
        try c.encodeIfPresent(on, forKey: .on)
        try c.encodeIfPresent(timeout, forKey: .timeout)
    }
}
