import Foundation
import HerdrCore
import WierdrModel

// MARK: ws

/// `ws [--watch] [--doc NAME] [--prefix P] [--settle SECONDS]`: what WierdrModel
/// builds from the core: machines, spaces, tabs, pane trees with their terminals.
/// Read-only (the engine is started with `allowWrites: false`).
func workspaceCommand(_ options: Options, _ args: [String]) async throws {
    var watch = false
    var engineOptions = EngineOptions(allowWrites: false)
    var settle = 2.0
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--watch": watch = true
        case "--doc": engineOptions.documentName = it.next() ?? engineOptions.documentName
        case "--prefix": engineOptions.labelPrefix = it.next() ?? engineOptions.labelPrefix
        case "--settle": settle = it.next().flatMap(Double.init) ?? settle
        default: throw CLIError.usage("unknown ws option \(a)")
        }
    }
    let connection = try await connect(options)
    let (watch_, settle_, engineOptions_) = (watch, settle, engineOptions)
    await MainActor.run {
        let (watch, settle, engineOptions) = (watch_, settle_, engineOptions_)
        let workspace = Workspace()
        let engine = WorkspaceEngine(workspace: workspace, options: engineOptions)
        engine.log = { FileHandle.standardError.write(Data("[engine] \($0)\n".utf8)) }
        let running = Task { @MainActor in
            do { try await engine.run(on: connection) } catch {
                FileHandle.standardError.write(Data("engine stopped: \(error)\n".utf8))
                exit(1)
            }
        }
        Task { @MainActor in
            let start = Date()
            while workspace.phase != .live {
                guard Date().timeIntervalSince(start) < 20 else {
                    FileHandle.standardError.write(Data("not live after 20 s\n".utf8))
                    exit(1)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Git facts, colors and installed agents arrive a moment later.
            try? await Task.sleep(for: .seconds(settle))
            let lines = render(workspace)
            print(lines.joined(separator: "\n"))
            guard watch else {
                running.cancel()
                await connection.close()
                exit(0)
            }
            var previous = lines
            while true {
                try? await Task.sleep(for: .milliseconds(300))
                let now = render(workspace)
                let time = ISO8601DateFormatter().string(from: Date()).suffix(9).dropLast()
                for line in now where !previous.contains(line) { print("\(time) + \(line.trimmingCharacters(in: .whitespaces))") }
                for line in previous where !now.contains(line) { print("\(time) - \(line.trimmingCharacters(in: .whitespaces))") }
                previous = now
            }
        }
        _ = running
    }
    // Keep the process alive; the tasks above exit it.
    while true { try await Task.sleep(for: .seconds(3600)) }
}

@MainActor
func render(_ ws: Workspace) -> [String] {
    var out: [String] = []
    let home = ws.home
    func short(_ path: String?) -> String {
        guard let path else { return "" }
        if let home, path == home || path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
    func status(_ s: AgentStatus?) -> String {
        guard let s else { return "-" }
        switch s {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .blocked: return "blocked"
        }
    }
    out.append("phase: \(ws.phase)   home: \(home ?? "?")")
    for m in ws.machines {
        let launchers = (ws.launchers[m.id] ?? []).map { "\($0.program.key)\($0.installed == true ? "+" : $0.installed == false ? "-" : "?")" }
        out.append("machine \(m.displayName): \(m.state) connected=\(m.isConnected)  agents: \(launchers.joined(separator: " "))")
    }
    for space in ws.spaces {
        var git = ""
        if let g = space.git {
            git = " git[\(g.repo ?? "?")\(g.branch.map { "@\($0)" } ?? " detached")\(g.ahead > 0 ? " ↑\(g.ahead)" : "")\(g.behind > 0 ? " ↓\(g.behind)" : "")\(g.isWorktree ? " worktree" : "")]"
        }
        out.append("space \(space.id) \"\(space.displayName)\"\(space.name.isEmpty ? "" : " (named)") \(space.color) \(status(space.status)) folder=\(short(space.folder))\(git)")
        for tab in space.tabs {
            out.append("  tab \(tab.id) \"\(tab.displayName)\" \(status(tab.status))")
            func node(_ n: PaneNode, _ depth: Int) {
                let pad = String(repeating: "  ", count: depth)
                let w = n.weight == 1 ? "" : String(format: " w=%.3g", n.weight)
                switch n.kind {
                case .row(let c):
                    out.append("\(pad)row \(n.id)\(w)")
                    c.forEach { node($0, depth + 1) }
                case .column(let c):
                    out.append("\(pad)column \(n.id)\(w)")
                    c.forEach { node($0, depth + 1) }
                case .mod(let name):
                    out.append("\(pad)mod \(name) \(n.id)\(w)")
                case .terminal(let a):
                    guard let t = ws.terminal(a) else {
                        out.append("\(pad)pane \(n.id)\(w) → \(a) (no terminal)")
                        return
                    }
                    var line = "\(pad)pane \(n.id)\(w) → \(a) [\(t.program.key)/\(t.program.name) \(t.program.iconAsset)] proc=\(t.processName ?? "-") \(status(t.status))"
                    if let s = t.state { line += " word=\(s) turn=\(t.turn)" }
                    if t.pinned { line += " pinned" }
                    if !t.isLive { line += " ENDED" }
                    line += " cwd=\(short(t.cwd))"
                    if !t.title.isEmpty { line += " title=\"\(t.title.prefix(50))\"" }
                    if let m = t.meta {
                        line += " meta[\(m.providerAsset ?? m.provider ?? "-") \(m.model ?? "-")\(m.effort.map { " @\($0)" } ?? "") ctx=\(m.ctx.map(String.init) ?? "-")/\(m.ctxMax.map(String.init) ?? "-") sub=\(m.subagents)]"
                    }
                    if ws.isNested(a) { line += " (nested under its parent)" }
                    out.append(line)
                    if ws.isNested(a) { return }
                    for node in ws.tree(of: a) {
                        let lead = node.lines.map { l -> String in
                            switch l { case .tee: return "├ "; case .elbow: return "└ "; case .pipe: return "│ "; case .blank: return "  " }
                        }.joined()
                        switch node {
                        case .kid(let kid):
                            let k = kid.terminal
                            out.append("\(pad)  \(lead)\(k.address) \(k.name ?? k.program.name) \(status(k.kidStatus))\(kid.paneID.map { " kept in \($0)" } ?? "")")
                        case .record(let r):
                            out.append("\(pad)  \(lead)record \(r.record.id) [\(r.record.kind)] \(status(r.record.status)) \"\(r.record.title.prefix(50))\"")
                        }
                    }
                }
            }
            node(tab.root, 2)
        }
    }
    let placed = Set(ws.spaces.flatMap { $0.tabs.flatMap { $0.panes.compactMap(\.terminal) } })
    let loose = ws.terminals.values.filter { !placed.contains($0.address) && $0.parent == nil && $0.isLive }
        .sorted { $0.address < $1.address }
    if !loose.isEmpty {
        out.append("terminals without a pane: " + loose.map { "\($0.address)(\($0.program.key))" }.joined(separator: " "))
        for t in loose where !t.records.isEmpty {
            out.append("  \(t.address) title=\"\(AgentText.title(t, tab: nil))\" records: " + t.records.map {
                "\($0.id) [\($0.kind)] \(status($0.status)) \"\($0.title)\""
            }.joined(separator: ", "))
        }
    }
    return out
}
