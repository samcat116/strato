import Foundation
import NIOConcurrencyHelpers
import Vapor

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Process-local gates on `/health/ready` that no dependency probe can observe.
///
/// Dependency reachability (Postgres, SpiceDB, Valkey) is probed per request;
/// these two facts are about *this* process's lifecycle and have to be recorded
/// as they happen:
///
/// - `migrationsComplete` — a replica that answers `SELECT 1` mid-`autoMigrate`
///   is reachable but not ready. Without this gate a blue/green cutover can
///   route traffic at a replica whose schema is half-applied.
/// - `draining` — set on `SIGTERM` so the replica reports itself unready
///   *before* it stops accepting connections, giving the load balancer a window
///   to pull it out of rotation and let in-flight requests and agent WebSockets
///   finish. See `docs/deployment/health-checks.md`.
final class ReadinessState: Sendable {
    private struct State {
        var migrationsComplete = false
        var draining = false
    }

    private let state = NIOLockedValueBox(State())

    /// True once `autoMigrate` and the boot-time schema/registry sync have finished.
    var migrationsComplete: Bool {
        state.withLockedValue { $0.migrationsComplete }
    }

    /// True once this process has been asked to shut down.
    var isDraining: Bool {
        state.withLockedValue { $0.draining }
    }

    func markMigrationsComplete() {
        state.withLockedValue { $0.migrationsComplete = true }
    }

    /// Re-close the migrations gate so tests can exercise the unready path.
    /// `configure` opens it during boot, and the alternative — tearing down a
    /// live dependency mid-test — would be far more fragile.
    func closeMigrationsGateForTesting() {
        state.withLockedValue { $0.migrationsComplete = false }
    }

    /// Idempotent: returns true only for the transition into draining, so the
    /// signal handler logs once even if the signal is delivered repeatedly.
    @discardableResult
    func beginDraining() -> Bool {
        state.withLockedValue { current in
            guard !current.draining else { return false }
            current.draining = true
            return true
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct ReadinessStateKey: StorageKey {
        typealias Value = ReadinessState
    }

    /// The readiness gates for this process. Created on first access so tests
    /// that never boot the full lifecycle still get a usable (not-yet-migrated,
    /// not-draining) state.
    var readiness: ReadinessState {
        if let existing = storage[ReadinessStateKey.self] { return existing }
        let created = ReadinessState()
        storage[ReadinessStateKey.self] = created
        return created
    }
}

extension Request {
    var readiness: ReadinessState {
        application.readiness
    }
}

// MARK: - Drain signalling

/// Flips `readiness.isDraining` on `SIGTERM` so `/health/ready` starts returning
/// 503 the moment a shutdown is requested.
///
/// Vapor's `ServeCommand` installs its own `SIGTERM` source and begins tearing
/// the server down immediately; a `DispatchSourceSignal` does not consume the
/// signal, so both handlers observe it and this one only has to record the fact.
/// The actual drain *window* is the orchestrator's job — a `preStop` hook in
/// Kubernetes (see the Helm chart's `terminationDrain`), or a stop timeout under
/// Compose — because the process cannot delay a shutdown Vapor has already begun.
struct DrainSignalLifecycleHandler: LifecycleHandler {
    /// Kept alive for the process lifetime; a `DispatchSourceSignal` stops
    /// delivering once it is deallocated.
    private static let source = NIOLockedValueBox<DispatchSourceSignal?>(nil)

    func didBootAsync(_ application: Application) async throws {
        // Tests boot and tear down many applications in one process; installing
        // a signal source per application would leak sources and let a handler
        // outlive the app it captured.
        guard application.environment != .testing else { return }

        let readiness = application.readiness
        let logger = application.logger
        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        signalSource.setEventHandler {
            guard readiness.beginDraining() else { return }
            logger.notice("SIGTERM received: reporting unready, draining in-flight work")
        }
        signalSource.resume()
        Self.source.withLockedValue { $0 = signalSource }
    }

    func shutdownAsync(_ application: Application) async {
        // A shutdown that did not come from SIGTERM (a crash-free programmatic
        // stop) should still read as draining to anything polling readiness
        // during teardown.
        application.readiness.beginDraining()
        Self.source.withLockedValue { existing in
            existing?.cancel()
            existing = nil
        }
    }
}
