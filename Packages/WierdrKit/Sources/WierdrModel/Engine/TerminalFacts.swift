import Foundation
import HerdrCore

// How a core terminal record becomes a `TerminalInfo`: title cleanup
// (`terminal.rs::shown_title`), status rules (`model.rs::status`, shared
// `herdr.seen`), `agent.*` labels (the user's `wierd-agents/meta.js`).

// MARK: - Titles

enum TerminalText {
    private static func spinner(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x2800...0x28FF, 0x00B7, 0x2722, 0x2733, 0x2736, 0x273B, 0x273D, 0x25D0...0x25D3: return true
        default: return false
        }
    }

    private static func braille(_ w: Substring.UnicodeScalarView) -> Bool {
        !w.isEmpty && w.allSatisfy { (0x2800...0x28FF).contains($0.value) }
    }

    /// The title as Herdr shows it: without the spinner frames agents put in front.
    static func shownTitle(_ title: String) -> String {
        let scalars = title.unicodeScalars
        let start = scalars.firstIndex { !(spinner($0) || $0.properties.isWhitespace) } ?? scalars.endIndex
        let led = scalars[..<start]
        if start != scalars.endIndex, led.contains(where: spinner), let last = led.last, last.properties.isWhitespace {
            return String(scalars[start...])
        }
        // "π ⠹ task": a short prefix, a braille frame, the rest.
        let parts = title.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count >= 2 {
            let prefix = parts[0], frame = parts[1]
            if !prefix.isEmpty, prefix.unicodeScalars.count <= 3, !braille(prefix.unicodeScalars), braille(frame.unicodeScalars) {
                let rest = parts.count > 2 ? parts[2].drop(while: { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) }) : ""
                return rest.isEmpty ? String(prefix) : "\(prefix) \(rest)"
            }
        }
        return title
    }

    /// The foreground process's own name: basename of its argv[0] (leading `-`
    /// dropped), else its process name, else the launch argv[0]'s basename.
    static func processName(_ t: Terminal) -> String? {
        func base(_ s: String) -> String {
            var name = s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? s
            while name.hasPrefix("-") { name.removeFirst() }
            return name
        }
        if let a0 = t.foreground?.argv.first, !base(a0).isEmpty { return base(a0) }
        if let n = t.foreground?.name, !n.isEmpty { return n }
        if let a0 = t.argv.first, !base(a0).isEmpty { return base(a0) }
        return nil
    }
}

// MARK: - Status

enum StatusRule {
    static func isBusy(_ word: String?) -> Bool { word == "working" || word == "blocked" || word == "error" }

    /// Herdr's status: `working`; `blocked`/`error` → blocked; otherwise done
    /// while the turn is unseen (shared `herdr.seen`, else this client's own flag).
    static func status(word: String?, turn: UInt64, seenTurn: UInt64?, locallySeen: Bool) -> AgentStatus? {
        guard let word else { return nil }
        switch word {
        case "working": return .working
        case "blocked", "error": return .blocked
        default:
            if let seenTurn { return turn > seenTurn ? .done : .idle }
            return locallySeen ? .idle : .done
        }
    }

    /// The 7501 word of a record (nil: not an agent).
    static func word(_ t: Terminal) -> String? {
        guard let s = t.status?.state, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - 7501 records

enum StatusRecords {
    /// A terminal's `records` (`{id: Status}`, as `hc get` shows them) → its work, by id.
    /// Records without a state (cleared) or an id are left out.
    static func parse(_ value: JSONValue?) -> [TaskRecord] {
        guard let object = value?.object else { return [] }
        func text(_ v: JSONValue?) -> String? {
            guard let s = v?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        var out: [TaskRecord] = []
        for (id, record) in object where !id.isEmpty {
            guard let state = text(record["state"]) else { continue }
            let message = text(record["msg"])
            out.append(TaskRecord(id: id, app: text(record["app"]), state: state,
                                  title: text(record["title"]) ?? message ?? id, message: message,
                                  blockedKind: text(record["kind"]), progress: record["progress"]?.int))
        }
        return out.sorted { $0.id < $1.id }
    }
}

// MARK: - agent.* labels

enum AgentLabels {
    /// Provider id → mark (`meta.js PROVIDERS`), first match wins.
    static let providers: [(mark: String, pattern: String)] = [
        ("anthropic", "^anthropic"), ("openai", "^(openai|chatgpt)"), ("azure", "^azure"),
        ("google", "^(google|gemini|vertex)"), ("aws", "^(amazon|aws|bedrock)"), ("opencode", "^opencode"),
        ("openrouter", "^openrouter"), ("github-copilot", "copilot"), ("vercel", "^vercel"),
        ("cloudflare", "^cloudflare"), ("xai", "^(xai|x-ai|grok)"), ("groq", "^groq"), ("cerebras", "^cerebras"),
        ("mistral", "^mistral"), ("deepseek", "^deepseek"), ("zai", "^(zai|z-ai|zhipu|bigmodel)"),
        ("minimax", "^minimax"), ("kimi", "^kimi"), ("moonshot", "^moonshot"), ("qwen", "^(qwen|dashscope|alibaba)"),
        ("xiaomi", "^xiaomi"), ("huggingface", "^(huggingface|hf-)"), ("fireworks", "^fireworks"),
        ("together", "^together"), ("baseten", "^baseten"), ("nvidia", "^nvidia"), ("meta", "^meta"),
        ("ollama", "^ollama"), ("lm-studio", "^lm-?studio"),
    ]

    /// Marks the app ships as `provider.<mark>` (Design/icons/providers).
    static let shippedMarks: Set<String> = [
        "anthropic", "aws", "azure", "baseten", "cerebras", "cloudflare", "deepseek", "fireworks", "github-copilot",
        "google", "groq", "huggingface", "kimi", "lm-studio", "meta", "minimax", "mistral", "moonshot", "nvidia",
        "ollama", "openai", "opencode", "openrouter", "qwen", "together", "vercel", "xai", "xiaomi", "zai",
    ]

    private static func matches(_ pattern: String, _ s: String, caseInsensitive: Bool = false) -> Range<String.Index>? {
        s.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression)
    }

    /// The provider's mark (`providerOf`), only when the app ships it.
    static func mark(provider: String?) -> String? {
        let p = (provider ?? "").lowercased()
        guard !p.isEmpty, let mark = providers.first(where: { matches($0.pattern, p) != nil })?.mark,
              shippedMarks.contains(mark) else { return nil }
        return mark
    }

    /// The model as people say it (`shortModel`): no "Vendor: " or `vendor/`
    /// prefix, no vendor word the provider mark already says.
    static func shortModel(_ name: String, mark: String?) -> String {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = raw
        if let r = matches("^[^:/]{1,40}:\\s+", s) { s.removeSubrange(r) }
        if let r = matches("^[A-Za-z0-9_.-]+/", s) { s.removeSubrange(r) }
        let own: [String: String] = ["anthropic": "^claude[\\s-]+(?=\\S)", "openai": "^gpt[\\s-]+(?=\\S)",
                                     "kimi": "^kimi[\\s-]+(?=\\S)", "moonshot": "^kimi[\\s-]+(?=\\S)"]
        if let mark, let re = own[mark], let r = matches(re, s, caseInsensitive: true) { s.removeSubrange(r) }
        return s.isEmpty ? raw : s
    }

    private static func number(_ labels: [String: String], _ key: String) -> Double? {
        guard let v = labels[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty, let n = Double(v), n.isFinite else { return nil }
        return n
    }

    /// `agentMeta`: trusted only while `agent.pid` is still the foreground program.
    static func meta(labels: [String: String], foregroundPID: Int?) -> AgentMeta? {
        guard let app = labels["agent.app"], !app.isEmpty else { return nil }
        if let pid = labels["agent.pid"], !pid.isEmpty, let fg = foregroundPID, String(fg) != pid { return nil }
        let provider = labels["agent.provider"].flatMap { $0.isEmpty ? nil : $0 }
        let mark = mark(provider: provider)
        let model = labels["agent.model"].flatMap { $0.isEmpty ? nil : shortModel($0, mark: mark) }
        func int(_ k: String) -> Int? { number(labels, k).flatMap { Int(exactly: $0.rounded()) } }
        return AgentMeta(
            provider: provider,
            providerAsset: mark.map { "provider.\($0)" },
            model: model,
            effort: labels["agent.effort"].flatMap { $0.isEmpty ? nil : $0 },
            ctx: int("agent.ctx"),
            ctxMax: int("agent.ctx_max"),
            cacheUntil: number(labels, "agent.cache_until").map { Date(timeIntervalSince1970: $0 / 1000) },
            cacheTTL: number(labels, "agent.cache_ttl").map { $0 / 1000 },
            session: labels["agent.session"].flatMap { $0.isEmpty ? nil : $0 },
            subagents: int("agent.subagents") ?? 0)
    }
}

// MARK: - Record → TerminalInfo

struct TerminalDeriver {
    /// Label prefix (`herdr`): `<prefix>.space`, `.tab`, `.seen`, `.pinned`.
    var prefix: String
    var table: ProgramTable = .builtIn
    /// Normalizes a record's `parent` to this connection's qualified addresses.
    var parent: (String) -> String? = { $0 }

    func label(_ name: String) -> String { "\(prefix).\(name)" }

    func seenLabel(_ t: Terminal) -> UInt64? { t.labels[label("seen")].flatMap { UInt64($0) } }

    /// When `<prefix>.pinned` says it was pinned: a Unix time in seconds (what Wierdr
    /// writes); `"1"` (the desktop's) or anything else is a pin without a time.
    static func pinTime(_ value: String?) -> Date? {
        guard let value, let seconds = Double(value.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds > 1 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func info(_ t: Terminal, seenTurn: UInt64?, locallySeen: Bool) -> TerminalInfo {
        let machine = LayoutID.machine(of: t.address)
        let word = StatusRule.word(t)
        let app = t.status?.app.flatMap { $0.isEmpty ? nil : $0 }
        let argv = (t.foreground?.argv.isEmpty == false) ? t.foreground!.argv : t.argv
        let cwd = [t.foreground?.cwd, t.cwd].compactMap { $0 }.first { !$0.isEmpty }
        func qualifiedLabel(_ name: String) -> String? {
            guard let v = t.labels[label(name)], !v.isEmpty else { return nil }
            return LayoutID.qualify(v, machine)
        }
        return TerminalInfo(
            address: t.address,
            machine: machine,
            name: t.name.flatMap { $0.isEmpty ? nil : $0 },
            template: t.template.flatMap { $0.isEmpty ? nil : $0 },
            createdAt: t.createdMs > 0 ? Date(timeIntervalSince1970: Double(t.createdMs) / 1000) : nil,
            title: TerminalText.shownTitle(t.title),
            cwd: cwd,
            processName: TerminalText.processName(t),
            program: table.resolve(app: app, argv: argv),
            isLive: t.isLive,
            status: StatusRule.status(word: word, turn: t.turn, seenTurn: seenTurn, locallySeen: locallySeen),
            state: word,
            message: t.status?.msg,
            app: app,
            turn: Int(clamping: t.turn),
            statusChangedAt: t.statusMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            parent: t.parent.flatMap { $0.isEmpty ? nil : parent($0) },
            labels: t.labels,
            pinned: !(t.labels[label("pinned")] ?? "").isEmpty,
            pinnedAt: Self.pinTime(t.labels[label("pinned")]),
            meta: AgentLabels.meta(labels: t.labels, foregroundPID: t.foreground?.pid),
            spaceID: qualifiedLabel("space"),
            tabID: qualifiedLabel("tab"),
            records: t.isLive ? StatusRecords.parse(t.records) : [])
    }
}

// MARK: - Naming and colors

enum SpaceNaming {
    /// `folder_name`: last path component; `~` for empty or home; `/` for root.
    static func folderName(_ path: String, home: String?) -> String {
        let trimmed = String(path.reversed().drop(while: { $0 == "/" || $0 == "\\" }).reversed())
        let h = home.map { String($0.reversed().drop(while: { $0 == "/" || $0 == "\\" }).reversed()) }
        if path.isEmpty || trimmed == h { return "~" }
        if trimmed.isEmpty { return String(path.prefix(1)) }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? trimmed
    }

    /// Avatar fills (`MARK` in `wierd-agents/spaces.js`), in palette order.
    static let palette: [(name: String, hex: String)] = [
        ("ansi6", "#22a99a"), ("ansi3", "#e3814f"), ("ansi4", "#5b8def"),
        ("ansi5", "#8b7cf6"), ("ansi2", "#3fae6a"), ("ansi1", "#d9649a"),
    ]

    static func hex(_ color: String) -> String {
        if color.hasPrefix("#") { return color }
        return palette.first { $0.name == color }?.hex ?? palette[0].hex
    }

    /// Colors for spaces in order (`id`, display name): the shared map's entry,
    /// else the palette color used least (ties: palette order), `~` spaces ansi6.
    static func colors(for spaces: [(id: String, name: String)], shared: [String: String]) -> [String: String] {
        let ids = Set(spaces.map(\.id))
        var kept = shared.filter { ids.contains($0.key) }
        for s in spaces where kept[s.id] == nil && s.name != "~" {
            var uses: [String: Int] = [:]
            for v in kept.values { uses[v, default: 0] += 1 }
            var best = palette[0].name
            for c in palette.map(\.name) where uses[c, default: 0] < uses[best, default: 0] { best = c }
            kept[s.id] = best
        }
        var out: [String: String] = [:]
        for s in spaces { out[s.id] = hex(kept[s.id] ?? "ansi6") }
        return out
    }
}

// MARK: - Agent launch

enum LaunchArgv {
    /// `remote_shell::launch`: run `cmd` in that machine's login+interactive
    /// shell, then stay in it. Works on any Unix machine without knowing `$SHELL`.
    static func agent(_ cmd: [String], task: String?) -> [String] {
        var cmd = cmd
        if let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty { cmd.append(task) }
        return inShell(posix: "\"$@\"; exec \"$0\" -li", fish: "command $argv[2..]; exec $argv[1] -li",
                       fallback: "\"$@\"; exec \"${SHELL:-sh}\" -i", cmd)
    }

    /// `remote_shell::check`: which of `commands` the machine's shell finds.
    static func check(_ commands: [String]) -> [String] {
        let posix = "for c; do unalias -- \"$c\" 2>/dev/null; command -v \"$c\" >/dev/null 2>&1 && printf 'herdr-has:%s\\n' \"$c\"; done; printf '\\nherdr-check-complete\\n'"
        let fish = "for c in $argv[2..]; command -v $c >/dev/null 2>&1; and printf 'herdr-has:%s\\n' $c; end; printf '\\nherdr-check-complete\\n'"
        return inShell(posix: posix, fish: fish, fallback: posix, commands)
    }

    /// The commands `check` output says exist (nil when the check did not complete).
    static func installed(_ commands: [String], output: String, code: Int?) -> Set<String>? {
        guard code == 0, output.split(separator: "\n", omittingEmptySubsequences: false).contains("herdr-check-complete") else {
            return nil
        }
        let found = output.components(separatedBy: "herdr-has:").dropFirst()
            .compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
        return Set(commands.filter { found.contains($0) })
    }

    private static func inShell(posix: String, fish: String, fallback: String, _ args: [String]) -> [String] {
        func quote(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }
        let script = """
            shell=${SHELL:-/bin/sh}
            case "${shell##*/}" in
              fish) exec "$shell" -lic '\(quote(fish))' "$shell" "$@" ;;
              sh|bash|zsh|dash|ksh) exec "$shell" -lic '\(quote(posix))' "$shell" "$@" ;;
              *) exec sh -c '\(quote(fallback))' sh "$@" ;;
            esac
            """
        return ["sh", "-c", script, "sh"] + args
    }
}
