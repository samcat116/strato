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
///   `makeEncoder()`/`makeDecoder()` so both sides agree — from one definition —
///   on the `Date` representation. Previously each call site constructed a bare
///   `JSONEncoder()`/`JSONDecoder()`, which left dates on Foundation's
///   `deferredToDate` default; any future divergence in date strategy across the
///   two codebases would silently break decoding of every message.
/// * A version stamped on every `MessageEnvelope` and negotiated at
///   registration (see `AgentRegisterMessage.protocolVersion`), so a peer can
///   detect and log skew instead of failing opaquely.
///
/// ## Date encoding: a two-phase migration
///
/// The eventual goal is self-describing ISO-8601 timestamps, but flipping the
/// *encoder* is a breaking change: a binary that predates this work decodes
/// payloads with a bare `JSONDecoder` (Foundation's `deferredToDate`), which
/// expects a numeric value and cannot read an ISO-8601 string. During any
/// rollout where one side is upgraded before the other, an upgraded sender
/// emitting ISO strings would break every timestamped message an old peer reads.
///
/// So this phase (`currentVersion == 1`) only widens what we *accept*:
///
/// * `makeEncoder()` still emits the legacy numeric `deferredToDate` form, byte
///   compatible with what old peers already read.
/// * `makeDecoder()` accepts *both* the numeric form and ISO-8601 strings.
///
/// Once every deployed peer is known to run a build that reads both forms (which
/// can be confirmed via the negotiated `protocolVersion`), a later version can
/// flip `makeEncoder()` to ISO-8601 with no compatibility window.
public enum WireProtocol {
    /// The wire/schema version this build speaks. Bump it whenever the on-wire
    /// representation changes in a way peers must be aware of (date strategy,
    /// envelope layout, field semantics). Carried on every `MessageEnvelope`
    /// and exchanged during agent registration.
    ///
    /// Version 1: decoder accepts both numeric and ISO-8601 dates; encoder still
    /// emits the legacy numeric form. See the type-level note on the migration.
    ///
    /// Version 2: reconciliation state sync. The peer understands
    /// `DesiredStateMessage`/`ObservedStateReport` and, for agents, runs a
    /// reconcile loop instead of the imperative VM lifecycle messages. The
    /// control plane keys dual-mode dispatch on this: agents registering with
    /// an older version keep receiving imperative messages. The date encoder is
    /// unchanged (still the legacy numeric form).
    ///
    /// Version 3: first-class network reconciliation. `DesiredStateMessage`
    /// carries a `networks: [DesiredNetworkState]` list so agents realize
    /// logical switches, per-project routers, and SNAT uplinks as level-triggered
    /// desired state. The change is additive and backward-tolerant: the field
    /// defaults to `[]` when absent, an older (v2) agent simply ignores it (and
    /// keeps realizing switches implicitly from `vms`), so state sync still works
    /// across the skew — hence `stateSyncMinimumVersion` stays at 2.
    public static let currentVersion = 3

    /// The lowest protocol version that speaks reconciliation state sync
    /// (see `currentVersion` version 2 notes).
    public static let stateSyncMinimumVersion = 2

    /// Whether a peer registering with `version` should be driven with
    /// desired-state syncs rather than imperative VM lifecycle messages.
    public static func supportsStateSync(_ version: Int) -> Bool {
        version >= stateSyncMinimumVersion
    }

    /// The JSON encoder for all wire messages. Dates are pinned — explicitly and
    /// from this single definition — to Foundation's `deferredToDate` numeric
    /// form, which is byte compatible with what pre-existing peers already
    /// decode. This is deliberately *not* ISO-8601 yet: see the type-level note
    /// on the two-phase date migration.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    /// The JSON decoder for all wire messages. Dates decode tolerantly: the
    /// current numeric `deferredToDate` form is accepted, and so is an ISO-8601
    /// string. Accepting ISO now — before any peer emits it — is what lets a
    /// future encoder flip to ISO-8601 be rolled out without a compatibility
    /// window.
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
