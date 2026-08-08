/// The last answer a hypervisor gave about the host, held so that a failed
/// query can serve it instead of an empty one (STR-196).
///
/// Everything here exists because, for host inventory, **the empty answer is
/// the dangerous one**. An empty VM list is not "no information", it is the
/// claim that this host manages nothing, and the control plane reads it as
/// every VM here being gone. Zero reservations are not "unknown", they are the
/// claim that this host is idle, and the scheduler places against it. A driver
/// that could not reach its daemon is in no position to make either claim.
///
/// Two decisions live here, and both are the sort that read identically to a
/// correct answer at the point they are served:
///
/// - **Never having answered is not the same as having answered zero.** This is
///   the distinction STR-190 lost in the field. A libvirt decoder that had never
///   once worked reported the same figure an idle host does — a synthesized
///   `(0, 0)` at the failure seam — so a node running VMs advertised its whole
///   machine as free while looking healthy for the entire time. `.neverAnswered`
///   is how a driver says it cannot say; a *recorded* zero is a real answer and
///   is served as one, because an empty host is a legitimate host.
/// - **Staleness is bounded, but never fatal.** A recent answer still beats the
///   caller's fallback, so a failed sweep serves the last one. What deserved a
///   bound is the *indefiniteness*: without one, "these are this second's
///   figures" and "these are from an hour ago" differ only by a log line nobody
///   reads. Past the threshold the answer is still served — stale beats empty,
///   always — and flagged, so the caller can say so at a level that gets noticed.
///
/// Lives in `StratoAgentCore` rather than beside its caller because its caller
/// is `LibvirtService`, in the executable target, which no test can import.
/// Same reasoning as `LibvirtDomain.reservation(from:)`: the sentence worth
/// asserting is a property of the seam, and it has to be assertable in a package
/// with no daemon in it.
///
/// Holds no cadence policy — the threshold is the caller's to choose, and the
/// instants are injectable so ageing is assertable without sleeping.
public struct LastKnownInventory<Value: Sendable>: Sendable {

    /// What to report after a live query failed.
    public enum Fallback: Sendable {
        /// Serve this answer, which is `age` old. `badlyStale` once that age is
        /// past the threshold — the value is still the best there is, but the
        /// caller should stop describing it as a hiccup.
        case lastKnown(Value, age: Duration, badlyStale: Bool)

        /// This driver has never had an answer. The caller must report *not
        /// knowing* — never an empty list or a zero, which are claims about the
        /// host that nothing here is entitled to make.
        case neverAnswered
    }

    /// How old a served answer may get before `badlyStale` is set.
    public let staleThreshold: Duration

    /// The last answer, with when it was given — the timestamp being the only
    /// thing that distinguishes a fresh reading from an indefinitely stale one
    /// at the point it is served.
    private var answer: (value: Value, at: ContinuousClock.Instant)?

    public init(staleThreshold: Duration) {
        self.staleThreshold = staleThreshold
    }

    /// Whether this driver has ever answered.
    public var hasAnswer: Bool { answer != nil }

    /// Record a live answer, replacing any earlier one and restarting its clock.
    public mutating func record(_ value: Value, at now: ContinuousClock.Instant = ContinuousClock.now) {
        answer = (value: value, at: now)
    }

    /// What to report now that a live query has failed.
    public func fallback(now: ContinuousClock.Instant = ContinuousClock.now) -> Fallback {
        guard let answer else { return .neverAnswered }
        let age = now - answer.at
        return .lastKnown(answer.value, age: age, badlyStale: age > staleThreshold)
    }
}
