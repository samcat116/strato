import Foundation
import Vapor

/// Loads the SpiceDB authorization schema at startup when SpiceDB doesn't have
/// one yet. Without a schema, the first relationship write (e.g. the dev-user
/// bootstrap) fails with a 400 and the control plane crashes. This happens on
/// every fresh start of the local dev stack, whose in-memory SpiceDB loses its
/// schema on each container restart.
///
/// An existing schema is upgraded only when the file introduces object types
/// the deployed schema lacks — the startup backfills that follow would
/// otherwise 400 writing tuples for the new types. Anything subtler (changed
/// permission expressions, new relations on existing types) is deliberately
/// left to the external schema appliers (the zed one-shot in deploy/compose,
/// the Helm schema job, `task dev`), which re-apply the full file on every
/// deploy; overwriting on any text difference here would stomp deployments
/// that manage the schema out of band.
func ensureSpiceDBSchema(_ app: Application) async throws {
    guard let schemaPath = spiceDBSchemaPath(app) else {
        app.logger.debug("No SpiceDB schema file found; assuming schema is managed externally")
        return
    }

    let schema = try String(contentsOfFile: schemaPath, encoding: .utf8)

    if let existing = try await readSchemaWithRetry(app), !existing.isEmpty {
        let missing = definitionNames(in: schema).subtracting(definitionNames(in: existing))
        guard !missing.isEmpty else {
            app.logger.debug("SpiceDB already has a schema; not overwriting")
            return
        }
        app.logger.notice(
            "SpiceDB schema is missing object types; applying the bundled schema",
            metadata: ["missing": .string(missing.sorted().joined(separator: ","))])
    }

    try await app.spicedb.writeSchema(schema)
    app.logger.notice("Loaded SpiceDB schema", metadata: ["path": .string(schemaPath)])
}

/// Object-type names declared in a schema text (`definition <name> {`).
private func definitionNames(in schema: String) -> Set<String> {
    var names: Set<String> = []
    for line in schema.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("definition ") else { continue }
        let rest = trimmed.dropFirst("definition ".count)
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        if !name.isEmpty {
            names.insert(String(name))
        }
    }
    return names
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
        workingDirectory + "../spicedb/schema.zed",
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
