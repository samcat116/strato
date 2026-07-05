import Foundation

/// Versioning and the canonical JSON coders for the control-plane ↔ agent wire
/// protocol.
///
/// Both codebases build against this package, but they deploy independently
/// (agents run on hypervisor nodes and reconnect on their own schedule), so the
/// two sides can run different builds at the same time. Two things make that
/// safe:
///
/// * A single pinned coder pair. Every message is encoded and decoded through
///   `makeEncoder()`/`makeDecoder()` so both sides agree on the `Date`
///   representation. Previously each call site constructed a bare
///   `JSONEncoder()`/`JSONDecoder()`, which left dates on Foundation's
///   `deferredToDate` default — any future divergence in date strategy across
///   the two codebases would silently break decoding of every message.
/// * A version stamped on every `MessageEnvelope` and negotiated at
///   registration (see `AgentRegisterMessage.protocolVersion`), so a peer can
///   detect and log skew instead of failing opaquely.
public enum WireProtocol {
    /// The wire/schema version this build speaks. Bump it whenever the on-wire
    /// representation changes in a way peers must be aware of (date strategy,
    /// envelope layout, field semantics). Carried on every `MessageEnvelope`
    /// and exchanged during agent registration.
    public static let currentVersion = 1

    /// The JSON encoder for all wire messages. Dates are pinned to ISO-8601
    /// strings so the representation is explicit and self-describing rather than
    /// riding on Foundation's `deferredToDate` default.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The JSON decoder for all wire messages. Dates decode tolerantly: an
    /// ISO-8601 string (the pinned encoding) is preferred, but a bare numeric
    /// value is still accepted as legacy `deferredToDate` seconds. That lets a
    /// build on the new date strategy keep decoding messages from a peer that
    /// predates the switch, so the two sides can be rolled out in any order.
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

            // Legacy `deferredToDate` encoding: seconds since the reference date
            // (2001-01-01) as a JSON number.
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }

    /// Matches `JSONEncoder.DateEncodingStrategy.iso8601` (internet date-time,
    /// no fractional seconds). Value-typed and `Sendable`, so it can back the
    /// decoder's tolerant string fallback without a shared mutable formatter.
    private static let iso8601Style = Date.ISO8601FormatStyle()
}
