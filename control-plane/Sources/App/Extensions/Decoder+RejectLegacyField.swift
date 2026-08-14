private struct LegacyFieldCodingKey: CodingKey {
    let stringValue: String

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    let intValue: Int? = nil

    init?(intValue: Int) {
        nil
    }
}

extension Decoder {
    /// Fails decoding with `error` when the input still contains a removed field.
    func rejectLegacyField(
        _ key: String,
        throwing error: @autoclosure () -> any Error
    ) throws {
        let key = LegacyFieldCodingKey(stringValue: key)
        if try container(keyedBy: LegacyFieldCodingKey.self).contains(key) {
            throw error()
        }
    }
}
