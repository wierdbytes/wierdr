import Foundation

/// Why an SSH connection to herdr-core failed or ended.
public enum SSHError: Error, Sendable, Equatable {
    /// The TCP connection could not be made (DNS, refused, unreachable, ...).
    case connectFailed(String)
    /// TCP connect, SSH handshake, authentication or exec took longer than
    /// `SSHConfig.connectTimeout` (time spent in the host-key prompt excluded).
    case timedOut
    /// The host-key validator did not accept the server's key.
    case hostKeyRejected(fingerprint: String)
    /// The server refused our credentials. `methodsOffered` are the methods the
    /// server said it would accept (`publickey`, `password`, `hostbased`), so
    /// the UI can say e.g. "this Mac only takes keys".
    case authenticationFailed(methodsOffered: [String])
    /// The server refused to run the remote command (exec request rejected,
    /// or the session channel could not be opened).
    case execRejected(stderr: String)
    /// The remote command exited with a non-zero status. `stderr` is the tail of
    /// what it printed there (e.g. "herdr-core is not installed here", 127).
    case remoteExited(status: Int, stderr: String)
    /// The remote command was killed by a signal.
    case remoteSignaled(signal: String, stderr: String)
    /// The connection dropped (network gone, server closed, protocol error).
    case disconnected(String)
    /// The transport was closed locally; no more writes.
    case closed

    /// True when the remote side said herdr-core is not installed (exit 127 or
    /// the marker line of the remote command).
    public var isHerdrCoreMissing: Bool {
        switch self {
        case .remoteExited(let status, let stderr):
            return status == 127 || stderr.contains(SSHConfig.notInstalledMarker)
        case .execRejected(let stderr), .remoteSignaled(_, let stderr):
            return stderr.contains(SSHConfig.notInstalledMarker)
        default:
            return false
        }
    }
}

extension SSHError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectFailed(let why):
            return "Cannot connect: \(why)"
        case .timedOut:
            return "The connection timed out"
        case .hostKeyRejected(let fingerprint):
            return "The server's host key (\(fingerprint)) was not accepted"
        case .authenticationFailed(let methods):
            let list = methods.isEmpty ? "none we support" : methods.joined(separator: ", ")
            return "Authentication failed (the server accepts: \(list))"
        case .execRejected(let stderr):
            return Self.withStderr("The server refused to run herdr-core", stderr)
        case .remoteExited(let status, let stderr):
            if status == 127 || stderr.contains(SSHConfig.notInstalledMarker) {
                return Self.withStderr("herdr-core (hc) is not installed on that machine", stderr)
            }
            return Self.withStderr("herdr-core exited with status \(status)", stderr)
        case .remoteSignaled(let signal, let stderr):
            return Self.withStderr("herdr-core was killed (SIG\(signal))", stderr)
        case .disconnected(let why):
            return "Disconnected: \(why)"
        case .closed:
            return "The connection is closed"
        }
    }

    private static func withStderr(_ message: String, _ stderr: String) -> String {
        let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? message : "\(message): \(tail)"
    }
}

/// Problems with keys: parsing, unsupported types, Keychain.
public enum SSHKeyError: Error, Sendable, Equatable {
    /// Not a key we can read; the string says what was wrong.
    case invalidFormat(String)
    /// The private key is protected by a passphrase.
    case encrypted
    /// A key type SwiftNIO SSH cannot use (RSA, DSA, P-384 sk-...).
    case unsupportedKeyType(String)
    /// A Keychain call failed with this OSStatus.
    case keychain(Int32)
}

extension SSHKeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let why):
            return "Not a valid OpenSSH private key: \(why)"
        case .encrypted:
            return "The key is protected by a passphrase. Import a copy without one (ssh-keygen -p -N \"\" -f <copy>)."
        case .unsupportedKeyType(let type):
            if type.contains("rsa") {
                return "RSA keys are not supported by SwiftNIO SSH; use ed25519 (ssh-keygen -t ed25519)."
            }
            return "Unsupported key type \(type); use ed25519 (ssh-keygen -t ed25519)."
        case .keychain(let status):
            return "Keychain error \(status)"
        }
    }
}
