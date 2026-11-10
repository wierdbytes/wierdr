# SSH in Wierdr

Wierdr reaches herdr-core on your Mac (or any machine with `hc`) over SSH: it
logs in, runs `herdr-core connect` in an exec channel, and speaks herdr-core's
API over that channel's stdin/stdout. Code: `Packages/WierdrKit/Sources/HerdrSSH`.

## Libraries

All Apple:

| What | Library |
|---|---|
| TCP | Network.framework, through `NIOTransportServices` (`NIOTSConnectionBootstrap`); works on iOS and macOS |
| SSH protocol | SwiftNIO SSH (`NIOSSH`) |
| Keys | CryptoKit (`Curve25519.Signing`, `P256.Signing`, via swift-crypto) |
| Secrets | Security framework Keychain (generic passwords) |

SwiftNIO SSH negotiates `curve25519-sha256` / `ecdh-sha2-nistp*` key exchange,
`aes128-gcm@openssh.com` / `aes256-gcm@openssh.com` ciphers, and
`ssh-ed25519` / `ecdsa-sha2-nistp*` host keys. Every current OpenSSH (macOS
included) supports these.

## API

```swift
import HerdrSSH

let keys = SSHKeyStore()                              // Keychain, service pw.xff.wierdr.ssh
let identity = try keys.loadOrCreateIdentity()        // Ed25519, generated on device
let publicLine = identity.openSSHPublicKey(comment: SSHPrivateKey.defaultComment)
// "ssh-ed25519 AAAAC3Nz... wierdr@ipad"  -> show it, let the user copy it

let knownHosts = KnownHostsStore(directory: applicationSupportURL)
let validator = TOFUHostKeyValidator(store: knownHosts) { key, prompt in
    // Off the main actor. Show an alert with key.fingerprint; for
    // .changed(old:) warn loudly. Return true to trust (and remember) it.
    await MainActor.run { ... }
}

let transport = try await SSHTransport.connect(
    SSHConfig(host: "mac.local", username: "me", auth: .key(identity)),
    hostKeyValidator: validator)
// transport is a HerdrCore.CoreTransport: hand it to CoreConnection.
```

- `SSHConfig(host:port:username:auth:remoteCommand:connectTimeout:keepaliveIdle:)`;
  port 22, the default remote command (below), 10 s timeout, 15 s keepalive idle.
- `SSHConfig.Auth`: `.password(String)`, `.ed25519(key)`, `.ecdsaP256(key)`,
  `.key(SSHPrivateKey)`.
- `SSHTransport.inbound` yields the remote command's stdout. It finishes normally
  after `close()` or when the command exits 0; otherwise it throws an `SSHError`
  (`remoteExited(status:stderr:)` with the last 8 KB of stderr,
  `remoteSignaled`, `disconnected`). `write` awaits the SSH channel's write
  (channel-window backpressure). `close()` is idempotent and drops the
  connection. When the command exits, the connection is closed too.
- `SSHError`: `connectFailed`, `timedOut`, `hostKeyRejected(fingerprint:)`,
  `authenticationFailed(methodsOffered:)`, `execRejected(stderr:)`,
  `remoteExited(status:stderr:)`, `remoteSignaled`, `disconnected`, `closed`.
  All have a `localizedDescription` fit for an alert;
  `error.isHerdrCoreMissing` says "hc is not installed there".
- `inbound` buffers without bound (an `AsyncThrowingStream`); herdr-core's own
  attach streams have credit-based flow control on top.

## Authentication

One method per connection, the one configured:

- **Ed25519 key** (recommended). `SSHKeyStore.generateIdentity()` creates one with
  CryptoKit; `loadOrCreateIdentity()` returns the stored one or makes one.
  The private key is a Keychain generic password (service
  `pw.xff.wierdr.ssh`, account `identity.ed25519`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: never leaves the device,
  not in backups). `openSSHPublicKey(comment:)` is the `authorized_keys` line;
  `fingerprint` is `SHA256:...` as `ssh-keygen -lf` prints it.
- **Imported key**. `SSHKeyStore.importIdentity(openSSHPrivateKey:)` takes the
  text of an OpenSSH private key file (`-----BEGIN OPENSSH PRIVATE KEY-----`):
  unencrypted ed25519 or ecdsa-sha2-nistp256 (also PEM P-256,
  `BEGIN EC PRIVATE KEY`). Passphrase-protected keys are refused (import a copy
  without a passphrase: `cp id_ed25519 /tmp/k && ssh-keygen -p -N "" -f /tmp/k`).
  Stored like a generated key (account `identity.ecdsa-p256` for P-256). One
  identity at a time.
- **Password**. `SSHKeyStore.savePassword(_:host:port:user:)` /
  `password(host:port:user:)` / `deletePassword(...)` keep it in the Keychain
  (account `password.<user>@<host>:<port>`).

If the server refuses, `connect` throws `.authenticationFailed(methodsOffered:)`
with what the server would accept (`publickey`, `password`), so the UI can say
"this Mac only accepts keys".

Keychain access goes through the `SecretStore` protocol: `KeychainSecretStore`
in the app, `InMemorySecretStore` in tests (unit tests never touch the login
keychain). On macOS, `KeychainSecretStore` uses the data-protection keychain,
which needs a signed app with a keychain access group; pass
`useDataProtectionKeychain: false` for an unsigned command-line tool.

## Host keys: trust on first use

Each handshake hands the server's key to a `HostKeyValidator`
(`HostKeyInfo`: host, port, key type, base64 key, `openSSHPublicKey`,
`fingerprint`). `TOFUHostKeyValidator` checks a `KnownHostsStore`:

- `.trusted` (same key as before for this host:port) -> accepted silently;
- `.unknown` -> `confirm(key, .unknown)`; yes = remembered and accepted;
- `.changed(old:)` -> `confirm(key, .changed(old:))`; this is what a
  man-in-the-middle looks like (or a reinstalled Mac): warn loudly.

`KnownHostsStore` is a JSON file (`<dir>/known_hosts.json`), one key per
`host:port` (host case-insensitive): `status(of:)`, `trust(_:)`,
`remove(host:port:)`, `all`. The time the validator takes (the user reading an
alert) is not counted against the connect timeout. `PinnedHostKeyValidator` and
`ClosureHostKeyValidator` are there for tests and special cases.

## The remote command

A non-interactive SSH session on macOS has a bare PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`, plus whatever `~/.zshenv` adds), and the hc
installer puts `hc`/`herdr-core` in `~/.local/bin`. So, like herdr-core's own
`machine` dialing (`crates/herdr-core/src/machines.rs`, `pipe()`), Wierdr runs
`SSHConfig.defaultRemoteCommand`:

```sh
/bin/sh -c 'for p in "$(command -v herdr-core)" "$HOME/.local/bin/herdr-core" "/opt/homebrew/bin/herdr-core" "/usr/local/bin/herdr-core" "$HOME/.cargo/bin/herdr-core" "$HOME/.local/share/mise/shims/herdr-core" "$HOME/.nix-profile/bin/herdr-core" "/run/current-system/sw/bin/herdr-core" "$(command -v hc)" "$HOME/.local/bin/hc"; do [ -n "$p" ] && [ -x "$p" ] && exec "$p" connect; done; echo "herdr-core is not installed here (looked on PATH and in ~/.local/bin, Homebrew, ~/.cargo/bin, mise, nix)" >&2; exit 127'
```

It is a single `/bin/sh -c '...'` with no single quotes or backslashes inside,
so the login shell (zsh, bash, fish, ...) passes it through unchanged. When
there is no herdr-core it exits 127 with herdr-core's own marker line
("herdr-core is not installed here"); `inbound` then throws
`.remoteExited(status: 127, stderr: ...)` and `isHerdrCoreMissing` is true.
`SSHConfig.remoteCommand(session:)` adds `HC_SESSION=<name>` for a named core
session.

## Connection behaviour

- TCP via Network.framework with `waitForActivity` off (errors such as
  "connection refused" or DNS failures come back at once instead of waiting),
  `TCP_NODELAY`, and TCP keepalive (15 s idle, then a probe every 5 s, 4 misses
  = dead: ~35 s to notice a vanished peer).
- `connectTimeout` (10 s) bounds TCP connect, then (separately) SSH handshake +
  auth + exec, minus the host-key prompt.
- No SSH-level keepalive (`keepalive@openssh.com`): SwiftNIO SSH has no public
  API to send it. TCP keepalive covers dead peers; iOS suspends sockets of
  backgrounded apps anyway, so the app must reconnect on return to foreground.

## Limitations

- No RSA (SwiftNIO SSH does not support it), no DSA, no security keys (`sk-*`),
  no certificates. Use ed25519.
- No keyboard-interactive auth (servers that only offer it, e.g. some 2FA
  setups, fail with `authenticationFailed([])`). Password auth only where the
  server offers the `password` method (macOS does by default).
- No ssh-agent, no `~/.ssh/config`, no ProxyJump/ProxyCommand, no port
  forwarding, no compression.
- One exec channel per connection.

## Setting up your Mac

1. System Settings › General › Sharing › **Remote Login**: on. Allow your user
   (default: all users).
2. Install herdr-core (`hc`) if it is not there; the default install location
   `~/.local/bin` is found automatically.
3. Either:
   - **Key** (recommended): in Wierdr, copy the public key (`ssh-ed25519 AAAA...
     wierdr@ipad`) and append it to `~/.ssh/authorized_keys` on the Mac:
     ```sh
     mkdir -p ~/.ssh && chmod 700 ~/.ssh
     echo 'ssh-ed25519 AAAA... wierdr@ipad' >> ~/.ssh/authorized_keys
     chmod 600 ~/.ssh/authorized_keys
     ```
   - **Password**: use your Mac login password.
4. Connect to `<your-mac>.local` (or its IP / Tailscale name), user = your
   short user name (`whoami`). Check the fingerprint the app shows on first
   connection against the Mac's:
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.

## Test sshd

`scripts/test-sshd.sh` runs a throwaway OpenSSH server as you (no root, nothing
in `~/.ssh` or `/etc/ssh` touched), on `127.0.0.1:2222`, out of
`/tmp/wierdr-sshd/` (own host key, a test client key, its own `authorized_keys`):

```sh
scripts/test-sshd.sh start     # idempotent
scripts/test-sshd.sh env       # user, client key path, host key fingerprint
scripts/test-sshd.sh stop
ssh -p 2222 -i /tmp/wierdr-sshd/client_ed25519 -o UserKnownHostsFile=/dev/null 127.0.0.1 'echo ok'
```

It only accepts your user, by key (a non-root sshd cannot check passwords).
From the iOS simulator: host `127.0.0.1`, port 2222, your user name, and either
import `/tmp/wierdr-sshd/client_ed25519` or append the app's public key to
`/tmp/wierdr-sshd/authorized_keys`.

Tests:

```sh
cd Packages/WierdrKit
swift test --filter HerdrSSHTests                      # unit tests (keys, known hosts, command)
WIERDR_SSH_LIVE=1 swift test --filter HerdrSSHTests    # + live tests (starts the test sshd)
```

The live tests run the real `hc connect` of this Mac through the test sshd
(JSON-RPC `hello`), and check wrong keys, refused passwords, host-key
rejection and fingerprints (against `ssh-keygen -lf`), exit status/stderr,
missing herdr-core, timeouts, refused connections and a 4 MB echo.
