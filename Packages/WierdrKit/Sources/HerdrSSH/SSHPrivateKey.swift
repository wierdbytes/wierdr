import Crypto
import Foundation
import NIOSSH

/// A private key SwiftNIO SSH can authenticate with.
public enum SSHPrivateKey: Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case ecdsaP256(P256.Signing.PrivateKey)

    /// A fresh Ed25519 key (CryptoKit).
    public static func generateEd25519() -> SSHPrivateKey {
        .ed25519(Curve25519.Signing.PrivateKey())
    }

    /// The SSH key type name: `ssh-ed25519` or `ecdsa-sha2-nistp256`.
    public var keyType: String {
        switch self {
        case .ed25519: return "ssh-ed25519"
        case .ecdsaP256: return "ecdsa-sha2-nistp256"
        }
    }

    var nioKey: NIOSSHPrivateKey {
        switch self {
        case .ed25519(let k): return NIOSSHPrivateKey(ed25519Key: k)
        case .ecdsaP256(let k): return NIOSSHPrivateKey(p256Key: k)
        }
    }

    /// The public half in SSH wire format (what `authorized_keys` base64-encodes).
    public var publicKeyBlob: Data {
        var w = SSHWireWriter()
        w.string(keyType)
        switch self {
        case .ed25519(let k):
            w.string(k.publicKey.rawRepresentation)
        case .ecdsaP256(let k):
            w.string("nistp256")
            w.string(k.publicKey.x963Representation)
        }
        return w.data
    }

    /// `ssh-ed25519 AAAA... comment`: one line for `~/.ssh/authorized_keys`.
    public func openSSHPublicKey(comment: String? = nil) -> String {
        let line = "\(keyType) \(publicKeyBlob.base64EncodedString())"
        guard let comment, !comment.isEmpty else { return line }
        return "\(line) \(comment)"
    }

    /// `SHA256:...`, as `ssh-keygen -lf` prints it.
    public var fingerprint: String {
        SSHFingerprint.sha256(blob: publicKeyBlob)
    }

    /// The default comment for keys made on this device: `wierdr@<device>`.
    public static var defaultComment: String {
        "wierdr@\(SSHDevice.name)"
    }
}

/// A name for this device in key comments. On iOS, `UIDevice.name` is
/// main-actor bound (and generic since iOS 16), so this is just the model
/// family; pass your own comment if you have a better name.
enum SSHDevice {
    static var name: String {
        #if os(macOS)
            let raw = Host.current().localizedName ?? "mac"
            let name = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            return String(name)
        #elseif os(iOS)
            return "ipad"
        #else
            return "device"
        #endif
    }
}

/// OpenSSH key fingerprints.
public enum SSHFingerprint {
    /// `SHA256:<base64 without padding>` of an SSH wire-format public key blob.
    public static func sha256(blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        var b64 = Data(digest).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:\(b64)"
    }

    /// Fingerprint of an OpenSSH public key line (`type base64 [comment]`).
    public static func sha256(openSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return sha256(blob: blob)
    }
}

// MARK: - Import

extension SSHPrivateKey {
    /// Reads a private key file's text.
    ///
    /// Supported: unencrypted `-----BEGIN OPENSSH PRIVATE KEY-----` with an
    /// ed25519 or ecdsa-sha2-nistp256 key, and PEM P-256 keys
    /// (`BEGIN EC PRIVATE KEY` / `BEGIN PRIVATE KEY`). Passphrase-protected
    /// keys throw `SSHKeyError.encrypted`; RSA and other types throw
    /// `SSHKeyError.unsupportedKeyType`.
    public init(importing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            self = try Self.parseOpenSSH(trimmed)
            return
        }
        if trimmed.contains("-----BEGIN RSA PRIVATE KEY-----") {
            throw SSHKeyError.unsupportedKeyType("ssh-rsa")
        }
        if trimmed.contains("-----BEGIN DSA PRIVATE KEY-----") {
            throw SSHKeyError.unsupportedKeyType("ssh-dss")
        }
        if trimmed.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") || trimmed.contains("Proc-Type: 4,ENCRYPTED") {
            throw SSHKeyError.encrypted
        }
        if trimmed.contains("-----BEGIN EC PRIVATE KEY-----") || trimmed.contains("-----BEGIN PRIVATE KEY-----") {
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
                self = .ecdsaP256(key)
                return
            }
            if let key = Self.parseSEC1P256(trimmed) {
                self = .ecdsaP256(key)
                return
            }
            throw SSHKeyError.unsupportedKeyType("PEM key that is not P-256")
        }
        if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") {
            throw SSHKeyError.invalidFormat("this is a public key; import the private key file (without .pub)")
        }
        throw SSHKeyError.invalidFormat("no -----BEGIN OPENSSH PRIVATE KEY----- block")
    }

    /// `BEGIN EC PRIVATE KEY` with explicit curve parameters (what
    /// `ssh-keygen -m PEM` writes), which CryptoKit's PEM reader refuses:
    /// takes the scalar and accepts it only if the embedded public key is the
    /// P-256 point for it.
    private static func parseSEC1P256(_ text: String) -> P256.Signing.PrivateKey? {
        guard
            let begin = text.range(of: "-----BEGIN EC PRIVATE KEY-----"),
            let end = text.range(of: "-----END EC PRIVATE KEY-----", range: begin.upperBound..<text.endIndex),
            let der = Data(base64Encoded: String(text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }))
        else { return nil }
        var outer = DERReader(der)
        guard let (tag, body) = outer.next(), tag == 0x30 else { return nil }
        var seq = DERReader(body)
        guard let (vTag, version) = seq.next(), vTag == 0x02, version == Data([1]),
            let (oTag, scalar) = seq.next(), oTag == 0x04, scalar.count == 32,
            let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar)
        else { return nil }
        while let (t, v) = seq.next() {
            guard t == 0xA1 else { continue }  // [1] publicKey
            var inner = DERReader(v)
            guard let (bTag, bits) = inner.next(), bTag == 0x03, bits.first == 0 else { return nil }
            return Data(bits.dropFirst()) == key.publicKey.x963Representation ? key : nil
        }
        return nil
    }

    private static func parseOpenSSH(_ text: String) throws -> SSHPrivateKey {
        guard
            let begin = text.range(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
            let end = text.range(of: "-----END OPENSSH PRIVATE KEY-----", range: begin.upperBound..<text.endIndex)
        else { throw SSHKeyError.invalidFormat("unterminated key block") }
        let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else {
            throw SSHKeyError.invalidFormat("bad base64")
        }
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.starts(with: magic) else { throw SSHKeyError.invalidFormat("missing openssh-key-v1 header") }
        var r = SSHWireReader(data.dropFirst(magic.count))
        let cipher = try r.stringUTF8()
        let kdf = try r.stringUTF8()
        _ = try r.string()  // kdf options
        if cipher != "none" || kdf != "none" { throw SSHKeyError.encrypted }
        let count = try r.uint32()
        guard count == 1 else { throw SSHKeyError.invalidFormat("\(count) keys in one file") }
        _ = try r.string()  // public key
        var p = SSHWireReader(try r.string())
        let check1 = try p.uint32()
        let check2 = try p.uint32()
        guard check1 == check2 else { throw SSHKeyError.invalidFormat("check bytes differ (corrupt or encrypted)") }
        let type = try p.stringUTF8()
        switch type {
        case "ssh-ed25519":
            let pub = try p.string()
            let priv = try p.string()  // seed (32) + public (32)
            guard pub.count == 32, priv.count == 64 else { throw SSHKeyError.invalidFormat("bad ed25519 key sizes") }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: priv.prefix(32))
            guard key.publicKey.rawRepresentation == pub else {
                throw SSHKeyError.invalidFormat("ed25519 public key does not match the private key")
            }
            return .ed25519(key)
        case "ecdsa-sha2-nistp256":
            let curve = try p.stringUTF8()
            guard curve == "nistp256" else { throw SSHKeyError.invalidFormat("curve \(curve) for nistp256 key") }
            let q = try p.string()
            var d = Data(try p.string())  // mpint: big-endian, maybe a leading 0
            while d.count > 32, d.first == 0 { d.removeFirst() }
            guard d.count <= 32 else { throw SSHKeyError.invalidFormat("bad P-256 scalar") }
            d = Data(repeating: 0, count: 32 - d.count) + d
            let key = try P256.Signing.PrivateKey(rawRepresentation: d)
            guard key.publicKey.x963Representation == q else {
                throw SSHKeyError.invalidFormat("P-256 public key does not match the private key")
            }
            return .ecdsaP256(key)
        case let other:
            throw SSHKeyError.unsupportedKeyType(other)
        }
    }
}

// MARK: - SSH wire format

/// Just enough DER (definite lengths) to walk a SEC1 key.
struct DERReader {
    private var data: Data

    init(_ data: Data) {
        self.data = Data(data)
    }

    mutating func next() -> (UInt8, Data)? {
        guard data.count >= 2 else { return nil }
        let tag = data[data.startIndex]
        var length = Int(data[data.startIndex + 1])
        var header = 2
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n >= 1, n <= 4, data.count >= 2 + n else { return nil }
            length = data.dropFirst(2).prefix(n).reduce(0) { $0 << 8 | Int($1) }
            header += n
        }
        guard data.count >= header + length else { return nil }
        let value = Data(data.dropFirst(header).prefix(length))
        data = Data(data.dropFirst(header + length))
        return (tag, value)
    }
}

struct SSHWireWriter {
    private(set) var data = Data()

    mutating func uint32(_ v: UInt32) {
        withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ bytes: Data) {
        uint32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func string(_ s: String) {
        string(Data(s.utf8))
    }
}

struct SSHWireReader {
    private var data: Data

    init(_ data: Data) {
        self.data = Data(data)  // re-base indices to 0
    }

    mutating func uint32() throws -> UInt32 {
        guard data.count >= 4 else { throw SSHKeyError.invalidFormat("truncated") }
        let v = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        data = data.dropFirst(4)
        return v
    }

    mutating func string() throws -> Data {
        let n = Int(try uint32())
        guard data.count >= n else { throw SSHKeyError.invalidFormat("truncated") }
        let s = Data(data.prefix(n))
        data = data.dropFirst(n)
        return s
    }

    mutating func stringUTF8() throws -> String {
        guard let s = String(data: try string(), encoding: .utf8) else {
            throw SSHKeyError.invalidFormat("bad string")
        }
        return s
    }
}
