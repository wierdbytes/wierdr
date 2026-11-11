import Foundation
import HerdrCore

/// Herdr's program table (`programs.json`, bundled as a resource) and its
/// resolution rules (`src/programs.rs::resolve`): what runs in a terminal, as
/// a name, an icon and a tile.
public final class ProgramTable: Sendable {
    struct Entry: Sendable {
        var name: String?
        var icon: String?
        var tint: Bool?
        var tile: String?
        var color: String?
        var also: [String]
        var run: [String]
    }

    let shells: [String]
    let interpreters: [String]
    /// Sorted by key byte-wise, as Rust's `BTreeMap` iterates.
    let programs: [(key: String, entry: Entry)]
    private let index: [String: Int]

    /// The menu order of startable agents (`AGENTS_FIRST`).
    static let agentsFirst = ["claude", "codex", "pi", "opencode", "cursor", "copilot", "amp", "gemini", "grok"]

    /// The table shipped with Wierdr (a copy of herdr-app's `defaults/programs.json`).
    public static let builtIn: ProgramTable = {
        guard let url = Bundle.module.url(forResource: "programs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? ProgramTable(data: data) else {
            return ProgramTable(shells: [], interpreters: [], programs: [])
        }
        return table
    }()

    init(shells: [String], interpreters: [String], programs: [(String, Entry)]) {
        self.shells = shells
        self.interpreters = interpreters
        let sorted = programs.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        self.programs = sorted.map { (key: $0.0, entry: $0.1) }
        index = Dictionary(sorted.enumerated().map { ($1.0, $0) }, uniquingKeysWith: { a, _ in a })
    }

    convenience init(data: Data) throws {
        let json = try JSONValue(data: data)
        let strings: (JSONValue?) -> [String] = { $0?.array?.compactMap(\.string) ?? [] }
        var list: [(String, Entry)] = []
        for (key, v) in json["programs"]?.object ?? JSONObject() {
            list.append((key, Entry(name: v["name"]?.string, icon: v["icon"]?.string, tint: v["tint"]?.bool,
                                    tile: v["tile"]?.string, color: v["color"]?.string,
                                    also: strings(v["match"]), run: strings(v["run"]))))
        }
        self.init(shells: strings(json["shells"]), interpreters: strings(json["interpreters"]), programs: list)
    }

    // MARK: Resolution

    /// How a terminal shows, from the agent's own report (`app`, OSC 7501) or
    /// else the program it runs (`argv`: foreground argv, else launch argv).
    public func resolve(app: String?, argv: [String]) -> Program {
        if let app, !app.isEmpty {
            if let (key, e) = find(app) { return shown(key, e, name: nil, shell: false, agent: true) }
            return shown("agent", entry("agent"), name: app, shell: false, agent: true)
        }
        // `zsh -ic '"$@"; exec "$0" -i' zsh <cmd>…` (and the remote `sh -c <script> sh <cmd>…`).
        if argv.count > 4, shells.contains(Self.base(argv[0])), argv[1].hasPrefix("-"), argv[1].hasSuffix("c"),
           argv[2].contains("\"$@\"") || argv[2] == "command $argv[2..]; exec $argv[1] -i" {
            return resolve(app: nil, argv: Array(argv[4...]))
        }
        if argv.count == 4, shells.contains(Self.base(argv[0])), argv[1] == "-NoExit", argv[2] == "-Command",
           let words = Self.powershellWords(argv[3]) {
            return resolve(app: nil, argv: words)
        }
        guard let firstArg = argv.first else {
            return shown("shell", entry("shell"), name: nil, shell: true, agent: false)
        }
        let first = Self.base(firstArg)
        if interpreters.contains(first) {
            for arg in argv.dropFirst() where !arg.hasPrefix("-") {
                let name = Self.base(arg)
                let stem = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"].first(where: { name.hasSuffix($0) })
                    .map { String(name.dropLast($0.count)) } ?? name
                if let (key, e) = find(stem), !interpreters.contains(key) {
                    return shown(key, e, name: nil, shell: false, agent: false)
                }
            }
        }
        if let (key, e) = find(first) { return shown(key, e, name: nil, shell: false, agent: false) }
        if shells.contains(first) { return shown("shell", entry("shell"), name: first, shell: true, agent: false) }
        var e = entry("program")
        e.tile = Self.hashColor(first)
        e.color = "#ffffff"
        return shown("program", e, name: first, shell: false, agent: false)
    }

    /// The display name of an agent from its 7501 `app` (`programs::name`).
    public func name(ofApp app: String) -> String {
        find(app).map { $0.1.name ?? $0.0 } ?? app
    }

    /// Agents people can start (entries with `run`), most picked first.
    public var startable: [(program: Program, run: [String])] {
        programs.filter { !$0.entry.run.isEmpty }
            .sorted { a, b in
                let ia = Self.agentsFirst.firstIndex(of: a.key) ?? Self.agentsFirst.count
                let ib = Self.agentsFirst.firstIndex(of: b.key) ?? Self.agentsFirst.count
                return ia != ib ? ia < ib : a.key.utf8.lexicographicallyPrecedes(b.key.utf8)
            }
            .map { (shown($0.key, $0.entry, name: nil, shell: false, agent: true), $0.entry.run) }
    }

    func find(_ name: String) -> (String, Entry)? {
        let lower = name.lowercased()
        if let hit = programs.first(where: { $0.key == name || $0.key.lowercased() == lower }) { return (hit.key, hit.entry) }
        if let hit = programs.first(where: { $0.entry.also.contains { $0 == name || $0.lowercased() == lower } }) {
            return (hit.key, hit.entry)
        }
        return nil
    }

    private func entry(_ key: String) -> Entry {
        index[key].map { programs[$0].entry } ?? Entry(also: [], run: [])
    }

    private func shown(_ key: String, _ e: Entry, name: String?, shell: Bool, agent: Bool) -> Program {
        let iconName = e.icon.map { Self.base($0) }.map { $0.hasSuffix(".svg") ? String($0.dropLast(4)) : $0 } ?? key
        return Program(key: key, name: name ?? e.name ?? key, iconAsset: "program.\(iconName)", tint: e.tint ?? true,
                       tile: e.tile ?? "#1c1d21", color: e.color ?? "#ffffff", isShell: shell, isAgent: agent)
    }

    // MARK: Helpers

    /// File name without a leading `-` (login shells) and a trailing `.exe`.
    static func base(_ s: String) -> String {
        var name = Substring(s)
        if let cut = s.lastIndex(where: { $0 == "/" || $0 == "\\" }) { name = s[s.index(after: cut)...] }
        while name.first == "-" { name = name.dropFirst() }
        if name.count >= 4, name.suffix(4).lowercased() == ".exe" { name = name.dropLast(4) }
        return String(name)
    }

    /// A stable tile color for an unknown program (FNV-1a 32 over its bytes).
    static func hashColor(_ s: String) -> String {
        let palette = ["#6d5bd0", "#2f80ed", "#0f9d8a", "#d9822b", "#c2417d", "#3a7d44", "#8a5a44", "#4e5d94"]
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    private static let psQuotes: Set<Character> = ["'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}"]

    /// The words of a `& 'prog' 'arg'` PowerShell line.
    static func powershellWords(_ line: String) -> [String]? {
        guard line.hasPrefix("& ") else { return nil }
        var chars = Array(line.dropFirst(2))[...]
        var words: [String] = []
        while let c = chars.popFirst() {
            if c == " " { continue }
            guard psQuotes.contains(c) else { return nil }
            var w = ""
            while let ch = chars.popFirst() {
                if psQuotes.contains(ch) {
                    if let n = chars.first, psQuotes.contains(n) {
                        w.append(chars.popFirst()!)
                        continue
                    }
                    break
                }
                w.append(ch)
            }
            words.append(w)
        }
        return words
    }
}
