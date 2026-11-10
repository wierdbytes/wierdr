import Crypto
import Foundation

/// The device's SSH identity and saved passwords, in a `SecretStore`
/// (the Keychain in the app).
///
/// One identity at a time: an Ed25519 key generated on the device, or a key
/// imported from an OpenSSH private key file (Ed25519 or ECDSA P-256).
///
///     let keys = SSHKeyStore()                       // Keychain, service pw.xff.wierdr.ssh
///     let identity = try keys.loadOrCreateIdentity()
///     identity.openSSHPublicKey(comment: SSHPrivateKey.defaultComment)  // for authorized_keys
///     SSHConfig(host: "mac.local", username: "me", auth: .key(identity))
public struct SSHKeyStore: Sendable {
    public let secrets: any SecretStore

    static let ed25519Account = "identity.ed25519"
    static let p256Account = "identity.ecdsa-p256"

    public init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
    }

    // MARK: Identity

    /// The stored identity, if any.
    public func identity() throws -> SSHPrivateKey? {
        if let raw = try secrets.data(for: Self.ed25519Account) {
            do {
                return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
            } catch {
                throw SSHKeyError.invalidFormat("stored ed25519 identity is corrupt")
            }
        }
        if let raw = try secrets.data(for: Self.p256Account) {
            do {
                return .ecdsaP256(try P256.Signing.PrivateKey(rawRepresentation: raw))
            } catch {
                throw SSHKeyError.invalidFormat("stored P-256 identity is corrupt")
            }
        }
        return nil
    }

    /// The stored identity, or a new Ed25519 one (saved).
    public func loadOrCreateIdentity() throws -> SSHPrivateKey {
        if let key = try identity() { return key }
        return try generateIdentity()
    }

    /// Generates a new Ed25519 identity and saves it, replacing any other.
    @discardableResult
    public func generateIdentity() throws -> SSHPrivateKey {
        let key = SSHPrivateKey.generateEd25519()
        try saveIdentity(key)
        return key
    }

    /// Saves `key` as the identity, replacing any other.
    public func saveIdentity(_ key: SSHPrivateKey) throws {
        switch key {
        case .ed25519(let k):
            try secrets.set(k.rawRepresentation, for: Self.ed25519Account)
            try secrets.delete(account: Self.p256Account)
        case .ecdsaP256(let k):
            try secrets.set(k.rawRepresentation, for: Self.p256Account)
            try secrets.delete(account: Self.ed25519Account)
        }
    }

    /// Parses an OpenSSH private key file's text and saves it as the identity.
    @discardableResult
    public func importIdentity(openSSHPrivateKey text: String) throws -> SSHPrivateKey {
        let key = try SSHPrivateKey(importing: text)
        try saveIdentity(key)
        return key
    }

    public func deleteIdentity() throws {
        try secrets.delete(account: Self.ed25519Account)
        try secrets.delete(account: Self.p256Account)
    }

    // MARK: Passwords

    static func passwordAccount(host: String, port: Int, user: String) -> String {
        "password.\(user)@\(host.lowercased()):\(port)"
    }

    public func savePassword(_ password: String, host: String, port: Int = 22, user: String) throws {
        try secrets.set(Data(password.utf8), for: Self.passwordAccount(host: host, port: port, user: user))
    }

    public func password(host: String, port: Int = 22, user: String) throws -> String? {
        try secrets.data(for: Self.passwordAccount(host: host, port: port, user: user))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    public func deletePassword(host: String, port: Int = 22, user: String) throws {
        try secrets.delete(account: Self.passwordAccount(host: host, port: port, user: user))
    }
}
