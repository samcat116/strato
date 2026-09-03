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
