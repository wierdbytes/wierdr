import Foundation
import HerdrCore

/// Drives a `Workspace` from herdr-core: the terminal event stream, the
/// per-machine `herdr-app` documents, machines, git/colors/launcher facts,
/// and the commands (`WorkspaceBackend`) with herdr-app's exact semantics.
///
/// One engine per workspace. Call `run(on:)` with a started (or idle)
/// connection; it returns when the connection closes (throws when it dropped).
/// To reconnect, call `run(on:)` again with a new connection: the workspace
/// keeps showing the last state until the new one is loaded.
@MainActor
public final class WorkspaceEngine: WorkspaceBackend {
    public let workspace: Workspace
    public let options: EngineOptions
    /// Colors and cell size for terminals this engine starts (`terminal.run`).
    public var display: Display?
    /// The pane that has the keyboard in a tab on this screen (`ScreenState`),
    /// used to pick the folder of a new tab like herdr-app does.
    public var focusedPaneProvider: ((_ tabID: String) -> String?)?
    /// Diagnostics (write failures, retries, cleanups).
    public var log: ((String) -> Void)?
    /// Every core event, after the engine handled it (e.g. the app reattaches
    /// terminal views on `restarted`).
    public var onEvent: ((CoreEvent) -> Void)?

    // MARK: Session state

    private var connection: CoreConnection?
    private var session = 0
    private var hello: HelloResult?
    private var records: [String: Terminal] = [:]
    private var seq: UInt64 = 0
    private var slots: [String: DocSlot] = [:]
    private var machineList: [HerdrCore.Machine] = []
    private var tasks: [Task<Void, Never>] = []
    private var writeTails: [String: Task<Void, Never>] = [:]
    private var machinesRefresh: Task<Void, Never>?

    // Seen (docs/labels.md): what we wrote, what we looked at, the local flag.
    private var writtenSeen: [String: UInt64] = [:]
    private var looked: [String: UInt64] = [:]
    private var localSeen: [String: Bool] = [:]
    private var lastWord: [String: String?] = [:]

    // Facts.
    private var homes: [String: String] = [:]
    private var gitCache: [GitKey: GitEntry] = [:]
    private var gitInFlight: Set<GitKey> = []
    private var sharedColors: [String: String] = [:]
    private var installed: [String: (at: Date, commands: Set<String>?)] = [:]
    private var launcherChecks: Set<String> = []
    private var born: [String: Date] = [:]
    private var missingSince: [String: Date] = [:]
    private var cleaning: Set<String> = []

    /// How long after a terminal ended its pane is removed (a running desktop usually does it first).
    var deadPaneDelay: Duration = .seconds(3)

    // Rebuild coalescing.
    private var rebuildScheduled = false
    private var lastRebuild = Date.distantPast

    struct DocSlot {
        enum State: Equatable { case loading, ready, unavailable(String), blocked(String) }
        var raw: JSONValue = .null
        var version: UInt64 = 0
        var state: State = .loading
        /// Read successfully at least once (its spaces can be shown).
        var loaded = false
        var connected = true
        var sinceMs: UInt64?
        var reading = false
        var rereadNeeded = false
    }

    struct GitKey: Hashable { var machine: String; var cwd: String }
    struct GitEntry { var at: Date; var info: GitInfo? }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    public init(workspace: Workspace, options: EngineOptions = .init()) {
        self.workspace = workspace
        self.options = options
        display = options.display
        workspace.backend = self
    }

    private func label(_ name: String) -> String { "\(options.labelPrefix).\(name)" }

    private func emit(_ message: String) { log?(message) }

    // MARK: - Run

    /// Drives the workspace until the connection closes. Throws the
    /// `ConnectionError` when it dropped; returns when it was closed on purpose.
    public func run(on connection: CoreConnection) async throws {
        if case .idle = connection.state { try await connection.start() }
        guard case .open(let hello) = connection.state else {
            if case .closed(let e) = connection.state { throw e }
            throw ConnectionError.notStarted
        }
        session += 1
        let me = session
        tasks.forEach { $0.cancel() }
        tasks = []
        writeTails = [:]
        self.connection = connection
        self.hello = hello
        workspace.backend = self
        switch workspace.phase {
        case .live, .failed: workspace.phase = .connecting
        default: break
        }
        writtenSeen = [:]
        looked = [:]
        for key in slots.keys {
            slots[key]?.state = .loading
            slots[key]?.reading = false
            slots[key]?.rereadNeeded = false
        }
        defer {
            if session == me {
                tasks.forEach { $0.cancel() }
                tasks = []
                machinesRefresh?.cancel()
                self.connection = nil
            }
        }

        // Subscribe first, then documents (so no doc change is missed).
        let sub = try await connection.subscribe()
        records = Dictionary(sub.terminals.map { ($0.address, $0) }, uniquingKeysWith: { _, b in b })
        seq = sub.seq
        for (a, t) in records where lastWord[a] == nil { lastWord[a] = StatusRule.word(t) }
        if slots[""] == nil { slots[""] = DocSlot() }
        let machines = (try? await connection.listMachines()) ?? []
        guard session == me else { return }
        applyMachines(machines, readNew: false)
        let initial = slots.filter { $0.value.connected }.map(\.key)
        await withTaskGroup(of: Void.self) { group in
            for key in initial { group.addTask { await self.readDoc(key, session: me) } }
            group.addTask { await self.fetchHome("", me) }
        }
        await readColors(me)  // first paint with the desktop's names and colors
        guard session == me else { return }
        rebuild()
        workspace.phase = .live

        startBackground(me)
        for await event in sub.events {
            guard session == me else { break }
            handle(event)
            onEvent?(event)
        }
        sub.cancel()
        guard session == me else { return }
        if !connection.state.isClosed { try? await Task.sleep(for: .milliseconds(200)) }
        let why: ConnectionError
        if case .closed(let e) = connection.state {
            why = e
        } else {
            why = .disconnected("event stream ended")
            await connection.close()
        }
        if why != .closed { throw why }
    }

    private func startBackground(_ me: Int) {
        // Machines (and dead panes) every few seconds.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session == me else { return }
                try? await Task.sleep(for: .seconds(self.options.machinePollInterval))
                guard self.session == me, !Task.isCancelled else { return }
                await self.refreshMachines(me)
                await self.checkMissingPanes(me)
                self.refreshGit()
            }
        })
        // Homes, colors, launchers.
        tasks.append(Task { [weak self] in
            guard let self else { return }
            self.refreshLaunchers(machine: nil)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.options.refreshInterval))
                guard self.session == me, !Task.isCancelled else { return }
                await self.readColors(me)
            }
        })
    }

    // MARK: - Events

    private func handle(_ e: CoreEvent) {
        switch e.kind {
        case .heartbeat:
            return
        case .missed(let fresh):
            records = Dictionary(fresh.map { ($0.address, $0) }, uniquingKeysWith: { _, b in b })
            seq = e.seq
            for (a, _) in records { noteWord(a) }
            for key in slots.keys { requestRead(key) }
            scheduleMachinesRefresh()
            scheduleRebuild()
            return
        default:
            break
        }
        guard e.seq > seq else { return }
        seq = e.seq
        switch e.kind {
        case .created(let t), .restarted(let t):
            records[t.address] = t
            noteWord(t.address)
            if LayoutID.machine(of: t.address) != nil { scheduleMachinesRefresh() }
        case .removed:
            if let a = e.terminal { records[a] = nil }
        case .labels(_, let record?):
            records[record.address] = record
        case .doc(let name, let version):
            guard name == options.documentName else { return }
            let key = e.machine ?? ""
            if let slot = slots[key], slot.state == .ready, slot.version >= version { return }
            requestRead(key)
            return
        case .finished(let end):
            if let a = e.terminal {
                records[a]?.apply(e.kind)
                if end.reason == "exited" || end.reason == "killed" { scheduleDeadPane(a) }
            }
        default:
            if let a = e.terminal {
                records[a]?.apply(e.kind)
                if case .status = e.kind { noteWord(a) }
            }
        }
        scheduleRebuild()
    }

    /// The local "seen" flag, for agents without a shared `herdr.seen` (`Model::set_word`).
    private func noteWord(_ address: String) {
        let word = records[address].flatMap(StatusRule.word)
        guard let previous = lastWord[address] else {
            lastWord[address] = .some(word)
            return
        }
        guard previous != word else { return }
        let wasBusy = previous == "working" || previous == "blocked"
        if word == "working" || word == "blocked" {
            localSeen[address] = true
        } else if word != nil, wasBusy {
            localSeen[address] = false
        }
        lastWord[address] = .some(word)
    }

    // MARK: - Machines

    private func scheduleMachinesRefresh() {
        guard machinesRefresh == nil else { return }
        let me = session
        machinesRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.machinesRefresh = nil
            await self.refreshMachines(me)
        }
    }

    private func refreshMachines(_ me: Int) async {
        guard let c = connection, session == me else { return }
        guard let list = try? await c.listMachines(), session == me else { return }
        applyMachines(list, readNew: true)
    }

    private func applyMachines(_ list: [HerdrCore.Machine], readNew: Bool) {
        let visible = list.filter { !$0.temporary }.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        let old = Set(machineList.map(\.name))
        machineList = visible
        var changed = false
        for m in visible {
            var slot = slots[m.name] ?? DocSlot()
            let fresh = slots[m.name] == nil
            if m.isConnected {
                if fresh || !slot.connected || slot.sinceMs != m.sinceMs {
                    slot.connected = true
                    slot.sinceMs = m.sinceMs
                    slot.state = .loading
                    slots[m.name] = slot
                    changed = true
                    if readNew { requestRead(m.name) }
                    if homes[m.name] == nil {
                        let me = session, name = m.name
                        tasks.append(Task { [weak self] in await self?.fetchHome(name, me) })
                    }
                    continue
                }
            } else {
                slot.connected = false
                let state = m.state.replacingOccurrences(of: "_", with: " ")
                let new: DocSlot.State = (m.state == "needs_update" || m.state == "needs_login")
                    ? .blocked("\(m.name) \(state): hc machine \(m.state == "needs_update" ? "update" : "login") \(m.name)")
                    : .unavailable(m.why.map { "\(state): \($0)" } ?? state)
                if slot.state != new { slot.state = new; changed = true }
            }
            slots[m.name] = slot
        }
        for key in slots.keys where !key.isEmpty && !visible.contains(where: { $0.name == key }) {
            slots[key] = nil
            changed = true
        }
        if changed || old != Set(visible.map(\.name)) { scheduleRebuild() }
    }

    // MARK: - Documents

    private func requestRead(_ key: String) {
        guard slots[key] != nil, connection != nil else { return }
        if slots[key]!.reading {
            slots[key]!.rereadNeeded = true
            return
        }
        slots[key]!.reading = true
        let me = session
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.slots[key]?.rereadNeeded = false
                await self.readDoc(key, session: me)
            } while self.session == me && self.slots[key]?.rereadNeeded == true
            if self.session == me { self.slots[key]?.reading = false }
        }
    }

    private func readDoc(_ key: String, session me: Int) async {
        guard let c = connection, slots[key] != nil else { return }
        do {
            let doc = try await c.getDoc(options.documentName, on: key.isEmpty ? nil : key)
            guard session == me else { return }
            applyRead(key, doc)
        } catch let e as CoreError {
            guard session == me, slots[key] != nil else { return }
            if e.kind == "needs_update" || e.kind == "needs_login" {
                slots[key]?.state = .blocked(e.description)
            } else {
                slots[key]?.state = .unavailable(e.message)
            }
        } catch {
            guard session == me, slots[key] != nil else { return }
            if !(error is ConnectionError) { slots[key]?.state = .unavailable("\(error)") }
        }
        scheduleRebuild()
    }

    private func applyRead(_ key: String, _ doc: HerdrCore.Document) {
        guard var slot = slots[key] else { return }
        if slot.state == .ready, doc.version < slot.version { return }  // an older read overtaken by our write
        do {
            try LayoutValidator.decode(doc.value)
        } catch {
            slot.state = .unavailable("Cannot read this machine's layout: \(error)")
            slot.version = doc.version
            slots[key] = slot
            emit("layout of \(key.isEmpty ? "this computer" : key) is undecodable: \(error)")
            return
        }
        slot.raw = doc.value
        slot.version = doc.version
        slot.state = .ready
        slot.loaded = true
        slots[key] = slot
        scheduleRebuild()
    }

    /// One CAS writer per machine: intents run one after another.
    private func serialized<T>(_ key: String, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = writeTails[key]
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await op()
        }
        writeTails[key] = Task { @MainActor in _ = try? await task.value }
        return try await task.value
    }

    /// Applies `intent` to the freshest document of a machine and writes it
    /// with compare-and-swap; on a conflict re-reads and re-applies (≤ 5 tries).
    /// Returns false when the intent no longer applied (nothing written).
    @discardableResult
    func write(_ key: String, _ intent: @escaping (JSONValue) -> JSONValue?) async throws -> Bool {
        try await serialized(key) { [self] in
            guard options.allowWrites else { throw WorkspaceError.core("Writing is disabled") }
            let machine = key.isEmpty ? nil : key
            for attempt in 1...5 {
                guard let c = connection else { throw WorkspaceError.notConnected }
                guard let slot = slots[key], slot.state == .ready else { throw WorkspaceError.layoutUnavailable(machine: machine) }
                guard let new = intent(slot.raw), new != slot.raw else { return false }
                do {
                    try LayoutValidator.checkWrite(new, base: slot.raw)
                } catch {
                    emit("refused write to \(key): \(error)")
                    throw WorkspaceError.core("\(error)")
                }
                do {
                    let version = try await c.setDoc(options.documentName, value: new, version: slot.version, on: machine)
                    if var s = slots[key], s.version <= version {
                        s.raw = new
                        s.version = version
                        slots[key] = s
                    }
                    scheduleRebuild()
                    return true
                } catch is DocConflict {
                    emit("layout of \(key.isEmpty ? "this computer" : key) changed meanwhile (try \(attempt)); re-reading")
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 100...400)))
                    await readDoc(key, session: session)
                } catch let e as CoreError {
                    if e.kind == "needs_update" || e.kind == "needs_login" {
                        slots[key]?.state = .blocked(e.description)
                        scheduleRebuild()
                    }
                    throw WorkspaceError.core(e.message)
                } catch is ConnectionError {
                    throw WorkspaceError.notConnected
                }
            }
            throw WorkspaceError.conflict
        }
    }

    private func requireDocument(_ key: String) throws -> CoreConnection {
        guard let c = connection else { throw WorkspaceError.notConnected }
        guard options.allowWrites else { throw WorkspaceError.core("Writing is disabled") }
        guard let slot = slots[key], slot.state == .ready else {
            throw WorkspaceError.layoutUnavailable(machine: key.isEmpty ? nil : key)
        }
        return c
    }

    // MARK: - Terminals

    private func runParams(_ argv: [String], cwd: String?, space: String, tab: String, machine: String?) -> RunParams {
        RunParams(argv: argv, cwd: cwd.flatMap { $0.isEmpty ? nil : $0 },
                  labels: [label("space"): space, label("tab"): tab, label("seen"): "0"],
                  env: ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"],
                  keep: true, display: display, noParent: true, on: machine)
    }

    /// `AppWindow::spawn` + `run_following_folder`: an inherited folder that
    /// fails to spawn gets one retry in the machine's home.
    private func spawn(_ c: CoreConnection, argv: [String], cwd: String, follow: Bool, space: String, tab: String,
                       machine: String?) async throws -> (address: String, folder: String) {
        do {
            let r = try await c.runTerminal(runParams(argv, cwd: cwd, space: space, tab: tab, machine: machine))
            born[r.terminal.address] = Date()
            return (r.terminal.address, cwd)
        } catch let e as CoreError where follow && !cwd.isEmpty && e.kind == "spawn_failed"
                    && !e.message.contains("the holder did not answer") {
            let home = machine == nil ? (homes[""] ?? "") : ""
            do {
                let r = try await c.runTerminal(runParams(argv, cwd: home, space: space, tab: tab, machine: machine))
                born[r.terminal.address] = Date()
                return (r.terminal.address, home)
            } catch let e as CoreError {
                throw WorkspaceError.core("Cannot start a terminal: \(e.message)")
            }
        } catch let e as CoreError {
            throw WorkspaceError.core("Cannot start a terminal: \(e.message)")
        } catch is ConnectionError {
            throw WorkspaceError.notConnected
        }
    }

    private func argv(_ launch: Launch) -> [String] {
        switch launch {
        case .shell: return []
        case .agent(let launcher, let task):
            return launcher.run.isEmpty ? [] : LaunchArgv.agent(launcher.run, task: task)
        }
    }

    /// Kills terminals and their non-kept descendants (`AppWindow::kill`).
    private func kill(_ addresses: [String]) async {
        guard let c = connection, options.allowWrites else { return }
        var doomed = addresses
        var i = 0
        while i < doomed.count {
            let parent = doomed[i]
            for (a, rec) in records.sorted(by: { $0.key < $1.key }) {
                let child = rec.parent.flatMap(normalizeParent) == parent
                let kept = !(rec.labels[label("space")] ?? "").isEmpty
                if child, !kept, !doomed.contains(a) { doomed.append(a) }
            }
            i += 1
        }
        for a in doomed {
            do { try await c.killTerminal(a) } catch { emit("kill \(a): \(error)") }
        }
    }

    /// Parent references may use the core's own or a machine's host name
    /// (`EventLines::live_for`): to this connection's addresses.
    private func normalizeParent(_ parent: String) -> String? {
        guard let slash = parent.firstIndex(of: "/") else { return parent }
        let prefix = String(parent[..<slash]), id = String(parent[parent.index(after: slash)...])
        if prefix == hello?.core.id || prefix == hello?.core.name { return id }
        if let m = machineList.first(where: { $0.name == prefix || $0.id == prefix }) { return "\(m.name)/\(id)" }
        let hosts = machineList.filter { $0.host == prefix }
        if hosts.count == 1 { return "\(hosts[0].name)/\(id)" }
        return parent
    }

    // MARK: - Commands

    private func key(of id: String) -> (key: String, machine: String?, local: String) {
        let machine = LayoutID.machine(of: id)
        return (machine ?? "", machine, LayoutID.local(id, machine))
    }

    private func liveCwd(_ address: String?) -> String? {
        guard let address, let t = records[address] else { return nil }
        return [t.foreground?.cwd, t.cwd].compactMap { $0 }.first { !$0.isEmpty }
    }

    func newSpace(machine: String?, name: String, folder: String?, launch: Launch, after: String?) async throws -> String {
        let key = machine ?? ""
        let c = try requireDocument(key)
        let (sp, tb, p) = (LayoutID.fresh("sp"), LayoutID.fresh("tb"), LayoutID.fresh("p"))
        let follow = folder == nil
        let cwd = folder ?? (machine == nil ? (homes[""] ?? "") : "")
        let (address, used) = try await spawn(c, argv: argv(launch), cwd: cwd, follow: follow, space: sp, tab: tb, machine: machine)
        let local = LayoutID.local(address, machine)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterLocal = after.map { LayoutID.local($0, machine) }
        do {
            try await write(key) { LayoutEdits.newSpace($0, id: sp, name: trimmed, folder: used, tabID: tb, paneID: p,
                                                         address: local, after: afterLocal) }
        } catch {
            if slots[key]?.raw.paneShowing(local) == nil { await kill([address]) }
            throw error
        }
        return LayoutID.qualify(sp, machine)
    }

    func newTab(in spaceID: String, after: String?, name: String, launch: Launch) async throws -> String {
        let (key, machine, localSpace) = key(of: spaceID)
        let c = try requireDocument(key)
        guard let space = workspace.space(spaceID) ?? spaceFromDoc(spaceID) else { throw WorkspaceError.notFound("Space") }
        // herdr-app's folder_for: the live folder of the tab's focused pane, else the space's folder, else home.
        let tab = space.tabs.first { $0.id == after } ?? space.tabs.first
        let pane = tab.flatMap { t in focusedPaneProvider?(t.id).flatMap { id in t.panes.first { $0.id == id } } ?? t.panes.first { $0.terminal != nil } }
        let cwd = liveCwd(pane?.terminal) ?? (space.folder.isEmpty ? nil : space.folder) ?? (machine == nil ? (homes[""] ?? "") : "")
        let (tb, p) = (LayoutID.fresh("tb"), LayoutID.fresh("p"))
        let (address, _) = try await spawn(c, argv: argv(launch), cwd: cwd, follow: true, space: localSpace, tab: tb, machine: machine)
        let local = LayoutID.local(address, machine)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterLocal = after.map { LayoutID.local($0, machine) }
        do {
            try await write(key) { LayoutEdits.newTab($0, space: localSpace, after: afterLocal, id: tb, name: trimmed,
                                                       paneID: p, address: local) }
        } catch {
            if slots[key]?.raw.paneShowing(local) == nil { await kill([address]) }
            throw error
        }
        if slots[key]?.raw.paneShowing(local) == nil, slots[key]?.raw.locateSpace(localSpace) == nil {
            // The space closed meanwhile: the terminal has nowhere to go.
            await kill([address])
            throw WorkspaceError.notFound("Space")
        }
        return LayoutID.qualify(tb, machine)
    }

    func split(pane paneID: String, direction: SplitDirection, launch: Launch) async throws -> String {
        let (key, machine, localPane) = key(of: paneID)
        let c = try requireDocument(key)
        guard let loc = slots[key]?.raw.locateNode(localPane),
              let target = slots[key]?.raw.layoutSpaces[loc.space].layoutTabs[loc.tab ?? 0]["root"]?.findNode(localPane),
              target.isPaneNode else { throw WorkspaceError.notFound("Pane") }
        let space = slots[key]!.raw.layoutSpaces[loc.space]
        let tabID = space.layoutTabs[loc.tab ?? 0].nodeID
        let targetAddress = target.paneTerminal.map { LayoutID.qualify($0, machine) }
        let folder = space["folder"]?.string ?? ""
        let cwd = liveCwd(targetAddress) ?? folder
        let p = LayoutID.fresh("p")
        let (address, _) = try await spawn(c, argv: argv(launch), cwd: cwd, follow: true, space: space.nodeID, tab: tabID, machine: machine)
        let local = LayoutID.local(address, machine)
        let axis = direction == .right ? "row" : "column"
        let container = LayoutID.fresh("s")
        do {
            try await write(key) { LayoutEdits.split($0, target: localPane, axis: axis, paneID: p, containerID: container, address: local) }
        } catch {
            if slots[key]?.raw.paneShowing(local) == nil { await kill([address]) }
            throw error
        }
        if let placed = slots[key]?.raw.paneShowing(local) {
            return LayoutID.qualify(placed.pane, machine)
        }
        await kill([address])
        throw WorkspaceError.notFound("Pane")
    }

    private func spaceFromDoc(_ id: String) -> Space? {
        let (key, machine, _) = key(of: id)
        guard let raw = slots[key]?.raw else { return nil }
        return LayoutParser.spaces(raw, machine: machine).first { $0.id == id }
    }

    /// Runs a removing intent, then kills what it removed.
    private func remove(_ id: String, _ edit: @escaping (JSONValue, String) -> (doc: JSONValue, removed: [String])?) async throws {
        let (key, machine, local) = key(of: id)
        _ = try requireDocument(key)
        let removed = Box<[String]>([])
        let wrote = try await write(key) { doc in
            guard let r = edit(doc, local) else { return nil }
            removed.value = r.removed
            return r.doc
        }
        if wrote { await kill(removed.value.map { LayoutID.qualify($0, machine) }) }
    }

    func closePane(_ paneID: String) async throws {
        try await remove(paneID) { LayoutEdits.removePane($0, id: $1) }
    }

    func closeTab(_ tabID: String) async throws {
        try await remove(tabID) { LayoutEdits.removeTab($0, id: $1) }
    }

    func closeSpace(_ spaceID: String) async throws {
        try await remove(spaceID) { LayoutEdits.removeSpace($0, id: $1) }
    }

    func renameSpace(_ spaceID: String, to name: String) async throws {
        let (key, _, local) = key(of: spaceID)
        _ = try requireDocument(key)
        guard slots[key]?.raw.locateSpace(local) != nil else { throw WorkspaceError.notFound("Space") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await write(key) { LayoutEdits.renameSpace($0, id: local, name: trimmed) }
    }

    func renameTab(_ tabID: String, to name: String) async throws {
        let (key, _, local) = key(of: tabID)
        _ = try requireDocument(key)
        guard slots[key]?.raw.locateTab(local) != nil else { throw WorkspaceError.notFound("Tab") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await write(key) { LayoutEdits.renameTab($0, id: local, name: trimmed) }
    }

    func moveTab(_ tabID: String, to index: Int) async throws {
        let (key, _, local) = key(of: tabID)
        _ = try requireDocument(key)
        guard slots[key]?.raw.locateTab(local) != nil else { throw WorkspaceError.notFound("Tab") }
        try await write(key) { LayoutEdits.moveTab($0, id: local, to: index) }
    }

    // MARK: Seen, unread, pinned

    private func seenTurn(_ t: Terminal) -> UInt64? {
        let label = t.labels[label("seen")].flatMap { UInt64($0) }
        let pending = writtenSeen[t.address]
        switch (label, pending) {
        case let (l?, p?): return max(l, p)
        case let (l?, nil): return l
        case let (nil, p?): return p
        default: return nil
        }
    }

    func markSeen(_ addresses: [String]) {
        var changed = false
        for addr in addresses {
            guard let t = records[addr], t.isLive, StatusRule.word(t) != nil else { continue }
            if localSeen[addr] == false { localSeen[addr] = true; changed = true }
            let turn = t.turn
            if looked[addr] == turn { continue }
            looked[addr] = turn
            if let s = seenTurn(t), s >= turn { continue }
            guard options.allowWrites, let c = connection else { continue }
            writtenSeen[addr] = turn
            changed = true
            let key = label("seen")
            Task { [weak self] in
                do {
                    try await c.labelTerminal(addr, [key: String(turn)])
                } catch {
                    guard let self else { return }
                    self.emit("seen label for \(addr): \(error)")
                    if self.writtenSeen[addr] == turn {
                        self.writtenSeen[addr] = nil
                        self.looked[addr] = nil
                        self.scheduleRebuild()
                    }
                }
            }
        }
        if changed { scheduleRebuild() }
    }

    func markUnread(_ address: String) {
        guard let t = records[address], StatusRule.word(t) != nil else { return }
        localSeen[address] = false
        looked[address] = t.turn
        writtenSeen[address] = nil
        if t.turn > 0, options.allowWrites, let c = connection {
            let value = String(t.turn - 1)
            // Shown at once; the label event confirms it.
            records[address]?.labels[label("seen")] = value
            let key = label("seen")
            Task { [weak self] in
                do { try await c.labelTerminal(address, [key: value]) } catch { self?.emit("unread label for \(address): \(error)") }
            }
        }
        scheduleRebuild()
    }

    func setPinned(_ address: String, _ pinned: Bool) {
        guard options.allowWrites, let c = connection, records[address] != nil else { return }
        let key = label("pinned"), value = pinned ? "1" : ""
        if pinned { records[address]?.labels[key] = value } else { records[address]?.labels[key] = nil }
        scheduleRebuild()
        Task { [weak self] in
            do { try await c.labelTerminal(address, [key: value]) } catch { self?.emit("pin \(address): \(error)") }
        }
    }

    // MARK: Launchers

    func refreshLaunchers(machine: String?) {
        let key = machine ?? ""
        guard let c = connection, !launcherChecks.contains(key) else { return }
        if let cached = installed[key], Date().timeIntervalSince(cached.at) < 60, cached.commands != nil { return }
        launcherChecks.insert(key)
        let commands = ProgramTable.builtIn.startable.compactMap(\.run.first)
        let me = session
        Task { [weak self] in
            let result = try? await c.exec(ExecParams(argv: LaunchArgv.check(commands), on: machine, timeout: 30))
            guard let self else { return }
            self.launcherChecks.remove(key)
            guard self.session == me else { return }
            let found = result.flatMap { LaunchArgv.installed(commands, output: $0.stdoutText, code: $0.code) }
            self.installed[key] = (Date(), found)
            self.scheduleRebuild()
        }
    }

    // MARK: - Facts: home, colors, git

    private func fetchHome(_ key: String, _ me: Int) async {
        guard let c = connection, session == me, homes[key] == nil else { return }
        let params = ExecParams(argv: ["sh", "-c", "printf %s \"$HOME\""], on: key.isEmpty ? nil : key, timeout: 15)
        guard let r = try? await c.exec(params), r.code == 0, session == me else { return }
        let home = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return }
        homes[key] = home
        scheduleRebuild()
    }

    private func readColors(_ me: Int) async {
        guard let c = connection, session == me, let home = homes[""] else { return }
        let path = "\(home)/.config/herdr-app/shared.json"
        var text = ""
        do {
            var offset = 1
            while true {
                let r = try await c.readFile(path, offset: offset, limit: 5000)
                text += (text.isEmpty ? "" : "\n") + r.text
                if r.last >= r.lines || r.last < offset { break }
                offset = r.last + 1
            }
        } catch {
            return  // no shared.json: colors by the palette rule
        }
        guard session == me, let json = try? JSONValue(parsing: text) else { return }
        var colors: [String: String] = [:]
        for (k, v) in json["space.colors"]?.object ?? JSONObject() { if let s = v.string { colors[k] = s } }
        if colors != sharedColors {
            sharedColors = colors
            scheduleRebuild()
        }
    }

    /// Git facts for each space's first terminal folder; stale after the refresh interval.
    private func refreshGit() {
        let now = Date()
        gitCache = gitCache.filter { now.timeIntervalSince($0.value.at) < 10 * options.refreshInterval }
        for (key, slot) in slots where slot.loaded {
            let machine = key.isEmpty ? nil : key
            for space in LayoutParser.spaces(slot.raw, machine: machine) {
                guard let cwd = firstTerminalCwd(space) else { continue }
                let gk = GitKey(machine: key, cwd: cwd)
                if let e = gitCache[gk], now.timeIntervalSince(e.at) < options.refreshInterval { continue }
                probeGit(gk)
            }
        }
    }

    private func firstTerminalCwd(_ space: Space) -> String? {
        let address = space.tabs.lazy.flatMap(\.panes).compactMap(\.terminal).first
        return liveCwd(address)
    }

    private func probeGit(_ gk: GitKey) {
        guard let c = connection, !gitInFlight.contains(gk) else { return }
        if gk.machine.isEmpty, let home = homes[""], gk.cwd == home {
            gitCache[gk] = GitEntry(at: Date(), info: nil)
            return
        }
        gitInFlight.insert(gk)
        let me = session
        Task { [weak self] in
            let info = await Self.gitInfo(c, cwd: gk.cwd, on: gk.machine.isEmpty ? nil : gk.machine)
            guard let self else { return }
            self.gitInFlight.remove(gk)
            guard self.session == me else { return }
            let changed = self.gitCache[gk]?.info != info || self.gitCache[gk] == nil
            self.gitCache[gk] = GitEntry(at: Date(), info: info)
            if changed { self.scheduleRebuild() }
        }
    }

    /// `folder_info` plus repo name, worktree and ahead/behind. Nil: not a repo (or git failed).
    nonisolated static func gitInfo(_ c: CoreConnection, cwd: String, on machine: String?) async -> GitInfo? {
        func git(_ args: [String], in dir: String) async -> String? {
            let params = ExecParams(argv: ["git", "--no-optional-locks", "-C", dir] + args, on: machine, timeout: 10)
            guard let r = try? await c.exec(params), r.code == 0 else { return nil }
            return r.stdoutText
        }
        guard let out = await git(["rev-parse", "--show-toplevel", "--abbrev-ref", "HEAD"], in: cwd) else { return nil }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return nil }
        let top = lines[0], head = lines[1]
        var info = GitInfo(top: top, repo: SpaceNaming.folderName(top, home: nil), branch: head == "HEAD" ? nil : head)
        if let common = await git(["rev-parse", "--git-common-dir"], in: top)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !common.isEmpty {
            let abs = common.hasPrefix("/") ? common : "\(top)/\(common)"
            let path = URL(fileURLWithPath: abs).standardizedFileURL.path
            let own = URL(fileURLWithPath: "\(top)/.git").standardizedFileURL.path
            if path != own {
                info.isWorktree = true
                let repoDir = path.hasSuffix("/.git") ? String(path.dropLast(5)) : path
                info.repo = SpaceNaming.folderName(repoDir, home: nil)
            }
        }
        if info.branch != nil,
           let counts = await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: top) {
            let n = counts.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
            if n.count == 2 { info.ahead = n[0]; info.behind = n[1] }
        }
        return info
    }

    // MARK: - Dead panes (§4.3)

    private func scheduleDeadPane(_ address: String) {
        guard options.allowWrites else { return }
        let me = session
        Task { [weak self] in
            // Let a running desktop clean up first (it ticks every 500 ms): fewer racing writes.
            guard let delay = self?.deadPaneDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, self.session == me else { return }
            guard let t = self.records[address], t.isFinished, t.reason == "exited" || t.reason == "killed" else { return }
            await self.removeDeadPane(address)
        }
    }

    private func removeDeadPane(_ address: String) async {
        let (key, machine, local) = key(of: address)
        guard !cleaning.contains(address), slots[key]?.state == .ready,
              let placed = slots[key]?.raw.paneShowing(local) else { return }
        cleaning.insert(address)
        defer { cleaning.remove(address) }
        emit("removing the pane of ended terminal \(address)")
        let pane = placed.pane
        do {
            try await write(key) { LayoutEdits.removePane($0, id: pane, expecting: local)?.doc }
        } catch {
            emit("dead pane \(LayoutID.qualify(pane, machine)): \(error)")
        }
    }

    /// Panes whose terminal is not live: asks the core, removes the pane only on
    /// evidence it ended (`exited`/`killed`, or `not_found`).
    private func checkMissingPanes(_ me: Int) async {
        guard options.allowWrites, let c = connection, session == me else { return }
        let now = Date()
        var missing: [String] = []
        for (key, slot) in slots where slot.state == .ready && slot.connected {
            let machine = key.isEmpty ? nil : key
            for s in slot.raw.layoutSpaces {
                for t in s.layoutTabs {
                    for a in t["root"]?.terminalAddresses ?? [] {
                        let q = LayoutID.qualify(a, machine)
                        if let r = records[q], r.isLive { continue }
                        if let b = born[q], now.timeIntervalSince(b) < 5 { continue }
                        missing.append(q)
                    }
                }
            }
        }
        let set = Set(missing)
        missingSince = missingSince.filter { set.contains($0.key) }
        born = born.filter { now.timeIntervalSince($0.value) < 30 }
        for q in missing {
            guard let since = missingSince[q] else { missingSince[q] = now; continue }
            guard now.timeIntervalSince(since) >= 5 else { continue }
            let ended: Bool
            do {
                let t = try await c.getTerminal(q)
                ended = t.isFinished && (t.reason == "exited" || t.reason == "killed")
            } catch let e as CoreError {
                ended = e.isNotFound
            } catch {
                ended = false
            }
            guard session == me else { return }
            if ended {
                missingSince[q] = nil
                await removeDeadPane(q)
            }
        }
    }

    // MARK: - Rebuild

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        let wait = max(0.0, 0.1 - Date().timeIntervalSince(lastRebuild))
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    /// Recomputes the published state; assigns only what changed.
    func rebuild() {
        lastRebuild = Date()
        let deriver = TerminalDeriver(prefix: options.labelPrefix, parent: { [weak self] in self?.normalizeParent($0) ?? $0 })

        // Spaces from each loaded machine document: this computer first, then machines by name.
        let keys = [""] + machineList.map(\.name)
        var spaces: [Space] = []
        for key in keys {
            guard let slot = slots[key], slot.loaded else { continue }
            spaces += LayoutParser.spaces(slot.raw, machine: key.isEmpty ? nil : key)
        }
        let shown = Set(spaces.flatMap { $0.tabs.flatMap { $0.panes.compactMap(\.terminal) } })

        // Terminals: live ones, plus ended ones still shown in a pane.
        var terminals: [String: TerminalInfo] = [:]
        for (a, t) in records where t.isLive || shown.contains(a) {
            terminals[a] = deriver.info(t, seenTurn: seenTurn(t), locallySeen: localSeen[a] ?? true)
        }

        // Names, git, statuses, colors.
        let home = homes[""]
        var wantGit: [GitKey] = []
        for i in spaces.indices {
            for j in spaces[i].tabs.indices {
                spaces[i].tabs[j].status = AgentStatus.rollup(spaces[i].tabs[j].panes.map { terminals[$0.terminal ?? ""]?.status })
            }
            spaces[i].status = AgentStatus.rollup(spaces[i].tabs.map(\.status))
            let key = spaces[i].machine ?? ""
            var folder = spaces[i].folder
            if let cwd = firstTerminalCwd(spaces[i]) {
                folder = cwd
                let gk = GitKey(machine: key, cwd: cwd)
                if let entry = gitCache[gk] {
                    spaces[i].git = entry.info
                    if let top = entry.info?.top { folder = top }
                } else {
                    wantGit.append(gk)
                }
            }
            if spaces[i].name.isEmpty { spaces[i].displayName = SpaceNaming.folderName(folder, home: home) }
        }
        let colors = SpaceNaming.colors(for: spaces.map { ($0.id, $0.displayName) }, shared: sharedColors)
        for i in spaces.indices { spaces[i].color = colors[spaces[i].id] ?? SpaceNaming.palette[0].hex }

        // Machines.
        func state(_ key: String) -> Machine.State {
            switch slots[key]?.state ?? .loading {
            case .ready: return .ready
            case .loading: return .loading
            case .unavailable(let s), .blocked(let s): return .unavailable(s)
            }
        }
        var machines = [Machine(name: nil, state: state(""), isConnected: connection != nil)]
        machines += machineList.map { Machine(name: $0.name, state: state($0.name), isConnected: $0.isConnected) }

        // Launchers.
        var launchers: [String: [AgentLauncher]] = [:]
        let startable = ProgramTable.builtIn.startable
        for key in keys {
            let found = installed[key]?.commands
            launchers[key] = startable.map { s in
                AgentLauncher(program: s.program, run: s.run, installed: found.map { f in s.run.first.map(f.contains) ?? false })
            }
        }

        if workspace.spaces != spaces { workspace.spaces = spaces }
        if workspace.terminals != terminals { workspace.terminals = terminals }
        if workspace.machines != machines { workspace.machines = machines }
        if workspace.launchers != launchers { workspace.launchers = launchers }
        if workspace.home != home { workspace.home = home }

        for gk in wantGit { probeGit(gk) }
        // Forget per-terminal state of terminals that are gone.
        if records.count < localSeen.count { localSeen = localSeen.filter { records[$0.key] != nil } }
        if records.count < lastWord.count { lastWord = lastWord.filter { records[$0.key] != nil } }
    }

    // MARK: - Testing hooks

    /// The raw document and version of a machine (`""` = this computer), as last read or written.
    func document(_ key: String) -> (value: JSONValue, version: UInt64, state: DocSlot.State)? {
        slots[key].map { ($0.raw, $0.version, $0.state) }
    }

    /// Writes nothing but a fresh read of every document (tests).
    func reloadDocuments() async {
        for key in slots.keys { await readDoc(key, session: session) }
    }
}
