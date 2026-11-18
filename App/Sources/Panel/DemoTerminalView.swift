import SwiftUI
import WierdrModel

/// A drawn (non-interactive) terminal for demo mode, previews and screenshots:
/// JetBrains Mono in the theme's terminal colors, plausible output per program
/// (a pi or Claude Code TUI for agents, a shell prompt, a lazygit layout).
struct DemoTerminalView: View {
    var context: TerminalViewContext
    @Environment(\.homeFolder) private var home

    private var palette: TerminalPalette { context.palette }
    private var size: CGFloat { context.fontSize }

    var body: some View {
        Group {
            if context.terminal?.program.key == "lazygit" {
                DemoLazygit(palette: palette, fontSize: size, cwd: Format.tilde(context.terminal?.cwd, home: home))
                    .padding(context.padding)
            } else {
                let script = DemoScript(terminal: context.terminal, home: home)
                // Lines never size the view: they hang from the top (shell) or the bottom (TUI) and clip.
                Color.clear
                    .overlay(alignment: script.anchorBottom ? .bottomLeading : .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(script.lines.enumerated()), id: \.offset) { _, line in
                                lineView(line)
                            }
                        }
                    }
                    .clipped()
                    .padding(context.padding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: palette.background))
        .clipped()
        .contentShape(Rectangle())
        .accessibilityLabel("Terminal \(context.address)")
    }

    @ViewBuilder
    private func lineView(_ line: TLine) -> some View {
        HStack(spacing: 0) {
            Text(attributed(line))
            if line.cursor { cursor }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: true)
        .frame(height: (size * 1.32).rounded())
    }

    private var cursor: some View {
        let color = Color(hex: palette.cursor)
        return Group {
            if context.focused {
                Rectangle().fill(color)
            } else {
                Rectangle().strokeBorder(color, lineWidth: 1)
            }
        }
        .frame(width: (size * 0.6).rounded(), height: (size * 1.3).rounded())
    }

    private func attributed(_ line: TLine) -> AttributedString {
        var out = AttributedString()
        for seg in line.segs {
            var s = AttributedString(seg.text)
            let (color, bold, bg) = resolve(seg.role)
            s.foregroundColor = color
            s.font = .mono(size, bold ? .bold : .regular)
            if let bg { s.backgroundColor = bg }
            out += s
        }
        if line.segs.isEmpty { out = AttributedString(" "); out.font = .mono(size) }
        return out
    }

    private func resolve(_ role: TRole) -> (Color, Bool, Color?) {
        let fg = Color(hex: palette.foreground)
        switch role {
        case .fg: return (fg, false, nil)
        case .bold: return (fg, true, nil)
        case .dim: return (Color(hex: palette.ansi[8]), false, nil)
        case .ansi(let i): return (Color(hex: palette.ansi[i]), false, nil)
        case .boldAnsi(let i): return (Color(hex: palette.ansi[i]), true, nil)
        case .hex(let h): return (Color(hex: h), false, nil)
        case .bar(let i): return (Color(hex: palette.ansi[i]), false, Color(hex: palette.ansi[i]))
        }
    }
}

// MARK: - Script

enum TRole { case fg, bold, dim, ansi(Int), boldAnsi(Int), hex(String), bar(Int) }

struct TSeg { var text: String; var role: TRole }

struct TLine {
    var segs: [TSeg]
    var cursor = false
    init(_ segs: [TSeg] = [], cursor: Bool = false) { self.segs = segs; self.cursor = cursor }
}

private func s(_ text: String, _ role: TRole = .fg) -> TSeg { TSeg(text: text, role: role) }

/// The demo content for a terminal.
struct DemoScript {
    var lines: [TLine] = []
    var anchorBottom = false

    init(terminal t: TerminalInfo?, home: String?) {
        let cwd = Format.tilde(t?.cwd, home: home)
        switch t?.program.key {
        case "pi": pi(t!, cwd: cwd)
        case "claude": claude(t!, cwd: cwd)
        default: shell(t, cwd: cwd)
        }
    }

    // A pi session (working / idle / done), shaped like the desktop screenshot.
    private mutating func pi(_ t: TerminalInfo, cwd: String) {
        anchorBottom = true
        let task = Format.cleanTitle(t.message)
        // An earlier turn, so the screen is full like a real session.
        lines += [
            TLine([s(" > ", .ansi(4)), s("Что сейчас в раскладке wierd-layout?", .bold)]),
            TLine(),
            TLine([s(" │ ", .ansi(2)), s("read ", .dim), s("~/.config/herdr-app/layouts/wierd-layout.json")]),
            TLine([s(" │ ", .ansi(2)), s("{")]),
            TLine([s(" │ ", .ansi(2)), s("  \"sidebar\"", .ansi(4)), s(": "), s("268", .ansi(3)), s(",")]),
            TLine([s(" │ ", .ansi(2)), s("  \"theme\"", .ansi(4)), s(": { "), s("\"light\"", .ansi(4)), s(": "), s("\"paper\"", .ansi(2)), s(", "), s("\"dark\"", .ansi(4)), s(": "), s("\"atom-one-dark\"", .ansi(2)), s(" },")]),
            TLine([s(" │ ", .ansi(2)), s("  \"mods\"", .ansi(4)), s(": ["), s("\"wierd-chrome\"", .ansi(2)), s(", "), s("\"wierd-agents\"", .ansi(2)), s(", "), s("\"wierd-tabs\"", .ansi(2)), s(", …]")]),
            TLine([s(" │ ", .ansi(2)), s("}")]),
            TLine([s(" └─ ", .ansi(2)), s("0.0s ", .dim), s("✓", .ansi(2)), s(" (24 lines) ", .dim),
                   s(String(repeating: "─", count: 160), .ansi(2))]),
            TLine(),
            TLine([s(" The layout uses the "), s("wierd-*", .bold), s(" mods for the sidebar, tabs and pane chrome,")]),
            TLine([s(" with Paper in light mode and Atom One Dark in dark mode.")]),
            TLine(),
        ]
        lines += [
            TLine([s(" > ", .ansi(4)), s(task.isEmpty ? "Continue" : task, .bold)]),
            TLine(),
            TLine([s(" I'll check the current layout files first, then make the changes.")]),
            TLine(),
            TLine([s(" │ ", .ansi(2)), s("$ ", .dim), s("ls ~/.config/herdr-app/mods")]),
        ]
        for name in ["agent-counts", "menu", "new-menu", "wierd-agents", "wierd-chrome", "wierd-pane", "wierd-tabs", "workspace-chrome"] {
            lines.append(TLine([s(" │ ", .ansi(2)), s(name)]))
        }
        lines += [
            TLine([s(" │ ", .ansi(2)), s("{")]),
            TLine([s(" │ ", .ansi(2)), s("  \"zoom\"", .ansi(4)), s(": "), s("1.0", .ansi(3)), s(",")]),
            TLine([s(" │ ", .ansi(2)), s("  \"font_size\"", .ansi(4)), s(": "), s("14.0", .ansi(3)), s(",")]),
            TLine([s(" │ ", .ansi(2)), s("  \"ui_font_size\"", .ansi(4)), s(": "), s("13.0", .ansi(3)), s(",")]),
            TLine([s(" │ ", .ansi(2)), s("  \"layout\"", .ansi(4)), s(": "), s("\"wierd-layout\"", .ansi(2)), s(",")]),
            TLine([s(" │ ", .ansi(2)), s("  \"agent\"", .ansi(4)), s(": "), s("\"\(t.address)\"", .ansi(2))]),
            TLine([s(" │ ", .ansi(2)), s("}")]),
            TLine([s(" │ ", .ansi(2)), s("… 38 more lines", .dim)]),
            TLine([s(" └─ ", .ansi(2)), s("0.0s ", .dim), s("✓ exit 0", .ansi(2)), s(" (118 lines) ", .dim),
                   s(String(repeating: "─", count: 160), .ansi(2))]),
            TLine(),
        ]
        switch t.status {
        case .working:
            lines += [
                TLine([s(" Reading the pane layout and the tab strip next.")]),
                TLine(),
                TLine([s(" ● ", .ansi(4)), s("Working... 44.9s · tps: ~33", .dim)]),
            ]
        case .done:
            lines += [
                TLine([s(" Done. The mod is installed and enabled; restart herdr-app to load it.")]),
                TLine([s(" Summary:", .bold)]),
                TLine([s("  • ", .dim), s("copied the mod into ~/.config/herdr-app/mods")]),
                TLine([s("  • ", .dim), s("added it to the layout's mod list")]),
            ]
        default:
            lines += [
                TLine([s(" All set. Nothing else is pending in this session.")]),
            ]
        }
        lines.append(TLine())
        lines.append(statusline(t, cwd: cwd))
        lines.append(TLine([s(" ")], cursor: true))
    }

    private func statusline(_ t: TerminalInfo, cwd: String) -> TLine {
        let m = t.meta
        let ctx = m?.ctx ?? 0, max = m?.ctxMax ?? 1_000_000
        let pct = max > 0 ? Int(Double(ctx) / Double(max) * 100) : 0
        let filled = Swift.max(1, Swift.min(10, pct / 10 + 1))
        let effortColor: TRole = {
            switch m?.effort {
            case "xhigh": return .hex("#f7768e")
            case "high": return .hex("#ff9e64")
            case "medium": return .hex("#7dcfff")
            case "low": return .hex("#7aa2f7")
            default: return .dim
            }
        }()
        return TLine([
            s(" ─ ", .dim), s("⚙ ", .ansi(5)), s(m?.model ?? t.program.name, .ansi(5)),
            s("  \(m?.effort ?? "off")", effortColor), s(" │ ", .dim),
            s("\(pct)%: ", .ansi(2)), s(Format.context(ctx) ?? "0"), s("["),
            s(String(repeating: "▬", count: filled), .ansi(2)), s(String(repeating: " ", count: 10 - filled)),
            s("]"), s(Format.context(max - ctx) ?? "0"), s(" │ ", .dim), s("$0.37", .dim), s(" │ ", .dim),
            s("…/", .dim), s(cwd.split(separator: "/").suffix(2).dropLast().joined(separator: "/") + "/", .ansi(4)),
            s(String(cwd.split(separator: "/").last ?? "~"), .boldAnsi(4)),
            s(" │ ", .dim), s("84.6%", .ansi(1)), s(" (260k/47k)", .dim), s(" ─", .dim),
        ])
    }

    // Claude Code asking for permission.
    private mutating func claude(_ t: TerminalInfo, cwd: String) {
        anchorBottom = true
        let w = 66
        func boxed(_ segs: [TSeg]) -> TLine {
            let visible = segs.reduce(0) { $0 + $1.text.count }
            return TLine([s("│ ", .hex("#d77757"))] + segs + [s(String(repeating: " ", count: Swift.max(0, w - 4 - visible)) + " │", .hex("#d77757"))])
        }
        lines += [
            TLine([s("╭" + String(repeating: "─", count: w - 2) + "╮", .hex("#d77757"))]),
            boxed([s("✻ ", .hex("#d77757")), s("Welcome to "), s("Claude Code", .bold), s("!")]),
            boxed([]),
            boxed([s("  cwd: \(t.cwd ?? cwd)", .dim)]),
            TLine([s("╰" + String(repeating: "─", count: w - 2) + "╯", .hex("#d77757"))]),
            TLine(),
            TLine([s("> ", .dim), s("move the dream scheduler onto the new job queue", .dim)]),
            TLine(),
            TLine([s("● ", .ansi(2)), s("Read", .bold), s("(src/queue.ts)")]),
            TLine([s("  ⎿  ", .dim), s("Read 142 lines", .dim)]),
            TLine(),
            TLine([s("● ", .fg), s("The scheduler can enqueue a dream job instead of running it inline.")]),
            TLine([s("  I'll update "), s("src/dream.ts", .bold), s(" to use "), s("queue.add()", .ansi(4)), s(".")]),
            TLine(),
            TLine([s("● ", .ansi(3)), s("Update", .bold), s("(src/dream.ts)")]),
        ]
        // Working (the demo's t8a): its background work runs, as its records tell.
        if t.status != .blocked {
            let tasks = t.records
            lines += [TLine([s("  ⎿  ", .dim), s("Updated ", .dim), s("src/dream.ts", .bold), s(" with 1 addition and 1 removal", .dim)]),
                      TLine()]
            for r in tasks {
                lines.append(TLine([s("● ", .ansi(2)), s(r.kind == .shell ? "Bash" : "Task", .bold), s("(\(r.title))"),
                                    s(" — running in background", .dim)]))
            }
            lines += [
                TLine(),
                TLine([s("✻ ", .hex("#d77757")), s("Queueing… ", .hex("#d77757")), s("(3m · ↓ 4.1k tokens · esc to interrupt)", .dim)]),
                TLine(),
                TLine([s(String(repeating: "─", count: w), .dim)]),
                TLine([s("> ", .dim)], cursor: true),
                TLine([s(String(repeating: "─", count: w), .dim)]),
                TLine([s("  \(tasks.count) background task\(tasks.count == 1 ? "" : "s") · ? for shortcuts", .dim)]),
            ]
            return
        }
        lines += [
            TLine(),
            TLine([s(String(repeating: "─", count: w), .ansi(4))]),
            TLine([s(" Edit file", .boldAnsi(4))]),
            TLine([s(" src/dream.ts", .bold)]),
            TLine([s(" 41  ", .dim), s("-  await runDream(job)", .ansi(1))]),
            TLine([s(" 41  ", .dim), s("+  await queue.add(\"dream\", job, { attempts: 3 })", .ansi(2))]),
            TLine(),
            TLine([s(" Do you want to make this edit to "), s("dream.ts", .bold), s("?")]),
            TLine([s(" ❯ ", .ansi(4)), s("1. Yes", .ansi(4))]),
            TLine([s("   2. Yes, allow all edits during this session (shift+tab)")]),
            TLine([s("   3. No, and tell Claude what to do differently (esc)")]),
            TLine(),
        ]
    }

    // A zsh with a few commands.
    private mutating func shell(_ t: TerminalInfo?, cwd: String) {
        let remote = t?.machine != nil
        let dir = cwd.isEmpty ? "~" : cwd
        func prompt(_ cmd: String, cursor: Bool = false) -> TLine {
            var segs: [TSeg] = []
            if remote { segs += [s("hcagent@\(t?.machine ?? "")", .ansi(2)), s(" ")] }
            segs += [s(dir, .boldAnsi(4))]
            if !remote { segs += [s(" main", .ansi(5))] }
            segs += [s(" ❯ ", .ansi(2)), s(cmd)]
            return TLine(segs, cursor: cursor)
        }
        if remote {
            lines += [
                TLine([s("Last login: Mon Nov 10 21:04:13 2025 from 10.0.0.12", .dim)]),
                prompt("uptime"),
                TLine([s(" 21:07:44 up 12 days,  3:41,  1 user,  load average: 0.08, 0.05, 0.01")]),
                prompt("hc ls"),
                TLine([s("ADDR  NAME  STATUS  WHERE", .bold)]),
                TLine([s("t1    -     -       ~ / 1")]),
                prompt("", cursor: true),
            ]
        } else {
            lines += [
                prompt("git status -sb"),
                TLine([s("## ", .fg), s("main", .ansi(2)), s("...", .fg), s("origin/main", .ansi(1))]),
                TLine([s(" M", .ansi(1)), s(" src/limits.ts")]),
                TLine([s(" M", .ansi(1)), s(" src/render.ts")]),
                TLine([s("??", .ansi(1)), s(" notes.md")]),
                prompt("ls"),
                TLine([s("README.md     ", .fg), s("node_modules  ", .boldAnsi(4)), s("package.json  ", .fg), s("src  ", .boldAnsi(4)), s("test", .boldAnsi(4))]),
                prompt("npm test"),
                TLine(),
                TLine([s("> wierd-limits@0.3.1 test", .dim)]),
                TLine([s("> vitest run", .dim)]),
                TLine(),
                TLine([s(" ✓ ", .ansi(2)), s("test/limits.test.ts "), s("(14 tests) ", .dim), s("38ms", .ansi(3))]),
                TLine([s(" ✓ ", .ansi(2)), s("test/render.test.ts "), s("(6 tests) ", .dim), s("12ms", .ansi(3))]),
                TLine(),
                TLine([s(" Test Files  ", .dim), s("2 passed", .boldAnsi(2)), s(" (2)", .dim)]),
                TLine([s("      Tests  ", .dim), s("20 passed", .boldAnsi(2)), s(" (20)", .dim)]),
                TLine(),
                prompt("", cursor: true),
            ]
        }
    }
}

// MARK: - lazygit

/// A lazygit-like layout drawn with views, so it fits any pane size.
private struct DemoLazygit: View {
    var palette: TerminalPalette
    var fontSize: CGFloat
    var cwd: String

    private var fg: Color { Color(hex: palette.foreground) }
    private var green: Color { Color(hex: palette.ansi[2]) }
    private var dim: Color { Color(hex: palette.ansi[8]) }
    private var blue: Color { Color(hex: palette.ansi[4]) }
    private var red: Color { Color(hex: palette.ansi[1]) }
    private var yellow: Color { Color(hex: palette.ansi[3]) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 520
            VStack(spacing: 0) {
                if wide {
                    HStack(spacing: 2) {
                        left.frame(width: geo.size.width * 0.38)
                        panel("Diff", active: false) { diffLines }
                    }
                } else {
                    left
                }
                Text("Commit: c | Stash: s | Push: P | Pull: p | Keybindings: ?")
                    .font(.mono(fontSize * 0.85)).foregroundStyle(blue)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    private var left: some View {
        VStack(spacing: 2) {
            panel("Status", active: false) { row([("✓ ", green), (cwd.split(separator: "/").last.map(String.init) ?? "chezmoi", fg), (" → ", dim), ("main", green)]) }
                .frame(height: fontSize * 3.2)
            panel("Files", active: true) {
                row([("M  ", green), ("dot_zshrc", fg)], selected: true)
                row([(" M ", red), ("dot_config/herdr-app/keys.json", fg)])
                row([("??", red), (" dot_config/pi/settings.json", fg)])
            }
            panel("Local branches", active: false) {
                row([("* ", green), ("main", green), ("  ✓", green)])
                row([("  ", fg), ("wierd-theme", fg), ("  3d", dim)])
            }
            panel("Commits", active: false) {
                row([("a91c2e4 ", yellow), ("herdr: new keys", fg)])
                row([("7f3d0b1 ", yellow), ("zsh: prompt tweaks", fg)])
                row([("e02a9c7 ", yellow), ("pi: settings", fg)])
                row([("19bb4d0 ", yellow), ("initial", fg)])
            }
            panel("Stash", active: false) { row([("", fg)]) }
                .frame(height: fontSize * 3.2)
        }
    }

    @ViewBuilder
    private var diffLines: some View {
        row([("diff --git a/dot_zshrc b/dot_zshrc", fg)])
        row([("@@ -12,6 +12,8 @@", blue)])
        row([(" export EDITOR=nvim", fg)])
        row([("+export HERDR_THEME=atom-one-dark", green)])
        row([("+alias hl='hc ls'", green)])
        row([("-alias ll='ls -la'", red)])
    }

    private func panel<Content: View>(_ title: String, active: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 6).padding(.top, fontSize * 0.75).padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? green : dim.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(" \(title) ").font(.mono(fontSize * 0.9, active ? .bold : .regular))
                    .foregroundStyle(active ? green : fg)
                    .background(Color(hex: palette.background))
                    .offset(x: 8, y: -fontSize * 0.65)
            }
            .padding(.top, fontSize * 0.5)
    }

    private func row(_ parts: [(String, Color)], selected: Bool = false) -> some View {
        parts.reduce(Text("")) { $0 + Text($1.0).foregroundColor($1.1) }
            .font(.mono(fontSize * 0.9))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? blue.opacity(0.25) : .clear)
    }
}

// MARK: - Home folder environment (for `~`)

private struct HomeFolderKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The connected computer's home (`Workspace.home`) for `~` shortening.
    var homeFolder: String? {
        get { self[HomeFolderKey.self] }
        set { self[HomeFolderKey.self] = newValue }
    }
}
