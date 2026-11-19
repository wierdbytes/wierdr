import Foundation
import HerdrCore

/// How a `WorkspaceEngine` talks to herdr-core.
public struct EngineOptions: Sendable, Hashable {
    /// The shared layout document (`herdr-app`, the desktop's).
    public var documentName: String
    /// Label namespace: `<prefix>.space`, `.tab`, `.seen`, `.pinned`. Tests use
    /// their own so a running desktop app never adopts their terminals.
    public var labelPrefix: String
    /// Colors and cell size passed to `terminal.run` (settable later on the engine).
    public var display: Display?
    /// `false`: never write anything (documents, labels, terminals): a read-only mirror.
    public var allowWrites: Bool
    /// How often `machine.list` is polled (seconds).
    public var machinePollInterval: TimeInterval
    /// How often git facts and `shared.json` colors are refreshed (seconds).
    public var refreshInterval: TimeInterval
    /// Subscription limits pi-wierdr publishes (`limits`), read from every machine; nil: not read.
    public var limitsDocument: String?

    public init(documentName: String = "herdr-app", labelPrefix: String = "herdr", display: Display? = nil,
                allowWrites: Bool = true, machinePollInterval: TimeInterval = 5, refreshInterval: TimeInterval = 60,
                limitsDocument: String? = Limits.documentName) {
        self.documentName = documentName
        self.labelPrefix = labelPrefix
        self.display = display
        self.allowWrites = allowWrites
        self.machinePollInterval = machinePollInterval
        self.refreshInterval = refreshInterval
        self.limitsDocument = limitsDocument
    }
}
