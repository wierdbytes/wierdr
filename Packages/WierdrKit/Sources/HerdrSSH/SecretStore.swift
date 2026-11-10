import Foundation
import Security
import Synchronization

/// Where secrets (private keys, passwords) live. `KeychainSecretStore` in the
/// app; `InMemorySecretStore` in tests (so `swift test` never touches the
/// login keychain).
public protocol SecretStore: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(account: String) throws
}

/// Generic-password items in the Keychain, one service, any number of accounts.
/// Items are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available to
/// background reconnects after the first unlock, never synced or backed up to
/// another device.
public struct KeychainSecretStore: SecretStore {
    public var service: String
    /// Use the data-protection keychain on macOS too (needs a signed app with a
    /// keychain access group; iOS always uses it). Off: the legacy file keychain.
    public var useDataProtectionKeychain: Bool

    public static let defaultService = "pw.xff.wierdr.ssh"

    public init(service: String = KeychainSecretStore.defaultService, useDataProtectionKeychain: Bool = true) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtectionKeychain {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }

    public func data(for account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        default: throw SSHKeyError.keychain(status)
        }
    }

    public func set(_ data: Data, for account: String) throws {
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.merge(update) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SSHKeyError.keychain(status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SSHKeyError.keychain(status) }
    }
}

/// Secrets in memory, for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    public init() {}

    public func data(for account: String) throws -> Data? {
        items.withLock { $0[account] }
    }

    public func set(_ data: Data, for account: String) throws {
        items.withLock { $0[account] = data }
    }

    public func delete(account: String) throws {
        _ = items.withLock { $0.removeValue(forKey: account) }
    }

    /// All accounts currently stored (tests).
    public var accounts: [String] {
        items.withLock { Array($0.keys).sorted() }
    }
}
