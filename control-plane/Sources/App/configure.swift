import Foundation
import Vapor

public func configure(
    _ app: Application,
    environmentVariables: [String: String] = ProcessInfo.processInfo.environment
) async throws {
    // Startup ordering is part of the control plane's interface. Each module
    // owns a cohesive phase; this manifest owns dependencies between phases.
    try await app.bootstrapFoundation(environmentVariables: environmentVariables)
    try app.bootstrapHTTPPipeline()
    try await app.bootstrapDatabase()
    try await app.reconcileStartupState()
    try await app.bootstrapRuntimeModules()
    app.bootstrapLifecycle()

    app.readiness.markMigrationsComplete()
    try routes(app)
    try app.assertAllRoutesClassified()
}
