// HerdrSSH: herdr-core over SSH (see docs/ssh.md).
//
//   SSHTransport        CoreTransport over an SSH exec channel running `hc connect`
//                       (Network.framework TCP via NIOTransportServices + SwiftNIO SSH).
//   SSHConfig           host, port, user, auth, remote command, timeouts.
//   SSHPrivateKey       Ed25519 / P-256 keys: generation, OpenSSH public key line,
//                       fingerprint, OpenSSH private key import.
//   SSHKeyStore         the device identity and passwords in the Keychain (SecretStore).
//   KnownHostsStore     trust-on-first-use host keys (JSON file), TOFUHostKeyValidator.
import HerdrCore
