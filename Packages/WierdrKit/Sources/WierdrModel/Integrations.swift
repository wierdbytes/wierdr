import Foundation
import HerdrCore

/// Wierdr's integrations for the agent harnesses on the connected computer: pi-wierdr for pi,
/// `cc@wierdr` for Claude Code, `codex@wierdr` for Codex (they write the `agent.*` labels and
/// the limits document the app reads; Integrations/, docs/pi.md, claude-code.md, codex.md).
/// One probe finds which harnesses are there (on the login shell's PATH, as the person's
/// terminals have it), their versions and whether the integration is in; an action installs
/// one with the harness's own command. All through herdr-core's `machine.exec`.
public enum Integrations {
    public enum Harness: String, CaseIterable, Sendable, Hashable {
        case pi, claude, codex

        public var name: String {
            switch self {
            case .pi: return "pi"
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        /// The program on PATH.
        public var command: String { rawValue }

        /// What the person installs, as the harness names it.
        public var integration: String {
            switch self {
            case .pi: return "pi-wierdr"
            case .claude: return "cc@wierdr"
            case .codex: return "codex@wierdr"
            }
        }

        /// The oldest harness the integration runs on (pi-wierdr's peer dependencies; the mods
        /// API's `$.settings.read({ key })`; Codex's hooks with the plugin's events).
        public var minimumVersion: String {
            switch self {
            case .pi: return "1.5.0"
            case .claude: return "2.1.304"
            case .codex: return "0.167.0"
            }
        }

        /// The terminal commands installing it (shown to the person; `script(for:)` runs them).
        public func commands(_ state: State) -> [String] {
            switch (self, state) {
            case (.pi, _):
                return ["pi install npm:@wierdbytes/pi-wierdr"]
            case (.claude, .disabled):
                return ["claude plugin enable cc@wierdr"]
            case (.claude, _):
                return ["claude plugin marketplace add wierdbytes/wierdr", "claude plugin install cc@wierdr"]
            case (.codex, _):
                return ["codex plugin marketplace add wierdbytes/wierdr", "codex plugin add codex@wierdr"]
            }
        }
    }

    /// The integration in a harness.
    public enum State: String, Sendable {
        case installed, disabled, missing
    }

    /// A harness the probe found.
    public struct Found: Equatable, Sendable {
        public var harness: Harness
        public var path: String
        /// The first dotted number of `--version` (nil: it said none).
        public var version: String?
        public var state: State = .missing
        /// pi: Wierdr's packages pi-wierdr replaces (`pi-herdr`, `pi-agents`), still installed.
        public var old: [String] = []
        /// Codex: hooks of `codex@wierdr` were trusted once (Codex asks again after an update).
        public var trusted = false
        /// Codex: a python3 that runs (the hooks need it; macOS's stub without the
        /// command line tools would only ask to install them).
        public var python = false

        public init(harness: Harness, path: String, version: String? = nil, state: State = .missing,
                    old: [String] = [], trusted: Bool = false, python: Bool = false) {
            self.harness = harness
            self.path = path
            self.version = version
            self.state = state
            self.old = old
            self.trusted = trusted
            self.python = python
        }

        public var verdict: Verdict {
            guard let version, Daemon.compare(version, harness.minimumVersion) >= 0 else {
                return .tooOld(needs: harness.minimumVersion)
            }
            if harness == .codex && !python { return .needsPython }
            switch state {
            case .installed: return .installed
            case .disabled: return harness == .claude ? .offer(.enable) : .offer(.install)
            case .missing: return .offer(.install)
            }
        }
    }

    public enum Action: String, Sendable {
        case install, enable
    }

    public enum Verdict: Equatable, Sendable {
        case installed
        case offer(Action)
        /// The harness is older than the integration needs: the person updates it.
        case tooOld(needs: String)
        /// Codex without a python3 that runs.
        case needsPython
    }

    /// What the probe found: the harnesses there, in `Harness` order.
    public struct Status: Equatable, Sendable {
        public var found: [Found] = []
        /// The probe ran to its end (a missing line means it was cut short).
        public var complete = false

        public init(found: [Found] = [], complete: Bool = false) {
            self.found = found
            self.complete = complete
        }

        public subscript(_ harness: Harness) -> Found? { found.first { $0.harness == harness } }

        /// Something to install or enable.
        public var offers: Bool {
            found.contains { if case .offer = $0.verdict { return true } else { return false } }
        }

        /// The probe's `<harness>.<key>=<value>` lines (other lines, from the login shell, ignored).
        public static func parse(_ text: String) -> Status {
            var found: [Harness: Found] = [:]
            var s = Status()
            for line in text.split(separator: "\n") {
                if line == "done=1" { s.complete = true; continue }
                guard let dot = line.firstIndex(of: "."), let eq = line.firstIndex(of: "="), dot < eq,
                      let harness = Harness(rawValue: String(line[..<dot])) else { continue }
                let key = line[line.index(after: dot)..<eq]
                let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if key == "path" {
                    if !value.isEmpty { found[harness] = Found(harness: harness, path: value) }
                    continue
                }
                guard var f = found[harness] else { continue }
                switch key {
                case "version": f.version = value.isEmpty ? nil : value
                case "state": f.state = State(rawValue: value) ?? .missing
                case "old": if !value.isEmpty { f.old.append(value) }
                case "trusted": f.trusted = value == "1"
                case "python": f.python = value == "1"
                default: break
                }
                found[harness] = f
            }
            s.found = Harness.allCases.compactMap { found[$0] }
            return s
        }
    }

    public typealias Failure = Daemon.Failure

    // MARK: Running it

    public static func probe(on core: CoreConnection) async throws -> Status {
        let r = try await core.exec(ExecParams(argv: ["/bin/sh", "-c", loginPath + "\n" + probeBody], timeout: 60))
        let s = Status.parse(r.stdoutText)
        guard r.code == 0, s.complete else {
            throw Failure("Couldn't check the agents (exit \(r.code.map(String.init) ?? "?")): \(Daemon.tail(r))")
        }
        return s
    }

    /// Installs (or enables) the integration of `found`'s harness.
    public static func perform(for found: Found, on core: CoreConnection) async throws {
        let r = try await core.exec(ExecParams(argv: ["/bin/sh", "-c", script(for: found)], timeout: 300))
        if r.timedOut { throw Failure("\(found.harness.name) took longer than 5 minutes. \(Daemon.tail(r))") }
        guard r.code == 0 else { throw Failure(Daemon.tail(r)) }
    }

    // MARK: Scripts

    /// `/bin/sh`: PATH as the person's login shell has it (bun's, npm's, mise's… folders are
    /// set in its rc files), asked of that shell with a marker line around what its rc files
    /// might print, given 10 s; then the usual folders after it.
    public static let loginPath = #"""
    shell=${SHELL:-/bin/sh}
    out=$(mktemp "${TMPDIR:-/tmp}/wierdr-path.XXXXXX")
    case "${shell##*/}" in
      fish) "$shell" -lic 'printf "\nwierdr-path:%s\n" (string join : $PATH)' </dev/null >"$out" 2>/dev/null & ;;
      bash|zsh|sh|dash|ksh) "$shell" -lic 'printf "\nwierdr-path:%s\n" "$PATH"' </dev/null >"$out" 2>/dev/null & ;;
      *) : & ;;
    esac
    pid=$!
    ( sleep 10; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    guard=$!
    wait "$pid" 2>/dev/null
    kill -PIPE "$guard" 2>/dev/null  # bash reports a job ended by TERM, not by PIPE
    lp=$(sed -n 's/^wierdr-path://p' "$out" | tail -n 1)
    rm -f "$out"
    PATH="${lp:+$lp:}$PATH:$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export PATH
    """#

    /// Prints `<harness>.<key>=<value>` lines and `done=1`. Claude Code is asked (`plugin
    /// list --json`); pi too (`pi list`); Codex's own list fetches a remote catalog (a minute
    /// and more), so its config and plugin cache are read instead.
    public static let probeBody = #"""
    ver() { "$1" --version 2>/dev/null </dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1; }
    if p=$(command -v pi 2>/dev/null); then
      echo "pi.path=$p"
      echo "pi.version=$(ver pi)"
      l=$(pi list 2>/dev/null </dev/null)
      case "$l" in *"npm:@wierdbytes/pi-wierdr"*) echo "pi.state=installed" ;; *) echo "pi.state=missing" ;; esac
      for o in pi-herdr pi-agents; do
        case "$l" in *"npm:@wierdbytes/$o"*) echo "pi.old=$o" ;; esac
      done
    fi
    if p=$(command -v claude 2>/dev/null); then
      echo "claude.path=$p"
      echo "claude.version=$(ver claude)"
      e=$(claude plugin list --json 2>/dev/null </dev/null | tr -d ' \n\t' | grep -o '"id":"cc@wierdr"[^}]*')
      case "$e" in
        "") echo "claude.state=missing" ;;
        *'"enabled":false'*) echo "claude.state=disabled" ;;
        *) echo "claude.state=installed" ;;
      esac
    fi
    if p=$(command -v codex 2>/dev/null); then
      echo "codex.path=$p"
      echo "codex.version=$(ver codex)"
      c="${CODEX_HOME:-$HOME/.codex}"
      s=$(sed -n '/^\[plugins\."codex@wierdr"\]/,/^\[/p' "$c/config.toml" 2>/dev/null)
      if [ -z "$s" ] || [ ! -d "$c/plugins/cache/wierdr/codex" ]; then
        echo "codex.state=missing"
      elif printf '%s\n' "$s" | grep -qE '^enabled[[:space:]]*=[[:space:]]*false'; then
        echo "codex.state=disabled"
      else
        echo "codex.state=installed"
      fi
      if grep -q 'codex@wierdr:hooks/hooks.json' "$c/config.toml" 2>/dev/null; then echo "codex.trusted=1"; fi
      py=$(command -v python3 2>/dev/null)
      if [ -n "$py" ] && { [ "$py" != /usr/bin/python3 ] || [ "$(uname -s)" != Darwin ] || xcode-select -p >/dev/null 2>&1; }; then
        echo "codex.python=1"
      fi
    fi
    echo "done=1"
    """#

    /// The harness's own commands, after `loginPath`; stops at the first that fails.
    public static func script(for found: Found) -> String {
        let body: String
        switch (found.harness, found.state) {
        case (.pi, _):
            // pi-wierdr replaces pi-herdr and pi-agents (the same tools twice otherwise).
            body = #"""
            pi install npm:@wierdbytes/pi-wierdr
            for o in pi-herdr pi-agents; do
              if pi list 2>/dev/null | grep -q "npm:@wierdbytes/$o"; then pi remove "npm:@wierdbytes/$o"; fi
            done
            """#
        case (.claude, .disabled):
            body = "claude plugin enable cc@wierdr"
        case (.claude, _):
            // A marketplace named wierdr (from GitHub or a checkout) is used as it is.
            body = #"""
            if ! claude plugin marketplace list 2>/dev/null | grep -qE '(^|[[:space:]])wierdr$'; then
              claude plugin marketplace add wierdbytes/wierdr
            fi
            claude plugin install cc@wierdr
            """#
        case (.codex, _):
            body = #"""
            if ! codex plugin marketplace list 2>/dev/null | grep -qE '^wierdr[[:space:]]'; then
              codex plugin marketplace add wierdbytes/wierdr
            fi
            codex plugin add codex@wierdr
            """#
        }
        return loginPath + "\nset -e\nexec </dev/null\n" + body
    }
}
