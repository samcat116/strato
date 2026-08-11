import Foundation

/// The exact control-plane to agent wire contract and its canonical JSON coders.
///
/// Registration is the single version handshake. Both peers require
/// `protocolVersion == currentVersion` before any state is exchanged; envelopes
/// carry only message routing and payload data. Strato therefore deploys matching
/// control-plane and agent builds as one coordinated change.
///
/// All wire values use `makeEncoder()` and `makeDecoder()` so both processes share
/// one pinned date representation. The current encoder emits Foundation numeric
/// dates; the decoder also accepts ISO-8601 strings.
public enum WireProtocol {
    /// The only wire/schema version this build accepts. Version 48 adds the
    /// VM guest-bootstrap metadata source (STR-64) to v47's dependency health
    /// contract (STR-237), v46's authoritative native-OVN load-balancer state
    /// and observations (STR-28), and v45's guest-agent wire contract
    /// (STR-76/78/60).
    public static let currentVersion = 48

    /// The JSON encoder for all wire messages. Dates are pinned explicitly to
    /// Foundation's `deferredToDate` numeric form.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    /// The JSON decoder for all wire messages. It accepts the emitted numeric
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
