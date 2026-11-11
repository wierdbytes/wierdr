#if DEBUG || WIERDR_LAB
import SwiftUI
import UIKit
import MetalKit
import HerdrCore
import HerdrSSH

/// DEBUG harness for the terminal view: `-terminal-lab YES`.
///
/// Connects to the test sshd (`scripts/test-sshd.sh start`) on 127.0.0.1:2222
/// with `/tmp/wierdr-sshd/client_ed25519`, starts a scratch terminal
/// (label `wierdr.test=1`, no herdr labels, no parent) and shows it full screen.
/// "Kill & quit" kills and removes it. Never touches other terminals.
///
/// Environment (`SIMCTL_CHILD_…` from `simctl launch`):
/// - `WIERDR_LAB_USER` (default: the Mac user owning the simulator's home), `WIERDR_LAB_HOST`,
///   `WIERDR_LAB_PORT`, `WIERDR_LAB_KEY`
/// - `WIERDR_LAB_CMD`: a shell line to run instead of the login shell
/// - `WIERDR_LAB_SCRIPT`: path of a JSON array of steps (see `TerminalLab.run(step:)`)
/// - `WIERDR_LAB_LIGHT=1`: start in light mode
/// Log: `/tmp/wierdr-lab.log` (host path; the simulator can write it).
struct TerminalLabView: View {
    @State private var lab = TerminalLab()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                Color(lab.pool.theme.backgroundColor)
                if let session = lab.session {
                    TerminalSurface(session: session, isFocused: true) { lab.log("tap") }
                        .frame(width: lab.surfaceWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    Text(lab.status).foregroundStyle(.secondary)
                }
            }
        }
        .preferredColorScheme(lab.pool.isDark ? .dark : .light)
        .task { await lab.start() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Terminal Lab").font(.headline)
            Text(lab.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button(lab.pool.isDark ? "Light" : "Dark") { lab.pool.setAppearance(dark: !lab.pool.isDark) }
            Button("A−") { lab.pool.setFontSize(lab.pool.fontSize - 1) }
            Button("A+") { lab.pool.setFontSize(lab.pool.fontSize + 1) }
            Button(lab.pool.useMetal ? "Metal" : "CG") { lab.pool.setUseMetal(!lab.pool.useMetal) }
            Button("Reconnect") { Task { await lab.reconnect() } }
            Button("Kill & quit", role: .destructive) { Task { await lab.killAndQuit() } }
            // Stand-ins for the app's menu shortcuts: they must still fire while the terminal has the keyboard.
            Button("⌘T") { lab.log("menu cmd-t") }.keyboardShortcut("t", modifiers: .command)
            Button("⌘1") { lab.log("menu cmd-1") }.keyboardShortcut("1", modifiers: .command)
            Button("⌘]") { lab.log("menu cmd-]") }.keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(TerminalTheme.uiColor(lab.pool.isDark ? "#16191d" : "#f1f1ee")))
    }
}

@MainActor
@Observable
final class TerminalLab {
    let pool: TerminalSessionPool
    var status = "Connecting…"
    var session: TerminalSession?
    var address: String?
    var surfaceWidth: CGFloat?
    @ObservationIgnored private var connection: CoreConnection?
    @ObservationIgnored private let env = ProcessInfo.processInfo.environment
    @ObservationIgnored private let logURL = URL(fileURLWithPath: "/tmp/wierdr-lab.log")
    @ObservationIgnored private var started = false

    init() {
        pool = TerminalSessionPool(dark: ProcessInfo.processInfo.environment["WIERDR_LAB_LIGHT"] != "1")
        try? Data().write(to: logURL)
    }

    var summary: String {
        guard let s = session else { return status }
        let state: String
        switch s.state {
        case .ended(let e): state = e.message
        case .error(let m): state = "error: \(m)"
        default: state = "\(s.state)"
        }
        return "\(s.address)  \(state)  \(s.cols)x\(s.rows)  \(s.isUsingMetal ? "metal" : "cg")  \(s.title)"
    }

    func log(_ line: String) {
        let text = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(line)\n"
        print("LAB", line)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }

    private func connect() async throws -> CoreConnection {
        let user = env["WIERDR_LAB_USER"] ?? Self.defaultUser
        let host = env["WIERDR_LAB_HOST"] ?? "127.0.0.1"
        let port = Int(env["WIERDR_LAB_PORT"] ?? "") ?? 2222
        let keyPath = env["WIERDR_LAB_KEY"] ?? "/tmp/wierdr-sshd/client_ed25519"
        let key = try SSHPrivateKey(importing: String(contentsOfFile: keyPath, encoding: .utf8))
        let transport = try await SSHTransport.connect(
            SSHConfig(host: host, port: port, username: user, auth: .key(key)),
            hostKeyValidator: ClosureHostKeyValidator { _ in .accept })
        let core = CoreConnection(transport: transport)
        let hello = try await core.start()
        log("connected \(user)@\(host):\(port) core \(hello.core.name) automatic_input=\(core.supports("automatic_input"))")
        return core
    }

    /// The simulator's home is /Users/<mac user>/Library/Developer/...
    private static var defaultUser: String {
        let parts = NSHomeDirectory().split(separator: "/")
        if parts.count > 1, parts[0] == "Users" { return String(parts[1]) }
        return NSUserName()
    }

    func start() async {
        guard !started else { return }
        started = true
        if env["WIERDR_LAB_KEYLOG"] == "1" { WierdrTerminalView.keyLog = { [weak self] in self?.log($0) } }
        do {
            let core = try await connect()
            connection = core
            let line = env["WIERDR_LAB_CMD"]
            let run = try await core.runTerminal(RunParams(
                argv: line == nil ? [] : nil, line: line, cwd: "/Users/\(env["WIERDR_LAB_USER"] ?? Self.defaultUser)",
                labels: ["wierdr.test": "1"],
                env: ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"],
                display: pool.theme.display(cellPixels: nil), noParent: true))
            let address = run.terminal.address
            self.address = address
            log("started \(address) argv=\(run.terminal.argv)")
            pool.setConnection(core)
            session = pool.session(for: address)
            status = "Running"
            if let path = env["WIERDR_LAB_SCRIPT"] { await runScript(path) }
        } catch {
            status = "Error: \(error.localizedDescription)"
            log("error \(error)")
        }
    }

    func reconnect() async {
        do {
            let old = connection
            let core = try await connect()
            connection = core
            pool.setConnection(core)
            await old?.close()
            log("reconnected")
        } catch {
            log("reconnect failed \(error)")
        }
    }

    func killAndQuit() async {
        if let address, let core = connection {
            _ = try? await core.killTerminal(address)
            try? await Task.sleep(for: .milliseconds(300))
            let removed = try? await core.removeTerminal(address)
            log("killed and removed \(removed ?? "?")")
            await core.close()
        }
        exit(0)
    }

    // MARK: Script

    private func runScript(_ path: String) async {
        guard let data = FileManager.default.contents(atPath: path),
              let steps = try? JSONDecoder().decode([String].self, from: data) else {
            log("script unreadable: \(path)")
            return
        }
        // Wait until live.
        for _ in 0..<100 where session?.state != .live { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        for step in steps { await run(step: step) }
        log("script done")
    }

    /// Steps: plain text is typed through the keyboard path ("\r" = Return).
    /// `@sleep S`, `@mark NAME` (log line for screenshots), `@raw TEXT` (bytes as input),
    /// `@ctrl X`, `@key NAME` (left/right/up/down/alt-left/alt-right/alt-backspace/cmd-left/cmd-right/cmd-backspace/cmd-period),
    /// `@width W|full`, `@font N`, `@dark 0|1`, `@metal 0|1`, `@detach`, `@attach`, `@reconnect`,
    /// `@drop` (close the connection, no new one), `@paste TEXT`, `@copyall`, `@focus`, `@blur`,
    /// `@expect TEXT [timeout]` (wait for TEXT on our emulator's screen), `@count TEXT` (occurrences in
    /// screen + scrollback), `@read` (the core's view of the screen), `@kill`, `@quit`.
    private func run(step: String) async {
        guard let session else { return }
        let view = session.terminalView
        guard step.hasPrefix("@") else {
            view.typeText(step)
            try? await Task.sleep(for: .milliseconds(80))
            return
        }
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "@sleep":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        case "@mark":
            log("MARK \(arg)")
            try? await Task.sleep(for: .milliseconds(3000))
        case "@log":
            log(arg)
        case "@raw":
            view.send(Array(arg.utf8))
        case "@ctrl":
            if let c = arg.uppercased().unicodeScalars.first { view.send([UInt8(c.value & 0x1f)]) }
        case "@key":
            sendKey(arg, view: view)
        case "@width":
            surfaceWidth = arg == "full" ? nil : CGFloat(Double(arg) ?? 600)
            try? await Task.sleep(for: .milliseconds(400))
            log("grid \(session.cols)x\(session.rows)")
        case "@font":
            pool.setFontSize(CGFloat(Double(arg) ?? 14))
            try? await Task.sleep(for: .milliseconds(400))
            log("grid \(session.cols)x\(session.rows)")
        case "@dark":
            pool.setAppearance(dark: arg != "0")
        case "@metal":
            pool.setUseMetal(arg != "0")
            log("metal \(session.isUsingMetal)")
        case "@detach":
            session.detach()
        case "@attach":
            session.retry()
        case "@reconnect":
            await reconnect()
        case "@drop":
            await connection?.close()
            pool.setConnection(nil)
        case "@paste":
            UIPasteboard.general.string = arg
            view.paste(nil)
        case "@copyall":
            view.selectAll(nil)
            view.copy(nil)
            let text = UIPasteboard.general.string ?? ""
            log("copied \(text.count) chars, last line: \(text.split(separator: "\n").last ?? "")")
        case "@focus":
            _ = view.becomeFirstResponder()
            log("focus: first responder \(view.isFirstResponder), hardware keyboard \(WierdrTerminalView.hardwareKeyboardConnected), accessory \(view.inputAccessoryView.map { "\(type(of: $0))" } ?? "nil")")
        case "@blur":
            _ = view.resignFirstResponder()
        case "@expect":
            let (text, timeout) = splitTimeout(arg)
            let start = Date()
            var found = false
            while Date().timeIntervalSince(start) < timeout {
                if screenText(view).contains(text) { found = true; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            log("\(found ? "PASS" : "FAIL") expect \(text.debugDescription) after \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        case "@count":
            let all = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
            log("count \(arg.debugDescription) = \(all.components(separatedBy: arg).count - 1)")
        case "@screen":
            log("screen:\n\(screenText(view))")
        case "@read":
            if let address, let r = try? await connection?.readTerminal(address) {
                log("core screen:\n\(r.text.split(separator: "\n").suffix(12).joined(separator: "\n"))")
            }
        case "@stats":
            let st = await session.pipe.readStats()
            log("feed stats: \(st.bytes) bytes in \(st.chunks) chunks, \(String(format: "%.2f", st.seconds))s parsing")
        case "@waitbytes":
            let (n, timeout) = splitTimeout(arg)
            let start = Date()
            let base = await session.pipe.readStats().bytes
            var st = await session.pipe.readStats()
            while st.bytes - base < Int(n) ?? 0, Date().timeIntervalSince(start) < timeout {
                try? await Task.sleep(for: .milliseconds(20))
                st = await session.pipe.readStats()
            }
            log("waitbytes \(st.bytes - base) after \(String(format: "%.2f", Date().timeIntervalSince(start)))s, \(st.chunks) chunks")
        case "@scrolltop":
            view.scrollTo(row: 0)
            try? await Task.sleep(for: .milliseconds(300))
            log(scrollInfo(view))
        case "@scrollinfo":
            log(scrollInfo(view))
        case "@metalscale":
            // `@metalscale 1.72` renders Metal like an iPad Pro on Display Zoom "More Space"; `@metalscale off`.
            WierdrTerminalView.debugMetalScale = arg == "off" ? nil : CGFloat(Double(arg) ?? 0)
            view.matchMetalScale()
            try? await Task.sleep(for: .milliseconds(300))
            log("metal scale \(view.subviews.first { $0 is MTKView }?.contentScaleFactor ?? 0) screen \(view.window?.screen.scale ?? 0)/\(view.window?.screen.nativeScale ?? 0)")
        case "@kill":
            if let address { _ = try? await connection?.killTerminal(address) }
        case "@quit":
            await killAndQuit()
        default:
            log("unknown step \(step)")
        }
    }

    private func scrollInfo(_ v: WierdrTerminalView) -> String {
        "scroll offset=\(v.contentOffset.y) size=\(v.contentSize.height) bounds=\(v.bounds) inset=\(v.adjustedContentInset) safe=\(v.safeAreaInsets) pos=\(v.scrollPosition) rows=\(v.terminalDimensions.rows)"
    }

    private func splitTimeout(_ arg: String) -> (String, Double) {
        if let r = arg.range(of: " ", options: .backwards), let t = Double(arg[r.upperBound...]) {
            return (String(arg[..<r.lowerBound]), t)
        }
        return (arg, 10)
    }

    private func screenText(_ view: WierdrTerminalView) -> String {
        let all = String(decoding: view.getBufferAsData(kind: .active), as: UTF8.self)
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(max(view.terminalDimensions.rows, 1) + 1).joined(separator: "\n")
    }

    private func sendKey(_ name: String, view: WierdrTerminalView) {
        switch name {
        case "left": view.sendKeyLeft()
        case "right": view.sendKeyRight()
        case "up": view.sendKeyUp()
        case "down": view.sendKeyDown()
        case "esc": view.send([0x1b])
        case "tab": view.send([0x09])
        case "enter": view.insertText("\n")
        case "backspace": view.deleteBackward()
        default:
            if let m = WierdrTerminalView.keymap.first(where: { $0.name == name }) {
                view.send(m.bytes)
            } else {
                log("unknown key \(name)")
            }
        }
    }
}
#endif
