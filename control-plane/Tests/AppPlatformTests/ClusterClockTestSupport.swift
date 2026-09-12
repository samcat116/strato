import Fluent
import Foundation
import StratoShared

@testable import App

extension ConvergingResource {
    func extendConvergenceDeadline(by budget: TimeInterval) {
        extendConvergenceDeadline(by: budget, from: .testing(Date()))
    }
}

extension ResourceConvergence {
    static func recordFailure<R: ConvergingResource>(
        _ resource: R,
        mutation: VMOperationKind,
        reason: String,
        telemetryReason: String,
        context: FailureRecordingContext = .resourceState,
        on db: any Database
    ) async throws -> WriteOutcome {
        try await recordFailure(
            resource, mutation: mutation, reason: reason, telemetryReason: telemetryReason,
            context: context, at: .testing(Date()), on: db)
    }
}

extension VM {
    func setStatus(_ status: VMStatus, at date: Date = Date()) {
        setStatus(status, at: .testing(date))
    }
}

extension ObservedStateApplier {
    func apply(_ report: ObservedStateReport) async throws -> UnrecognizedOutcome {
        try await apply(report, at: .testing(Date()))
    }
}

extension AgentMaintenanceLoop {
    func sweepStuckConvergence() async {
        await sweepStuckConvergence(at: .testing(Date()))
    }
}
