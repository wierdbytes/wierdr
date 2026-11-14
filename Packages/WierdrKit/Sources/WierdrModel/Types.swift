import Foundation

// The Herdr world as Wierdr shows it. Value types only: the UI renders these,
// `Workspace` builds them from the `herdr-app` document(s) and the terminal
// event stream (see docs/research/herdr-app-model.md for the source of truth).
//
// Ids and terminal addresses are *qualified* the way herdr-app qualifies
// them: things on the connected computer are bare (`sp…`, `t5w`), things on a
// machine that computer added are prefixed (`lf/sp…`, `lf/t1`).

// MARK: - Status

/// An agent's status as Herdr shows it (`nil` = the terminal is not an agent).
/// Ordered by urgency: blocked > done > working > idle.
public enum AgentStatus: Int, Comparable, Sendable, CaseIterable, Hashable {
    case idle = 1
    case working = 2
    case done = 3
    case blocked = 4

    public static func < (a: AgentStatus, b: AgentStatus) -> Bool { a.rawValue < b.rawValue }

    /// The most urgent of several statuses (`nil` when none is an agent).
    public static func rollup<S: Sequence>(_ statuses: S) -> AgentStatus? where S.Element == AgentStatus? {
        statuses.compactMap { $0 }.max()
    }
}

// MARK: - Programs

/// What runs in a terminal, resolved through Herdr's program table
/// (`programs.json`): its display name and icon.
public struct Program: Hashable, Sendable {
    /// Table key: `claude`, `pi`, `shell`, `lazygit`, `program` (unknown) …
    public var key: String
    /// Display name: `Claude Code`, `Pi`, `zsh`, `lazygit` …
    public var name: String
    /// Asset-catalog image name of the icon, e.g. `program.claude`.
    public var iconAsset: String
    /// `true`: one-color glyph, tint it. `false`: full-color picture.
    public var tint: Bool
    /// Tile background and glyph colors (`#rrggbb`), for tiles.
    public var tile: String
    public var color: String
    public var isShell: Bool
    public var isAgent: Bool

    public init(key: String, name: String, iconAsset: String, tint: Bool = true,
                tile: String = "#1c1d21", color: String = "#ffffff",
                isShell: Bool = false, isAgent: Bool = false) {
        self.key = key; self.name = name; self.iconAsset = iconAsset; self.tint = tint
        self.tile = tile; self.color = color; self.isShell = isShell; self.isAgent = isAgent
    }

    public static let shell = Program(key: "shell", name: "Shell", iconAsset: "program.shell",
                                      tile: "#16241a", color: "#4ec95f", isShell: true)
}

/// An agent people can start from the "+" menu (`programs.json` entries with `run`).
public struct AgentLauncher: Hashable, Sendable, Identifiable {
    public var id: String { program.key }
    public var program: Program
    /// argv to start it, e.g. `["codex", "--no-daemon"]`.
    public var run: [String]
    /// Whether the machine has it (`nil` = not checked yet).
    public var installed: Bool?

    public init(program: Program, run: [String], installed: Bool?) {
        self.program = program; self.run = run; self.installed = installed
    }
}

// MARK: - Terminals and agents

/// Rich facts pi (and other agents using the same convention) publish as
/// `agent.*` labels: model, effort, context size, prompt cache.
public struct AgentMeta: Hashable, Sendable {
    /// `anthropic`, `openai` … (`agent.provider`).
    public var provider: String?
    /// Asset name of the provider mark, e.g. `provider.anthropic`.
    public var providerAsset: String?
    /// Display model, already shortened: `Opus 5.5` (`agent.model`).
    public var model: String?
    /// `agent.effort`: `off|minimal|low|medium|high|xhigh|max`.
    public var effort: String?
    /// Context tokens in use and the window (`agent.ctx`, `agent.ctx_max`).
    public var ctx: Int?
    public var ctxMax: Int?
    /// Prompt cache expiry and its TTL (`agent.cache_until` ms, `agent.cache_ttl` ms).
    public var cacheUntil: Date?
    public var cacheTTL: TimeInterval?
    /// `agent.session`: pi session id.
    public var session: String?
    /// `agent.subagents`: sub-agents the agent reports itself.
    public var subagents: Int

    public init(provider: String? = nil, providerAsset: String? = nil, model: String? = nil,
                effort: String? = nil, ctx: Int? = nil, ctxMax: Int? = nil, cacheUntil: Date? = nil,
                cacheTTL: TimeInterval? = nil, session: String? = nil, subagents: Int = 0) {
        self.provider = provider; self.providerAsset = providerAsset; self.model = model
        self.effort = effort; self.ctx = ctx; self.ctxMax = ctxMax; self.cacheUntil = cacheUntil
        self.cacheTTL = cacheTTL; self.session = session; self.subagents = subagents
    }
}

/// One herdr-core terminal, as the UI needs it.
public struct TerminalInfo: Identifiable, Hashable, Sendable {
    public var id: String { address }
    /// Qualified address: `t5w`, `lf/t1`.
    public var address: String
    /// Machine name for terminals on an added machine, `nil` on the connected computer.
    public var machine: String?
    /// hc terminal name (`--name`), if any.
    public var name: String?
    /// hc template it was started from (`hc run reviewer …`), if any.
    public var template: String?
    /// When the core started it.
    public var createdAt: Date?
    /// Window title (OSC 0/2), cleaned of spinner glyphs; `""` when none.
    public var title: String
    /// Live folder (foreground process cwd, else launch cwd).
    public var cwd: String?
    /// Foreground process name (basename of its argv[0], leading `-` dropped).
    public var processName: String?
    public var program: Program
    public var isLive: Bool
    /// Herdr status (`nil` = not an agent).
    public var status: AgentStatus?
    /// Raw OSC 7501 word (`working`, `idle`, `blocked`, `error`, `done` …).
    public var state: String?
    /// OSC 7501 `msg` (pi: the session name; a question while blocked).
    public var message: String?
    /// OSC 7501 `app`.
    public var app: String?
    public var turn: Int
    /// When the status last changed (from the record's `status_ms`).
    public var statusChangedAt: Date?
    /// Qualified address of the terminal that started it (sub-agents).
    public var parent: String?
    public var labels: [String: String]
    public var pinned: Bool
    /// When it was pinned (`herdr.pinned` holds the Unix time in seconds); nil for a
    /// pin without a time (`"1"`, the desktop's) or when it isn't pinned.
    public var pinnedAt: Date?
    public var meta: AgentMeta?
    /// Qualified space/tab ids from `herdr.space` / `herdr.tab` labels.
    public var spaceID: String?
    public var tabID: String?

    public init(address: String, machine: String? = nil, name: String? = nil, template: String? = nil,
                createdAt: Date? = nil, title: String = "",
                cwd: String? = nil, processName: String? = nil, program: Program = .shell,
                isLive: Bool = true, status: AgentStatus? = nil, state: String? = nil,
                message: String? = nil, app: String? = nil, turn: Int = 0,
                statusChangedAt: Date? = nil, parent: String? = nil, labels: [String: String] = [:],
                pinned: Bool = false, pinnedAt: Date? = nil, meta: AgentMeta? = nil, spaceID: String? = nil,
                tabID: String? = nil) {
        self.address = address; self.machine = machine; self.name = name; self.title = title
        self.template = template; self.createdAt = createdAt
        self.cwd = cwd; self.processName = processName; self.program = program; self.isLive = isLive
        self.status = status; self.state = state; self.message = message; self.app = app
        self.turn = turn; self.statusChangedAt = statusChangedAt; self.parent = parent
        self.labels = labels; self.pinned = pinned; self.pinnedAt = pinnedAt; self.meta = meta
        self.spaceID = spaceID; self.tabID = tabID
    }

    public var isAgent: Bool { status != nil }

    /// Its status as a sub-agent reads under its parent (`kidStatus`): never
    /// done, it reports to its parent and the parent's done is the news
    /// (`error` is already blocked).
    public var kidStatus: AgentStatus? {
        status == .done ? .idle : status
    }
}

/// A live terminal an agent started (`hc run`), shown under that agent in the
/// sidebar (the user's `wierd-agents`): a sub-agent (it reports a status) or a
/// plain terminal. Its own children follow it, a level deeper.
public struct SubAgent: Identifiable, Hashable, Sendable {
    /// One column of the tree in front of a row: `├`/`└` its own elbow into
    /// its first line, `│` an ancestor's line going on past it, blank none.
    public enum Line: Hashable, Sendable { case tee, elbow, pipe, blank }

    public var id: String { terminal.address }
    public var terminal: TerminalInfo
    /// One per level, outermost first; the last is its own (`tee` or `elbow`).
    public var lines: [Line]
    /// Its pane, when someone kept it (`Keep`): it still shows here, under its parent.
    public var paneID: String?

    public init(terminal: TerminalInfo, lines: [Line], paneID: String? = nil) {
        self.terminal = terminal; self.lines = lines; self.paneID = paneID
    }

    public var isAgent: Bool { terminal.isAgent }
    public var depth: Int { lines.count }
}

// MARK: - Layout: spaces, tabs, panes

/// A node of a tab's split tree (the document's `root`).
public struct PaneNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A pane showing a terminal (qualified address).
        case terminal(String)
        /// A mod pane (desktop panel such as a markdown viewer); not rendered on iPad.
        case mod(String)
        /// Children side by side.
        case row([PaneNode])
        /// Children stacked.
        case column([PaneNode])
    }

    /// Qualified node id (`p…` for panes, `s…`/`tb…` for containers).
    public var id: String
    public var kind: Kind
    /// Flex weight among siblings (missing size = 1).
    public var weight: Double

    public init(id: String, kind: Kind, weight: Double = 1) {
        self.id = id; self.kind = kind; self.weight = weight
    }

    public var isPane: Bool {
        switch kind { case .terminal, .mod: return true; default: return false }
    }

    /// Panes in tree order (depth first).
    public var panes: [Pane] {
        switch kind {
        case .terminal(let address): return [Pane(id: id, terminal: address, mod: nil)]
        case .mod(let name): return [Pane(id: id, terminal: nil, mod: name)]
        case .row(let children), .column(let children): return children.flatMap(\.panes)
        }
    }
}

/// A leaf of the split tree.
public struct Pane: Identifiable, Hashable, Sendable {
    public var id: String
    /// Qualified terminal address for terminal panes.
    public var terminal: String?
    /// Mod name for mod panes.
    public var mod: String?

    public init(id: String, terminal: String?, mod: String?) {
        self.id = id; self.terminal = terminal; self.mod = mod
    }
}

public struct Tab: Identifiable, Hashable, Sendable {
    /// Qualified tab id (`tb…`, `lf/tb…`).
    public var id: String
    public var spaceID: String
    /// Name a person gave it (`""` = unnamed).
    public var name: String
    /// 0-based position in its space.
    public var index: Int
    public var root: PaneNode
    /// Most urgent status of its agents.
    public var status: AgentStatus?

    public init(id: String, spaceID: String, name: String, index: Int, root: PaneNode, status: AgentStatus? = nil) {
        self.id = id; self.spaceID = spaceID; self.name = name; self.index = index
        self.root = root; self.status = status
    }

    /// `name`, or its 1-based number when unnamed (Herdr's rule).
    public var displayName: String { name.isEmpty ? String(index + 1) : name }
    public var panes: [Pane] { root.panes }
}

/// Git facts about a space's folder (for the sidebar's git tail).
public struct GitInfo: Hashable, Sendable {
    public var top: String?
    public var repo: String?
    public var branch: String?
    public var ahead: Int
    public var behind: Int
    public var isWorktree: Bool

    public init(top: String? = nil, repo: String? = nil, branch: String? = nil, ahead: Int = 0,
                behind: Int = 0, isWorktree: Bool = false) {
        self.top = top; self.repo = repo; self.branch = branch; self.ahead = ahead
        self.behind = behind; self.isWorktree = isWorktree
    }
}

public struct Space: Identifiable, Hashable, Sendable {
    /// Qualified space id (`sp…`, `lf/sp…`).
    public var id: String
    /// Machine name (`nil` = the connected computer).
    public var machine: String?
    /// Name a person gave it (`""` = automatic).
    public var name: String
    /// Shown name: `name`, else its first terminal's repo/folder name, `~` at home.
    public var displayName: String
    /// Folder it was made in (fallback for new terminals).
    public var folder: String
    public var tabs: [Tab]
    public var status: AgentStatus?
    public var git: GitInfo?
    /// Avatar color, `#rrggbb`.
    public var color: String

    public init(id: String, machine: String?, name: String, displayName: String, folder: String,
                tabs: [Tab], status: AgentStatus? = nil, git: GitInfo? = nil, color: String = "#22a99a") {
        self.id = id; self.machine = machine; self.name = name; self.displayName = displayName
        self.folder = folder; self.tabs = tabs; self.status = status; self.git = git; self.color = color
    }

    /// First letter for the avatar.
    public var initial: String {
        displayName.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "~"
    }
}

/// A computer whose spaces are shown: the connected one (`name == nil`) or one
/// it added (`hc machine add`).
public struct Machine: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Its layout document is loaded and usable.
        case ready
        case loading
        /// Unreachable / needs login / needs update; text for the user.
        case unavailable(String)
    }

    /// `""` for the connected computer, else the machine name.
    public var id: String { name ?? "" }
    public var name: String?
    public var state: State
    public var isConnected: Bool

    public init(name: String?, state: State, isConnected: Bool) {
        self.name = name; self.state = state; self.isConnected = isConnected
    }

    public var displayName: String { name ?? "This computer" }
    public var isLocal: Bool { name == nil }
}

// MARK: - Sidebar rows

/// One row under a space card in the sidebar, in Herdr's order
/// (agents by pinned → urgency → recency, then plain terminals in pane order).
public struct SidebarRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case agent, terminal, mod }
    public var id: String { paneID }
    public var kind: Kind
    public var paneID: String
    public var tabID: String
    /// The terminal shown in that pane (nil for mod panes).
    public var terminal: TerminalInfo?
    /// Mod name for mod panes.
    public var mod: String?
    /// True when this row's tab shows 2+ rows (the sidebar draws a bracket joining them).
    public var tabIsSplit: Bool
    /// An agent's sub-agents and terminals, depth first (kept ones too: they show
    /// here, not as rows of their own tab).
    public var subtree: [SubAgent]
    /// The most urgent of its own status and its sub-agents' (what the sidebar sorts by).
    public var urgency: AgentStatus?

    public init(kind: Kind, paneID: String, tabID: String, terminal: TerminalInfo?, mod: String? = nil,
                tabIsSplit: Bool = false, subtree: [SubAgent] = [], urgency: AgentStatus? = nil) {
        self.kind = kind; self.paneID = paneID; self.tabID = tabID; self.terminal = terminal
        self.mod = mod; self.tabIsSplit = tabIsSplit; self.subtree = subtree
        self.urgency = urgency ?? terminal?.status
    }

    /// This row's pane, then its kept sub-agents' panes (the order ⌘] steps through).
    public var paneIDs: [String] { [paneID] + subtree.compactMap(\.paneID) }
}

// MARK: - Commands

public enum SplitDirection: String, Sendable { case right, down }

/// What a new terminal runs.
public enum Launch: Hashable, Sendable {
    /// The machine's own shell.
    case shell
    /// An agent (argv from `AgentLauncher.run`), optionally with a first message.
    case agent(AgentLauncher, task: String?)
}

public enum WorkspaceError: Error, LocalizedError, Sendable {
    case notConnected
    case layoutUnavailable(machine: String?)
    case notFound(String)
    case conflict
    case core(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .layoutUnavailable(let m): return "The layout of \(m ?? "this computer") is unavailable"
        case .notFound(let what): return "\(what) not found"
        case .conflict: return "The layout changed elsewhere; try again"
        case .core(let message): return message
        }
    }
}
