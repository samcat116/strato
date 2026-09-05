import Fluent
import Foundation
import StratoShared
import Vapor

@testable import App

extension ConvergingResource {
    func extendConvergenceDeadline(by budget: TimeInterval, from date: Date = Date()) {
        extendConvergenceDeadline(by: budget, from: .testing(date))
    }

    func resolveForStuckOperation(
        mutation: VMOperationKind, telemetryReason: String
    ) -> Bool {
        resolveForStuckOperation(
            mutation: mutation, telemetryReason: telemetryReason, at: .testing(Date()))
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

    static func recordExpiredDeadline<R: ConvergingResource>(
        _ resource: R,
        mutation: VMOperationKind,
        now: Date,
        timeoutReason: String,
        on db: any Database
    ) async throws -> WriteOutcome {
        try await recordExpiredDeadline(
            resource, mutation: mutation, at: .testing(now), timeoutReason: timeoutReason, on: db)
    }
}

extension TimestampedConvergenceObservable {
    func recordTimestampedConvergence(
        phase: String?,
        lastError: String?,
        failedGeneration: Int64?,
        at date: Date = Date()
    ) -> Bool {
        recordTimestampedConvergence(
            phase: phase,
            lastError: lastError,
            failedGeneration: failedGeneration,
            at: .testing(date))
    }
}

extension VM {
    func setStatus(_ status: VMStatus, at date: Date = Date()) {
        setStatus(status, at: .testing(date))
    }
}

extension Sandbox {
    func setStatus(_ status: SandboxStatus, at date: Date = Date()) {
        setStatus(status, at: .testing(date))
    }

    func isExpired(at date: Date = Date()) -> Bool {
        isExpired(at: .testing(date))
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

    func sweepOrphanedTerminatingResources() async {
        await sweepOrphanedTerminatingResources(at: .testing(Date()))
    }

    func sweepExpiredSandboxes() async {
        await sweepExpiredSandboxes(at: .testing(Date()))
    }
}

extension SnapshotRetentionSweep {
    static func run(app: Application) async {
        await run(app: app, at: .testing(Date()))
    }
}

extension SnapshotRetention {
    static func expiry(
        requested: Int?,
        defaultTTLSeconds: Int? = nil,
        from date: Date
    ) throws -> Date? {
        try expiry(
            requested: requested,
            defaultTTLSeconds: defaultTTLSeconds,
            from: .testing(date))
    }
}

extension VMCommandExecutionService {
    func sweepStuck() async {
        await sweepStuck(at: .testing(Date()))
    }
}
