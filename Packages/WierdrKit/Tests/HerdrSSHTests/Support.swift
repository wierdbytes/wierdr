import Foundation

/// Runs a program and returns (status, stdout, stderr). macOS tests only.
@discardableResult
func run(_ path: String, _ args: [String], environment: [String: String]? = nil) throws -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let environment { p.environment = environment }
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

/// A fresh temporary directory.
func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wierdr-ssh-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `ssh-keygen -q -t <type> -N <pass> -f <dir>/<name> [extra]`; returns the private key path.
func sshKeygen(_ dir: URL, name: String, type: [String], passphrase: String = "", extra: [String] = []) throws -> URL {
    let path = dir.appendingPathComponent(name)
    let (status, _, err) = try run(
        "/usr/bin/ssh-keygen", ["-q"] + type + ["-N", passphrase, "-C", "test@wierdr", "-f", path.path] + extra)
    guard status == 0 else { throw TestError("ssh-keygen failed: \(err)") }
    return path
}

/// The `SHA256:...` field of `ssh-keygen -lf <file>`.
func keygenFingerprint(_ file: URL) throws -> String {
    let (status, out, err) = try run("/usr/bin/ssh-keygen", ["-lf", file.path])
    guard status == 0 else { throw TestError("ssh-keygen -lf failed: \(err)") }
    return String(out.split(separator: " ")[1])
}

struct TestError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// The repo root (for scripts/test-sshd.sh).
let repoRoot: URL = {
    // .../Packages/WierdrKit/Tests/HerdrSSHTests/Support.swift -> the first
    // ancestor with scripts/test-sshd.sh.
    var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    while url.path != "/" {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/test-sshd.sh").path) {
            return url
        }
    }
    return url
}()
