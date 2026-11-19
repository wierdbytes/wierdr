import Foundation
import HerdrCore

/// wierdrd, Wierdr's daemon, on the connected computer: what the app finds there and
/// how it sets it up. Everything goes through herdr-core's `machine.exec` (so it runs
/// in the core's session on that computer, not in the SSH login): one probe, a short
/// shell script that says the OS, where Homebrew and wierdrd are, wierdrd's version,
/// whether it comes from the formula and whether it runs; then, if the person asks,
/// one action with Homebrew (install, start, update). See docs/wierdrd.md.
public enum Daemon {
    /// The program, its process name.
    public static let name = "wierdrd"
    /// The Homebrew tap: github.com/wierdbytes/homebrew-apps (its `Formula/wierdrd.rb` is
    /// written by Wierdr's release workflow).
    public static let tap = "wierdbytes/apps"
    public static let formula = "wierdbytes/apps/wierdrd"
    /// The oldest wierdrd this app works with: an older one is offered an update.
    public static let minimumVersion = "0.1.0"

    /// How long an action may take (`machine.exec` allows 600 s).
    static let actionTimeout: Double = 600

    /// What the probe found.
    public struct Status: Equatable, Sendable {
        /// `uname -s`: `Darwin` on a Mac.
        public var os: String = ""
        /// Homebrew's `brew`, if there is one.
        public var brew: String?
        /// wierdrd's path, if installed (Homebrew's, or a build from source in ~/.local/bin).
        public var path: String?
        /// What `wierdrd --version` says (nil: none, or a wierdrd too old to say).
        public var version: String?
        /// Installed by the formula (`<prefix>/opt/wierdrd`): Homebrew can start and update it.
        public var fromBrew = false
        /// A `wierdrd` process runs.
        public var running = false
        /// When it doesn't: the Homebrew service's last exit code (launchd: `sh.brew.wierdrd`,
        /// `homebrew.mxcl.wierdrd` in older Homebrew), if any.
        public var lastExit: String?
        /// When it doesn't: the last line of the service's log.
        public var lastLog: String?

        public init(os: String = "", brew: String? = nil, path: String? = nil, version: String? = nil,
                    fromBrew: Bool = false, running: Bool = false, lastExit: String? = nil, lastLog: String? = nil) {
            self.os = os
            self.brew = brew
            self.path = path
            self.version = version
            self.fromBrew = fromBrew
            self.running = running
            self.lastExit = lastExit
            self.lastLog = lastLog
        }

        /// The probe's `key=value` lines.
        public static func parse(_ text: String) -> Status {
            var s = Status()
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq]
                let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                let value: String? = raw.isEmpty ? nil : raw
                switch key {
                case "os": s.os = raw
                case "brew": s.brew = value
                case "wierdrd": s.path = value
                case "version": s.version = value
                case "formula": s.fromBrew = raw == "1"
                case "running": s.running = raw == "1"
                case "exit": s.lastExit = value
                case "log": s.lastLog = value
                default: break
                }
            }
            return s
        }

        public var isMac: Bool { os == "Darwin" }

        /// Older than the app wants (or too old to say its version).
        public var isOutdated: Bool {
            guard path != nil else { return false }
            guard let version else { return true }
            return Daemon.compare(version, Daemon.minimumVersion) < 0
        }

        /// What the app should say and offer.
        public var verdict: Verdict {
            guard isMac else { return .unsupported(os: os.isEmpty ? "this system" : os) }
            if running {
                return isOutdated && fromBrew && brew != nil ? .offer(.update) : .running
            }
            guard path != nil else { return brew == nil ? .needsBrew : .offer(.install) }
            guard fromBrew, brew != nil else { return .stoppedOutsideBrew }
            return .offer(isOutdated ? .update : .start)
        }
    }

    /// What can be done about it.
    public enum Action: String, Sendable, CaseIterable {
        /// Tap, trust, install the formula, start its service.
        case install
        /// Start (restart) the service.
        case start
        /// Pull the tap, upgrade the formula, restart the service.
        case update
    }

    public enum Verdict: Equatable, Sendable {
        /// It runs (and is new enough, or can't be updated from here).
        case running
        /// Not a Mac: wierdrd is macOS only.
        case unsupported(os: String)
        /// Not installed, and no Homebrew to install it with.
        case needsBrew
        /// Installed outside Homebrew (a build from source) and not running.
        case stoppedOutsideBrew
        case offer(Action)
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    // MARK: Running it

    /// Runs the probe on the connected computer.
    public static func probe(on core: CoreConnection) async throws -> Status {
        let r = try await core.exec(ExecParams(argv: ["/bin/sh", "-c", probeScript], timeout: 20))
        guard r.code == 0 else {
            throw Failure("Couldn't check \(name) (exit \(r.code.map(String.init) ?? "?")): \(tail(r))")
        }
        return Status.parse(r.stdoutText)
    }

    /// Runs `action` with Homebrew (`brew` from the probe); throws with the end of its output.
    public static func perform(_ action: Action, brew: String, on core: CoreConnection) async throws {
        let r = try await core.exec(ExecParams(argv: ["/bin/sh", "-c", script(for: action)],
                                               env: ["WIERDR_BREW": brew], timeout: actionTimeout))
        if r.timedOut { throw Failure("Homebrew took longer than \(Int(actionTimeout / 60)) minutes. \(tail(r))") }
        guard r.code == 0 else { throw Failure(tail(r)) }
    }

    /// The last lines of what a command said (errors last), for the person.
    static func tail(_ r: ExecResult, lines: Int = 8) -> String {
        let text = (r.stdoutText + "\n" + r.stderrText)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let shown = text.suffix(lines).joined(separator: "\n")
        return shown.isEmpty ? "No output." : shown
    }

    /// The terminal commands an action stands for (shown to the person).
    public static func commands(for action: Action) -> [String] {
        switch action {
        case .install:
            return ["brew tap \(tap)", "brew install \(formula)", "brew services start \(name)"]
        case .start:
            return ["brew services restart \(name)"]
        case .update:
            return ["brew upgrade \(formula)", "brew services restart \(name)"]
        }
    }

    // MARK: Scripts

    /// `/bin/sh` (run as argv, no login shell). Prints `key=value` lines (`Status.parse`).
    /// Looks for Homebrew and wierdrd on the core's PATH and where they're installed
    /// (Apple silicon, Intel, Linuxbrew; a build from source in ~/.local/bin).
    public static let probeScript = """
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    echo "os=$(uname -s)"
    brew=""
    for p in "$(command -v brew 2>/dev/null)" /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
      if [ -n "$p" ] && [ -x "$p" ]; then brew="$p"; break; fi
    done
    echo "brew=$brew"
    prefix=""
    if [ -n "$brew" ]; then prefix="${brew%/bin/brew}"; fi
    d=""
    for p in "$(command -v wierdrd 2>/dev/null)" "${prefix:-/nonexistent}/bin/wierdrd" "$HOME/.local/bin/wierdrd"; do
      if [ -n "$p" ] && [ -x "$p" ]; then d="$p"; break; fi
    done
    echo "wierdrd=$d"
    if [ -n "$d" ]; then echo "version=$("$d" --version 2>/dev/null | head -n 1)"; fi
    if [ -n "$prefix" ] && [ -d "$prefix/opt/wierdrd" ]; then echo "formula=1"; fi
    if pgrep -x wierdrd >/dev/null 2>&1; then
      echo "running=1"
    else
      if command -v launchctl >/dev/null 2>&1; then
        for label in sh.brew.wierdrd homebrew.mxcl.wierdrd; do
          e=$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | sed -n 's/^[[:space:]]*last exit code = //p' | head -n 1)
          if [ -n "$e" ]; then echo "exit=$e"; break; fi
        done
      fi
      if [ -n "$prefix" ] && [ -f "$prefix/var/log/wierdrd.log" ]; then
        echo "log=$(tail -n 1 "$prefix/var/log/wierdrd.log" | cut -c 1-300)"
      fi
    fi
    exit 0
    """

    /// Homebrew quietly, without asking: no auto-update (an install only needs this tap,
    /// which it clones), no hints, no cleanup of other formulae.
    private static let brewEnvironment = """
    set -e
    brew="$WIERDR_BREW"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
    export HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1 NONINTERACTIVE=1
    PATH="$(dirname "$brew"):$PATH:/usr/bin:/bin:/usr/sbin:/sbin"
    """

    /// The tap, trusted (Homebrew 6 wants it of a third-party tap; installing a formula by
    /// its full name trusts that formula anyway).
    private static let tapLines = """
    "$brew" tap \(tap)
    if "$brew" trust --help >/dev/null 2>&1; then "$brew" trust --tap \(tap); fi
    """

    public static func script(for action: Action) -> String {
        switch action {
        case .install:
            return brewEnvironment + "\n" + tapLines + """

            "$brew" install \(formula)
            "$brew" services restart \(name)
            """
        case .start:
            return brewEnvironment + "\n" + """
            "$brew" services restart \(name)
            """
        case .update:
            // The tap's own pull, not `brew update` (every tap, and fails with any of them).
            return brewEnvironment + "\n" + tapLines + """

            repo="$("$brew" --repository \(tap))"
            git -C "$repo" pull --ff-only --quiet
            "$brew" upgrade \(formula) || "$brew" install \(formula)
            "$brew" services restart \(name)
            """
        }
    }

    // MARK: Versions

    /// Compares dotted versions by their numbers (`0.10.0` > `0.9.1`; what isn't a number is 0).
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" }).map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
