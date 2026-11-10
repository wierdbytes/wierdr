extension KeyedDecodingContainer {
    /// The value when present and well-typed; nil when missing, null or of
    /// another type. Records from other core versions must never fail to decode
    /// because one non-essential field changed.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
