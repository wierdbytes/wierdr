import Foundation
import NIOSSH

/// The key a server presented during the SSH handshake.
public struct HostKeyInfo: Sendable, Hashable {
    /// The host as configured (not resolved).
    public var host: String
    public var port: Int
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, ...
    public var keyType: String
    /// Base64 of the SSH wire-format public key.
    public var keyBase64: String
    /// `SHA256:...` as `ssh-keygen -lf` prints it.
    public var fingerprint: String

    /// `ssh-ed25519 AAAA...` (no comment).
    public var openSSHPublicKey: String { "\(keyType) \(keyBase64)" }

    public init(host: String, port: Int, keyType: String, keyBase64: String, fingerprint: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.keyBase64 = keyBase64
        self.fingerprint = fingerprint
    }

    /// From an OpenSSH public key line (`type base64 [comment]`).
    public init?(host: String, port: Int, openSSHPublicKey line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        self.init(
            host: host, port: port, keyType: String(parts[0]), keyBase64: String(parts[1]),
            fingerprint: SSHFingerprint.sha256(blob: blob))
    }

    init(host: String, port: Int, key: NIOSSHPublicKey) {
        let line = String(openSSHPublicKey: key)
        // NIO always produces "type base64".
        self.init(host: host, port: port, openSSHPublicKey: line)!
    }
}

public enum HostKeyDecision: Sendable {
    case accept
    case reject
}

/// Decides whether to trust a server's host key. Called once per handshake
/// (and again on re-key), off the main actor; may take as long as it likes
/// (e.g. while an alert waits for the user): the connect timeout is paused.
public protocol HostKeyValidator: Sendable {
    func validate(_ key: HostKeyInfo) async -> HostKeyDecision
}

/// A validator from a closure.
public struct ClosureHostKeyValidator: HostKeyValidator {
    private let body: @Sendable (HostKeyInfo) async -> HostKeyDecision

    public init(_ body: @escaping @Sendable (HostKeyInfo) async -> HostKeyDecision) {
        self.body = body
    }

    public func validate(_ key: HostKeyInfo) async -> HostKeyDecision {
        await body(key)
    }
}

/// Accepts exactly the given fingerprints (pinning); rejects everything else.
public struct PinnedHostKeyValidator: HostKeyValidator {
    public var fingerprints: Set<String>

    public init(fingerprints: Set<String>) {
        self.fingerprints = fingerprints
    }

    public func validate(_ key: HostKeyInfo) async -> HostKeyDecision {
        fingerprints.contains(key.fingerprint) ? .accept : .reject
    }
}
