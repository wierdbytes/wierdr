// herdr-core client. See docs/hc-protocol-client.md.

/// Protocol constants.
public enum HerdrCoreInfo {
    /// The protocol generation this client speaks (sent in `hello`).
    public static let protocolGeneration: UInt32 = 1
}
