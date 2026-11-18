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
    /// Work its program runs in-process and reports as 7501 records of its own (Claude
    /// Code's background sub-agents and shells), by id; none once it ended.
    public var records: [TaskRecord]

    public init(address: String, machine: String? = nil, name: String? = nil, template: String? = nil,
                createdAt: Date? = nil, title: String = "",
                cwd: String? = nil, processName: String? = nil, program: Program = .shell,
                isLive: Bool = true, status: AgentStatus? = nil, state: String? = nil,
                message: String? = nil, app: String? = nil, turn: Int = 0,
                statusChangedAt: Date? = nil, parent: String? = nil, labels: [String: String] = [:],
                pinned: Bool = false, pinnedAt: Date? = nil, meta: AgentMeta? = nil, spaceID: String? = nil,
                tabID: String? = nil, records: [TaskRecord] = []) {
        self.address = address; self.machine = machine; self.name = name; self.title = title
        self.template = template; self.createdAt = createdAt
        self.cwd = cwd; self.processName = processName; self.program = program; self.isLive = isLive
        self.status = status; self.state = state; self.message = message; self.app = app
        self.turn = turn; self.statusChangedAt = statusChangedAt; self.parent = parent
        self.labels = labels; self.pinned = pinned; self.pinnedAt = pinnedAt; self.meta = meta
        self.spaceID = spaceID; self.tabID = tabID; self.records = records
    }

    public var isAgent: Bool { status != nil }

    /// The sub-agents it runs in-process: what it says (`agent.subagents`) or the
    /// sub-agent records it reports, whichever is more (the same work, told twice).
    public var inProcessAgents: Int {
        max(meta?.subagents ?? 0, records.filter { $0.kind == .agent }.count)
    }

    /// The background shells it reports (records).
    public var backgroundShells: Int {
        records.filter { $0.kind == .shell }.count
    }

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

/// A piece of work a terminal's program runs in-process and reports as an OSC 7501
/// record of its own (`Terminal.records`, keyed by id), next to its root status:
/// Claude Code's background sub-agents and shells. It has no terminal: it shows as a
/// row of its terminal's tree, and a tap opens that terminal.
public struct TaskRecord: Identifiable, Hashable, Sendable {
    /// What it is, as far as its id tells: Claude Code's background shells are `b` and
    /// 8 base-36 characters (its sub-agents `a` and 16 hex); anything else is taken for
    /// a sub-agent.
    public enum Kind: Hashable, Sendable { case agent, shell }

    /// Its record's key (`a445e47c8be43ef46`, `bcq5ektlx`).
    public var id: String
    public var app: String?
    /// Raw 7501 word: `working`, `blocked` …
    public var state: String
    /// What it does (`title`, else `msg`, else its id).
    public var title: String
    /// `msg` (a blocked one's question).
    public var message: String?
    /// 7501 `kind` of a blocked one: `permission`, `question`, `auth`.
    public var blockedKind: String?
    public var progress: Int?
    public var kind: Kind

    public init(id: String, app: String? = nil, state: String, title: String, message: String? = nil,
                blockedKind: String? = nil, progress: Int? = nil, kind: Kind? = nil) {
        self.id = id; self.app = app; self.state = state; self.title = title; self.message = message
        self.blockedKind = blockedKind; self.progress = progress
        self.kind = kind ?? Self.kind(id: id, app: app)
    }

    /// Its dot, as a sub-agent's (`kidStatus`): working, blocked (`blocked`/`error`),
    /// else idle (it reports to its terminal, whose own status is the news).
    public var status: AgentStatus {
        switch state {
        case "working": return .working
        case "blocked", "error": return .blocked
        default: return .idle
        }
    }

    static func kind(id: String, app: String?) -> Kind {
        guard app == "claude-code", id.count == 9, id.first == "b" else { return .agent }
        return id.dropFirst().allSatisfy { ($0.isASCII && $0.isNumber) || ("a"..."z").contains($0) } ? .shell : .agent
    }
}

/// A record in an agent's tree, under the terminal that reports it.
public struct RecordKid: Identifiable, Hashable, Sendable {
    public var id: String { "\(owner)#\(record.id)" }
    public var record: TaskRecord
    /// The terminal that reports it: the row's agent or one of its sub-agents.
    public var owner: String
    /// As `SubAgent.lines`.
    public var lines: [SubAgent.Line]

    public init(record: TaskRecord, owner: String, lines: [SubAgent.Line]) {
        self.record = record; self.owner = owner; self.lines = lines
    }
}

/// A row of an agent's tree, depth first: a terminal it started (`SubAgent`), or a
/// record a terminal of the tree reports (after that terminal's own children).
public enum TreeNode: Identifiable, Hashable, Sendable {
    case kid(SubAgent)
    case record(RecordKid)

    public var id: String {
        switch self {
        case .kid(let k): return "kid:\(k.terminal.address)"
        case .record(let r): return "record:\(r.id)"
        }
    }

    public var lines: [SubAgent.Line] {
        switch self {
        case .kid(let k): return k.lines
        case .record(let r): return r.lines
        }
    }

    public var kid: SubAgent? { if case .kid(let k) = self { return k } else { return nil } }
    public var record: RecordKid? { if case .record(let r) = self { return r } else { return nil } }
}

/// What an agent row's badges count: its tree's sub-agents (with a terminal, and those
/// the block's terminals run in-process: per terminal `inProcessAgents`) and terminals
/// (plain ones it started, and the background shells the block's terminals report).
public struct KidCounts: Hashable, Sendable {
    public var terminalAgents = 0
    public var inProcess = 0
    public var terminals = 0
    public var shells = 0
    /// One of its sub-agents (or records) needs you.
    public var alert = false

    public var agents: Int { terminalAgents + inProcess }
    public var allTerminals: Int { terminals + shells }

    public init() {}

    /// For an agent `terminal` and its tree.
    public init(terminal: TerminalInfo?, tree: [TreeNode]) {
        var seen: Set<String> = []
        func own(_ t: TerminalInfo) {
            guard seen.insert(t.address).inserted else { return }
            inProcess += t.inProcessAgents
            shells += t.backgroundShells
        }
        if let terminal { own(terminal) }
        for node in tree {
            switch node {
            case .kid(let k):
                if k.isAgent {
                    terminalAgents += 1
                    if k.terminal.status == .blocked { alert = true }
                } else {
                    terminals += 1
                }
                own(k.terminal)
            case .record(let r):
                if r.record.status == .blocked { alert = true }
            }
        }
    }
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
    /// What its tree shows, depth first: `subtree` and the records its terminals report,
    /// each terminal's after its own children (the lines drawn for both).
    public var tree: [TreeNode]
    /// The most urgent of its own status and its sub-agents' (what the sidebar sorts by).
    public var urgency: AgentStatus?

    public init(kind: Kind, paneID: String, tabID: String, terminal: TerminalInfo?, mod: String? = nil,
                tabIsSplit: Bool = false, subtree: [SubAgent] = [], tree: [TreeNode]? = nil,
                urgency: AgentStatus? = nil) {
        self.kind = kind; self.paneID = paneID; self.tabID = tabID; self.terminal = terminal
        self.mod = mod; self.tabIsSplit = tabIsSplit; self.subtree = subtree
        self.tree = tree ?? subtree.map(TreeNode.kid)
        self.urgency = urgency ?? terminal?.status
    }

    /// This row's pane, then its kept sub-agents' panes (the order ⌘] steps through).
    public var paneIDs: [String] { [paneID] + subtree.compactMap(\.paneID) }

    /// What its badges count (an agent's row).
    public var kidCounts: KidCounts { KidCounts(terminal: terminal, tree: tree) }
}

// MARK: - Agent counts

/// One agent as the counts count it: a row's agent or one of its sub-agents,
/// each an agent of its own (a sub-agent with its status as it reads under the
/// row, `kidStatus`: never done).
public struct CountedAgent: Hashable, Sendable {
    public var terminal: TerminalInfo
    public var status: AgentStatus
    /// The sub-agent, nil for the row's own agent.
    public var kid: SubAgent?
    /// The pane of the row it shows in.
    public var rowPane: String

    public init(terminal: TerminalInfo, status: AgentStatus, kid: SubAgent? = nil, rowPane: String) {
        self.terminal = terminal; self.status = status; self.kid = kid; self.rowPane = rowPane
    }
}

extension Sequence where Element == SidebarRow {
    /// The agents these rows count, in their order: each agent row's agent, then its
    /// sub-agents. A terminal counts once (one in two panes has two rows).
    public var countedAgents: [CountedAgent] {
        var out: [CountedAgent] = []
        var seen: Set<String> = []
        for row in self where row.kind == .agent {
            if let t = row.terminal, let s = t.status, seen.insert(t.address).inserted {
                out.append(CountedAgent(terminal: t, status: s, rowPane: row.paneID))
            }
            for kid in row.subtree {
                guard let s = kid.terminal.kidStatus, seen.insert(kid.terminal.address).inserted else { continue }
                out.append(CountedAgent(terminal: kid.terminal, status: s, kid: kid, rowPane: row.paneID))
            }
        }
        return out
    }
}

/// What a space holds, as its rows show it (the Go to panel's line under a space).
public struct SpaceTally: Hashable, Sendable {
    /// Its agents with a pane (rows of their own).
    public var agents: Int
    /// Their sub-agents: those with a terminal (under them in the list) and those
    /// they run in-process (`TerminalInfo.inProcessAgents`: pi's `agent.subagents`,
    /// Claude Code's sub-agent records), as the rows' badges count them.
    public var subAgents: Int
    /// Its plain terminals, those its agents started and the background shells they report.
    public var terminals: Int

    public init(agents: Int = 0, subAgents: Int = 0, terminals: Int = 0) {
        self.agents = agents; self.subAgents = subAgents; self.terminals = terminals
    }
}

extension Sequence where Element == SidebarRow {
    /// How many agents, sub-agents and terminals these rows show, each terminal once.
    public var tally: SpaceTally {
        var agents: Set<String> = [], kids: Set<String> = [], terminals: Set<String> = []
        var inner = 0, shells = 0
        // Each terminal's in-process work once (one in two panes has two rows).
        var owners: Set<String> = []
        func own(_ t: TerminalInfo) {
            guard owners.insert(t.address).inserted else { return }
            inner += t.inProcessAgents
            shells += t.backgroundShells
        }
        for row in self {
            switch row.kind {
            case .agent:
                if let t = row.terminal {
                    agents.insert(t.address)
                    own(t)
                }
                for kid in row.subtree {
                    if kid.isAgent { kids.insert(kid.terminal.address) } else { terminals.insert(kid.terminal.address) }
                    own(kid.terminal)
                }
            case .terminal:
                terminals.insert(row.terminal?.address ?? row.paneID)
            case .mod:
                break
            }
        }
        return SpaceTally(agents: agents.count, subAgents: kids.count + inner, terminals: terminals.count + shells)
    }
}

extension Sequence where Element == CountedAgent {
    /// How many have each status.
    public var byStatus: [AgentStatus: Int] {
        var out: [AgentStatus: Int] = [:]
        for a in self { out[a.status, default: 0] += 1 }
        return out
    }
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
