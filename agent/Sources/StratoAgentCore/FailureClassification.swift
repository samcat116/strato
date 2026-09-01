import Foundation

/// Whether a failed operation might succeed after time or host state changes,
/// or whether the request itself cannot succeed on this agent.
///
/// The reconciler uses this to preserve level-triggered retries for failures
/// whose remedy does not mint a new generation, while suppressing requests
/// whose spec, artifact, format, platform, or compiled capability is
/// intrinsically unsupported.
public enum FailureClassification: Sendable, Equatable {
    /// Might succeed on retry (network blip, service briefly down).
    case transient
    /// The request itself cannot succeed on this agent: for example an
    /// unsupported format or media type, no image manifest for this
    /// architecture, an invalid image reference, an unsafe archive, an
    /// unsupported platform, or a runtime absent from this agent build.
    /// Re-driving the same request against unchanged capabilities cannot help.
    case permanent
    /// The host is currently in a state that refuses this convergence, and the
    /// reported error names what clears it: capacity or disk space becomes
    /// available, a guest releases a volume, or an operator repairs a host
    /// precondition (STR-199, STR-262).
    ///
    /// The two halves are what make it its own case rather than a flavour of
    /// the two above. It is *reported* like a permanent failure, because the
    /// thing that lifts the block is usually a human and a human who is never
    /// told cannot act. It burns *no attempt*, like a dependency wait, because
    /// the block lifts without anyone minting a new generation — and the
    /// permanent-failure suppression would otherwise be the whole reason the
    /// remedy the error names changes nothing. Every sync re-drives it until
    /// it converges.
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
        case .insufficientDiskSpace:
            return .blocked
        case .createFailed, .deleteFailed, .resizeFailed, .snapshotFailed, .cloneFailed, .infoFailed,
            .volumeNotFound:
            return .transient
        }
    }
}
