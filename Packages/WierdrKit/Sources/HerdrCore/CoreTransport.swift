import Foundation

/// A bidirectional byte pipe to a herdr-core API endpoint (`hc connect`'s
/// stdin/stdout, wherever it runs). HerdrCore speaks JSON-RPC and the framed
/// protocol over it; it does not care how the bytes travel.
///
/// Implementations:
/// - `ProcessTransport` (macOS only): spawns `hc connect` locally. Tests, CLI.
/// - `SSHTransport` (HerdrSSH): an SSH exec channel running `hc connect`.
public protocol CoreTransport: AnyObject, Sendable {
    /// Bytes from the core, in order. Finishes normally when the pipe closes,
    /// or with an error when the transport fails. Must be iterated by exactly
    /// one consumer (the `CoreConnection`).
    var inbound: AsyncThrowingStream<Data, Error> { get }

    /// Write bytes to the core, in call order. Throws once the pipe is closed.
    func write(_ data: Data) async throws

    /// Close the pipe. Idempotent. `inbound` finishes afterwards.
    func close() async
}
