import Logging

/// Runs an independent reconciliation side effect without aborting the rest
/// of the pass. The returned flag lets callers suppress dependent work while
/// the next level-triggered sync remains responsible for retrying the step.
@discardableResult
public func attempt(
    _ logger: Logger,
    _ step: String,
    _ body: () async throws -> Void
) async -> Bool {
    do {
        try await body()
        return true
    } catch {
        logger.error(
            "Network reconcile step failed",
            metadata: [
                "step": .string(step),
                "error": .string(error.localizedDescription),
            ])
        return false
    }
}

/// One failed best-effort network step retained for the observed-state report.
public struct ReconcileStepFailure: Sendable, Equatable {
    public let message: String
    public let classification: FailureClassification

    public init(message: String, classification: FailureClassification) {
        self.message = message
        self.classification = classification
    }
}

/// Runs a best-effort step while returning the failure instead of reducing it
/// to a log line. Used by reconcilers whose caller publishes observed state.
public func observeAttempt(
    _ logger: Logger,
    _ step: String,
    _ body: () async throws -> Void
) async -> ReconcileStepFailure? {
    do {
        try await body()
        return nil
    } catch {
        logger.error(
            "Network reconcile step failed",
            metadata: [
                "step": .string(step),
                "error": .string(error.localizedDescription),
            ])
        return ReconcileStepFailure(
            message: "\(step): \(error.localizedDescription)",
            classification: (error as? any ClassifiableError)?.failureClassification ?? .transient)
    }
}
