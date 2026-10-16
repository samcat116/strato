import Foundation
import Vapor

struct StoreUnavailableError: Error {}

/// One gate per coordination endpoint, shared with the authentication limiter.
/// Only the recovery probe can close an open gate; late successes from commands
/// started before the outage cannot erase a newer failure decision.
actor CoordinationFailureGate {
    static let defaultDeadline: Duration = .seconds(2)
    private let threshold: Int
    private let cooldown: Duration
    private let maxCooldown: Duration
    private let deadline: Duration
    private let probe: @Sendable () async throws -> Void
    private let logger: Logger
    private let now: @Sendable () -> ContinuousClock.Instant
    private var failures = 0
    private var epoch = 0
    private var openedUntil: ContinuousClock.Instant?
    private var recoveryRunning = false
    private var recoveryCooldown: Duration

    init(
        deadline: Duration = CoordinationFailureGate.defaultDeadline, threshold: Int = 3,
        cooldown: Duration = .seconds(1), maxCooldown: Duration = .seconds(30),
        logger: Logger = Logger(label: "coordination-gate"),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        probe: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.deadline = deadline
        self.threshold = max(1, threshold)
        self.cooldown = cooldown
        self.maxCooldown = maxCooldown
        self.recoveryCooldown = cooldown
        self.logger = logger
        self.now = now
        self.probe = probe
    }

    var unavailable: Bool { failures > 0 || openedUntil != nil }

    func run<Value: Sendable>(
        operation: String, deadline override: Duration? = nil,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        if let until = openedUntil {
            guard now() >= until, !recoveryRunning else {
                Telemetry.coordinationFailOpen(operation: operation)
                throw StoreUnavailableError()
            }
            recoveryRunning = true
            do {
                try await withStoreTimeout(deadline, probe)
                openedUntil = nil
                failures = 0
                epoch += 1
                recoveryCooldown = cooldown
                recoveryRunning = false
                Telemetry.coordinationStoreUnavailable(false)
                logger.info("Coordination store recovered")
            } catch {
                recoveryRunning = false
                // Cancellation of this caller does not count as a store failure.
                if !(error is CancellationError) {
                    recoveryCooldown = min(maxCooldown, recoveryCooldown * 2)
                    openedUntil = now().advanced(by: recoveryCooldown)
                }
                Telemetry.coordinationFailOpen(operation: operation)
                throw error
            }
        }
        let startedEpoch = epoch
        do {
            let value = try await withStoreTimeout(override ?? deadline, body)
            if epoch == startedEpoch, openedUntil == nil {
                failures = 0
                Telemetry.coordinationStoreUnavailable(false)
            }
            return value
        } catch {
            if !(error is CancellationError), epoch == startedEpoch {
                failures += 1
                Telemetry.coordinationStoreUnavailable(true)
                if failures >= threshold {
                    epoch += 1
                    openedUntil = now().advanced(by: recoveryCooldown)
                    logger.warning("Coordination store failure gate opened")
                }
            }
            if !(error is CancellationError) { Telemetry.coordinationFailOpen(operation: operation) }
            throw error
        }
    }
}
