import Foundation
import Vapor

/// Loads the SpiceDB authorization schema at startup when SpiceDB doesn't have
/// one yet. Without a schema, the first relationship write (e.g. the dev-user
/// bootstrap) fails with a 400 and the control plane crashes. This happens on
/// every fresh start of the local dev stack, whose in-memory SpiceDB loses its
/// schema on each container restart.
///
/// An existing schema is never overwritten, so deployments that manage the
/// schema externally (the zed one-shot in deploy/compose, the Helm schema job)
/// are unaffected — as are schema upgrades applied by those tools.
func ensureSpiceDBSchema(_ app: Application) async throws {
    guard let schemaPath = spiceDBSchemaPath(app) else {
        app.logger.debug("No SpiceDB schema file found; assuming schema is managed externally")
        return
    }

    if let existing = try await readSchemaWithRetry(app), !existing.isEmpty {
        app.logger.debug("SpiceDB already has a schema; not overwriting")
        return
    }

    let schema = try String(contentsOfFile: schemaPath, encoding: .utf8)
    try await app.spicedb.writeSchema(schema)
    app.logger.notice("Loaded SpiceDB schema", metadata: ["path": .string(schemaPath)])
}

/// Resolves the schema file: explicit SPICEDB_SCHEMA_PATH, or the repo's
/// spicedb/schema.zed relative to the working directory (covers both running
/// from the repo root and `swift run` from control-plane/).
private func spiceDBSchemaPath(_ app: Application) -> String? {
    if let explicit = Environment.get("SPICEDB_SCHEMA_PATH") {
        return explicit
    }
    let workingDirectory = app.directory.workingDirectory
    let candidates = [
        workingDirectory + "spicedb/schema.zed",
        workingDirectory + "../spicedb/schema.zed"
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
}

/// SpiceDB's container healthcheck probes gRPC, so its HTTP listener can lag
/// slightly behind; retry briefly before giving up.
private func readSchemaWithRetry(_ app: Application, attempts: Int = 5) async throws -> String? {
    for attempt in 1..<attempts {
        do {
            return try await app.spicedb.readSchema()
        } catch {
            app.logger.warning("SpiceDB schema read failed (attempt \(attempt)/\(attempts)), retrying: \(error)")
            try await Task.sleep(for: .seconds(1))
        }
    }
    return try await app.spicedb.readSchema()
}
