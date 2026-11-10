import Crypto
import Foundation
import Testing

@testable import HerdrSSH

@Suite("Keys")
struct KeyTests {
    @Test func generatedKeyMatchesSSHKeygenFingerprint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for key in [SSHPrivateKey.generateEd25519(), .ecdsaP256(P256.Signing.PrivateKey())] {
            let line = key.openSSHPublicKey(comment: "wierdr@test")
            #expect(line.hasPrefix(key.keyType + " AAAA"))
            #expect(line.hasSuffix(" wierdr@test"))
            let file = dir.appendingPathComponent("k-\(key.keyType).pub")
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            #expect(try keygenFingerprint(file) == key.fingerprint)
            #expect(SSHFingerprint.sha256(openSSHPublicKey: line) == key.fingerprint)
            // NIO parses what we print.
            #expect(HostKeyInfo(host: "h", port: 22, openSSHPublicKey: line)?.fingerprint == key.fingerprint)
        }
    }

    @Test func fingerprintHasNoPadding() {
        let fp = SSHPrivateKey.generateEd25519().fingerprint
        #expect(fp.hasPrefix("SHA256:"))
        #expect(!fp.hasSuffix("="))
        #expect(fp.count == "SHA256:".count + 43)
    }

    @Test(arguments: [["-t", "ed25519"], ["-t", "ecdsa", "-b", "256"]])
    func importsOpenSSHPrivateKey(type: [String]) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try sshKeygen(dir, name: "id", type: type)
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("BEGIN OPENSSH PRIVATE KEY"))
        let key = try SSHPrivateKey(importing: text)
        let pub = try String(contentsOf: path.appendingPathExtension("pub"), encoding: .utf8)
        let expected = pub.split(separator: " ").prefix(2).joined(separator: " ")
        #expect(key.openSSHPublicKey() == expected)
        #expect(key.fingerprint == (try keygenFingerprint(path.appendingPathExtension("pub"))))
    }

    @Test func importsPEMP256Key() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try sshKeygen(dir, name: "id", type: ["-t", "ecdsa", "-b", "256"], extra: ["-m", "PEM"])
        let key = try SSHPrivateKey(importing: try String(contentsOf: path, encoding: .utf8))
        #expect(key.keyType == "ecdsa-sha2-nistp256")
        #expect(key.fingerprint == (try keygenFingerprint(path.appendingPathExtension("pub"))))
    }

    @Test func rejectsEncryptedKey() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try sshKeygen(dir, name: "id", type: ["-t", "ed25519"], passphrase: "secret")
        #expect(throws: SSHKeyError.encrypted) {
            try SSHPrivateKey(importing: try String(contentsOf: path, encoding: .utf8))
        }
    }

    @Test func rejectsRSAKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try sshKeygen(dir, name: "id", type: ["-t", "rsa", "-b", "2048"])
        let error = #expect(throws: SSHKeyError.self) {
            try SSHPrivateKey(importing: try String(contentsOf: path, encoding: .utf8))
        }
        #expect(error == .unsupportedKeyType("ssh-rsa"))
        #expect(error?.localizedDescription.contains("RSA keys are not supported by SwiftNIO SSH") == true)
        let pem = try sshKeygen(dir, name: "pem", type: ["-t", "rsa", "-b", "2048"], extra: ["-m", "PEM"])
        #expect(throws: SSHKeyError.unsupportedKeyType("ssh-rsa")) {
            try SSHPrivateKey(importing: try String(contentsOf: pem, encoding: .utf8))
        }
    }

    @Test func rejectsGarbageAndPublicKeys() {
        #expect(throws: SSHKeyError.self) { try SSHPrivateKey(importing: "hello") }
        let pub = SSHPrivateKey.generateEd25519().openSSHPublicKey()
        #expect(throws: SSHKeyError.self) { try SSHPrivateKey(importing: pub) }
        #expect(throws: SSHKeyError.self) {
            try SSHPrivateKey(importing: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----")
        }
    }
}

@Suite("Key store")
struct KeyStoreTests {
    @Test func identityLifecycle() throws {
        let secrets = InMemorySecretStore()
        let store = SSHKeyStore(secrets: secrets)
        #expect(try store.identity() == nil)
        let key = try store.loadOrCreateIdentity()
        #expect(key.keyType == "ssh-ed25519")
        #expect(secrets.accounts == ["identity.ed25519"])
        #expect(try store.loadOrCreateIdentity().fingerprint == key.fingerprint)
        #expect(try store.identity()?.fingerprint == key.fingerprint)

        let p256 = SSHPrivateKey.ecdsaP256(P256.Signing.PrivateKey())
        try store.saveIdentity(p256)
        #expect(try store.identity()?.fingerprint == p256.fingerprint)
        #expect(secrets.accounts == ["identity.ecdsa-p256"])

        let fresh = try store.generateIdentity()
        #expect(fresh.fingerprint != key.fingerprint)
        #expect(try store.identity()?.fingerprint == fresh.fingerprint)

        try store.deleteIdentity()
        #expect(try store.identity() == nil)
        #expect(secrets.accounts.isEmpty)
    }

    @Test func importIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try sshKeygen(dir, name: "id", type: ["-t", "ed25519"])
        let store = SSHKeyStore(secrets: InMemorySecretStore())
        let key = try store.importIdentity(openSSHPrivateKey: try String(contentsOf: path, encoding: .utf8))
        #expect(try store.identity()?.fingerprint == key.fingerprint)
    }

    @Test func passwords() throws {
        let store = SSHKeyStore(secrets: InMemorySecretStore())
        #expect(try store.password(host: "mac.local", user: "me") == nil)
        try store.savePassword("pa ss", host: "Mac.local", user: "me")
        #expect(try store.password(host: "mac.local", user: "me") == "pa ss")
        #expect(try store.password(host: "mac.local", port: 2222, user: "me") == nil)
        #expect(try store.password(host: "mac.local", user: "you") == nil)
        try store.deletePassword(host: "mac.local", user: "me")
        #expect(try store.password(host: "mac.local", user: "me") == nil)
    }
}
