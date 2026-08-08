import Foundation

/// Whether a failed operation could succeed if simply retried, or needs an
/// operator to change something on the host first.
///
/// The reconciler uses this to stop burning its per-generation retry budget
/// on failures that can never self-heal (missing binaries, permission
/// problems, a full disk): a permanent failure is reported once with its
/// remediation instead of re-running the same doomed convergence.
public enum FailureClassification: Sendable, Equatable {
    /// Might succeed on retry (network blip, service briefly down).
    case transient
    /// Will keep failing until the host is fixed (misconfiguration,
    /// missing dependency, permissions, disk full).
    case permanent
    /// Refused by a precondition that this convergence cannot satisfy but that
    /// clears on its own or when an operator acts on the reported reason — a
    /// volume grow refused because the guest holding the image is still running
    /// (STR-199).
    ///
    /// The two halves are what make it its own case rather than a flavour of
    /// the two above. It is *reported* like a permanent failure, because the
    /// thing that lifts the block is usually a human and a human who is never
    /// told cannot act. It burns *no attempt*, like a dependency wait, because
    /// the block lifts without anyone minting a new generation — and the
    /// attempt cap is otherwise the whole reason the remedy the error names
    /// changes nothing. Every sync re-drives it until it converges.
    case blocked
    /// Cannot succeed until *another component* converges first — e.g. a VM
    /// port on a shared site NB whose switch the site's network controller
    /// hasn't realized yet (issue #343). Not a failure at all: the reconciler
    /// reports no error (an error would fail the pending operation on the
    /// control plane) and burns no retry budget; the periodic level-triggered
    /// sync re-drives the item until the dependency lands, with the control
    /// plane's operation completion budget as the backstop.
    case waitingOnDependency
}

/// Errors that know whether retrying them is useful. Unclassified errors are
/// treated as transient, which preserves the historical retry behavior.
public protocol ClassifiableError: Error {
    var failureClassification: FailureClassification { get }
}

/// A convergence blocker that is another component's pending work, not this
/// host's fault (see `FailureClassification.waitingOnDependency`).
public struct DependencyPendingError: ClassifiableError, LocalizedError {
    public let reason: String
    public var failureClassification: FailureClassification { .waitingOnDependency }
    public var errorDescription: String? { reason }

    public init(_ reason: String) {
        self.reason = reason
    }
}

extension StorageBackendError: ClassifiableError {
    public var failureClassification: FailureClassification {
        switch self {
        case .hostMisconfiguration, .unsupportedFormat, .imageSourceUnavailable:
            return .permanent
        case .createFailed, .deleteFailed, .resizeFailed, .snapshotFailed, .cloneFailed, .infoFailed,
            .volumeNotFound:
            return .transient
        }
    }
}
