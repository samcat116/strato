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
}

/// Errors that know whether retrying them is useful. Unclassified errors are
/// treated as transient, which preserves the historical retry behavior.
public protocol ClassifiableError: Error {
    var failureClassification: FailureClassification { get }
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
