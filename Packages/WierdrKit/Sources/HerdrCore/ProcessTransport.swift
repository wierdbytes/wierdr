#if os(macOS)
import Foundation
import Synchronization

/// A `CoreTransport` that spawns `hc connect` locally and talks over its
/// stdin/stdout. macOS only (tests and `wierdr-cli`).
public final class ProcessTransport: CoreTransport, @unchecked Sendable {
    public let inbound: AsyncThrowingStream<Data, Error>

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let writeQueue = DispatchQueue(label: "wierdr.ProcessTransport.write")
    private let state = Shared()

    private final class Shared: Sendable {
        let mutex = Mutex(State())
        func withLock<R>(_ body: (inout State) -> R) -> R { mutex.withLock { body(&$0) } }
    }

    private struct State {
        var closed = false
        /// The last stderr bytes, for error messages.
        var stderrTail = Data()
    }

    /// Where `hc` is: `$PATH`, then `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
    public static func locateHC(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("hc") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Launches `executable arguments` (default: `hc connect`).
    public init(executable: URL? = nil, arguments: [String] = ["connect"],
                environment: [String: String]? = nil) throws {
        guard let url = executable ?? Self.locateHC() else {
            throw ConnectionError.disconnected("hc not found in PATH or ~/.local/bin")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let environment { process.environment = environment }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        self.process = process
        stdin = input.fileHandleForWriting
        stdout = output.fileHandleForReading
        // A dead `hc` must surface as a write error, not kill us with SIGPIPE.
        _ = fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1)
        (inbound, continuation) = AsyncThrowingStream.makeStream(of: Data.self)

        let continuation = continuation
        let state = state
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            state.withLock { s in
                s.stderrTail.append(chunk)
                if s.stderrTail.count > 4096 { s.stderrTail = Data(s.stderrTail.suffix(4096)) }
            }
        }
        stdout.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                let tail = state.withLock { String(decoding: $0.stderrTail, as: UTF8.self) }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ConnectionError.disconnected("hc connect: \(tail)"))
                }
            } else {
                continuation.yield(chunk)
            }
        }
        try process.run()
    }

    public func write(_ data: Data) async throws {
        if state.withLock({ $0.closed }) { throw ConnectionError.closed }
        let stdin = stdin
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try stdin.write(contentsOf: data)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        let first = state.withLock { s in
            defer { s.closed = true }
            return !s.closed
        }
        guard first else { return }
        let (stdin, process, writeQueue) = (stdin, process, writeQueue)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            // After queued writes: closing stdin ends `hc connect`.
            writeQueue.async {
                try? stdin.close()
                c.resume()
            }
        }
        if process.isRunning {
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning { process.terminate() }
        }
    }

    deinit {
        stdout.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
#endif
