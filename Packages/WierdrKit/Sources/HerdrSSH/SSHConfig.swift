import Crypto
import Foundation

/// Where and how to reach herdr-core over SSH.
public struct SSHConfig: Sendable {
    /// How we prove who we are.
    public enum Auth: Sendable {
        case password(String)
        case ed25519(Curve25519.Signing.PrivateKey)
        case ecdsaP256(P256.Signing.PrivateKey)

        /// Public-key auth with a stored or imported key.
        public static func key(_ key: SSHPrivateKey) -> Auth {
            switch key {
            case .ed25519(let k): return .ed25519(k)
            case .ecdsaP256(let k): return .ecdsaP256(k)
            }
        }
    }

    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    /// Run on the server in an exec channel; must speak herdr-core's API on
    /// stdin/stdout. Defaults to `SSHConfig.defaultRemoteCommand`.
    public var remoteCommand: String
    /// Budget for TCP connect + SSH handshake + auth + exec. Time the
    /// host-key validator spends (an alert waiting for the user) is not counted.
    public var connectTimeout: TimeInterval
    /// TCP keepalive: idle seconds before the first probe (0 disables).
    /// Probes then go every 5 s; 4 unanswered probes drop the connection.
    public var keepaliveIdle: Int

    public init(
        host: String,
        port: Int = 22,
        username: String,
        auth: Auth,
        remoteCommand: String = SSHConfig.defaultRemoteCommand,
        connectTimeout: TimeInterval = 10,
        keepaliveIdle: Int = 15
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.remoteCommand = remoteCommand
        self.connectTimeout = connectTimeout
        self.keepaliveIdle = keepaliveIdle
    }
}

extension SSHConfig.Auth: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never shows secrets (logs, `print(config)`).
    public var description: String {
        switch self {
        case .password: return "password(<redacted>)"
        case .ed25519(let k): return "ed25519(\(SSHPrivateKey.ed25519(k).fingerprint))"
        case .ecdsaP256(let k): return "ecdsaP256(\(SSHPrivateKey.ecdsaP256(k).fingerprint))"
        }
    }

    public var debugDescription: String { description }
}

extension SSHConfig {
    /// What the remote command prints on stderr (exit 127) when it finds no
    /// herdr-core. Same words herdr-core itself uses when dialing machines.
    public static let notInstalledMarker = "herdr-core is not installed here"

    /// `herdr-core connect` on the server, wherever it is.
    ///
    /// A non-interactive SSH session on macOS has a bare PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), and the installer puts hc in
    /// `~/.local/bin`. Like herdr-core's own `machine` dialing, this looks on
    /// PATH first, then in the usual install places, and prints
    /// `notInstalledMarker` with exit status 127 when there is none.
    ///
    /// It is one `/bin/sh -c '...'` with no single quotes or backslashes
    /// inside, so the login shell (zsh, bash, fish, ...) passes it through
    /// untouched.
    public static let defaultRemoteCommand = remoteCommand()

    /// The default remote command, optionally for a named herdr-core session
    /// (`HC_SESSION`). Session names are limited to `[A-Za-z0-9._-]`; others
    /// are ignored.
    public static func remoteCommand(session: String? = nil) -> String {
        let dirs = [
            "$HOME/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "$HOME/.cargo/bin",
            "$HOME/.local/share/mise/shims", "$HOME/.nix-profile/bin", "/run/current-system/sw/bin",
        ]
        var candidates = ["\"$(command -v herdr-core)\""]
        candidates += dirs.map { "\"\($0)/herdr-core\"" }
        candidates += ["\"$(command -v hc)\"", "\"$HOME/.local/bin/hc\""]
        var env = ""
        if let session, !session.isEmpty,
            session.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }),
            session.allSatisfy(\.isASCII)
        {
            env = "HC_SESSION=\(session) "
        }
        let script =
            "for p in \(candidates.joined(separator: " ")); do "
            + "[ -n \"$p\" ] && [ -x \"$p\" ] && \(env)exec \"$p\" connect; done; "
            + "echo \"\(notInstalledMarker) (looked on PATH and in ~/.local/bin, Homebrew, ~/.cargo/bin, mise, nix)\" >&2; exit 127"
        return "/bin/sh -c '\(script)'"
    }
}
