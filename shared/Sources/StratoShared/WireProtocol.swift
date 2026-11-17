import Foundation

/// Binary Protobuf workload transport plus explicit legacy JSON codecs for
/// persisted records, public HTTP payloads and guest-control messages.
public enum WireProtocol {
    /// The compatibility JSON encoder. Dates are pinned explicitly to
    /// Foundation's `deferredToDate` numeric form.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    /// The compatibility JSON decoder. It accepts the emitted numeric
    /// date form and ISO-8601 strings.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let string = try? container.decode(String.self) {
                guard let date = try? iso8601Style.parse(string) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Expected an ISO-8601 date string, got \"\(string)\""
                    )
                }
                return date
            }

            // `deferredToDate` encoding: seconds since the reference date
            // (2001-01-01) as a JSON number.
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }

    /// Matches `JSONEncoder.DateEncodingStrategy.iso8601` (internet date-time,
    /// no fractional seconds). Value-typed and `Sendable`, so it can back the
    /// decoder's tolerant string branch without a shared mutable formatter.
    private static let iso8601Style = Date.ISO8601FormatStyle()
}
