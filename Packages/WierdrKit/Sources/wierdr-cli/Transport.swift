import Foundation
import HerdrCore

/// How to reach a core. Add new ways here (e.g. `--ssh user@host` via HerdrSSH's
/// `SSHTransport`): parse the flag in `Options.parse`, then build it in `makeTransport`.
struct Options {
    /// Path to `hc` (`--hc`); default: looked up in PATH and ~/.local/bin.
    var hcPath: String?
    /// Remaining arguments: the subcommand and its arguments.
    var rest: [String] = []

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--hc":
                guard let v = it.next() else { throw CLIError.usage("--hc needs a path") }
                o.hcPath = v
            default:
                o.rest.append(a)
            }
        }
        return o
    }
}

/// The single place that turns options into a byte pipe to a core.
func makeTransport(_ options: Options) throws -> CoreTransport {
    // Plug other transports in here (SSH: `--ssh user@host` → SSHTransport).
    try ProcessTransport(executable: options.hcPath.map { URL(fileURLWithPath: $0) })
}

/// A started connection.
func connect(_ options: Options) async throws -> CoreConnection {
    let connection = CoreConnection(transport: try makeTransport(options))
    try await connection.start()
    return connection
}
