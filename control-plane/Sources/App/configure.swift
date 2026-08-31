import Foundation
import Vapor

public func configure(
    _ app: Application,
    environmentVariables: [String: String] = ProcessInfo.processInfo.environment
) async throws {
    // Startup ordering is part of the control plane's interface. Each bootstrap
    // module owns a cohesive phase; this manifest owns the dependencies between
    // those phases.
    try await app.bootstrapFoundation(environmentVariables: environmentVariables)
    try app.bootstrapHTTPPipeline()
    try await app.bootstrapDatabase()
    try await app.reconcileStartupState()
    try await app.bootstrapRuntimeModules()
    app.bootstrapLifecycle()

    // Open the readiness gate: every migration, schema load, and boot-time
    // backfill above has finished. Vapor binds the port only after `configure`
    // returns, so in the normal path a probe cannot arrive before this line —
    // the gate exists so that stays true if boot work ever moves later, and so
    // "ready" has an explicit meaning rather than an implicit one.
    app.readiness.markMigrationsComplete()

    try routes(app)

    // The structural half of default-deny (#482): every registered route must
    // carry an authorization classification, or the process refuses to start.
    // Runs in every environment, so the whole test suite fails the moment an
    // unclassified endpoint is added.
    try app.assertAllRoutesClassified()
}
