import Fluent
import Foundation
import SQLKit
import Vapor

/// The database boundary for every desired-state generation write.
///
/// A generation is not an ordinary model field: agents use it as the ordering
/// key for level-triggered desired state. Advancing it through a model's
/// in-memory snapshot lets two writers both persist `N + 1`, so all production
/// writers go through the SQL operations below instead.
enum DesiredStateGenerationWriter {
    enum Outcome: Equatable, Sendable {
        case applied(Int64)
        case superseded(actualGeneration: Int64)
        case missing
    }

    enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case unsupportedDatabase

        var description: String {
            switch self {
            case .unsupportedDatabase:
                return "Desired-state generation writes require an SQL database"
            }
        }
    }

    /// Atomically advances `generation`, optionally only when the row is still
    /// at the generation the caller read. `RETURNING` is authoritative: callers
    /// must copy it back to their model before any later `save`.
    static func advance(
        schema: String,
        id: UUID,
        expectedGeneration: Int64? = nil,
        on db: any Database
    ) async throws -> Outcome {
        guard let sql = db as? any SQLDatabase else { throw Error.unsupportedDatabase }

        let advanced: GenerationRow?
        let tracksNetworkFabric = schema == LogicalNetwork.schema || schema == SecurityGroup.schema
        let convergenceDeadline = Date().addingTimeInterval(180)
        if let expectedGeneration, tracksNetworkFabric {
            advanced = try await sql.raw(
                """
                UPDATE \(ident: schema)
                SET generation = generation + 1,
                    convergence_deadline = \(bind: convergenceDeadline)
                WHERE id = \(bind: id) AND generation = \(bind: expectedGeneration)
                RETURNING generation
                """
            ).first(decoding: GenerationRow.self)
        } else if let expectedGeneration {
            advanced = try await sql.raw(
                """
                UPDATE \(ident: schema)
                SET generation = generation + 1
                WHERE id = \(bind: id) AND generation = \(bind: expectedGeneration)
                RETURNING generation
                """
            ).first(decoding: GenerationRow.self)
        } else if tracksNetworkFabric {
            advanced = try await sql.raw(
                """
                UPDATE \(ident: schema)
                SET generation = generation + 1,
                    convergence_deadline = \(bind: convergenceDeadline)
                WHERE id = \(bind: id)
                RETURNING generation
                """
            ).first(decoding: GenerationRow.self)
        } else {
            advanced = try await sql.raw(
                """
                UPDATE \(ident: schema)
                SET generation = generation + 1
                WHERE id = \(bind: id)
                RETURNING generation
                """
            ).first(decoding: GenerationRow.self)
        }

        if let advanced { return .applied(advanced.generation) }
        return try await currentOutcome(schema: schema, id: id, on: sql)
    }

    @discardableResult
    static func advanceOrThrow(
        schema: String,
        id: UUID,
        resource: String,
        on db: any Database
    ) async throws -> Int64 {
        switch try await advance(schema: schema, id: id, on: db) {
        case .applied(let generation):
            return generation
        case .missing:
            throw Abort(.notFound, reason: "\(resource) no longer exists")
        case .superseded:
            // No expected generation was supplied, so an existing row always
            // advances. Keep the impossible case loud.
            throw Abort(.internalServerError, reason: "\(resource) generation did not advance")
        }
    }

    /// Takes the row lock and verifies that a background writer still owns the
    /// generation it is about to resolve. The lock remains held for the
    /// caller's transaction, closing the gap between this comparison and its
    /// subsequent model save or webhook enqueue.
    static func lockCurrent(
        schema: String,
        id: UUID,
        expectedGeneration: Int64? = nil,
        on db: any Database
    ) async throws -> Outcome {
        guard let sql = db as? any SQLDatabase else { throw Error.unsupportedDatabase }
        guard
            let row = try await sql.raw(
                "SELECT generation FROM \(ident: schema) WHERE id = \(bind: id) FOR UPDATE"
            ).first(decoding: GenerationRow.self)
        else { return .missing }

        if let expectedGeneration, row.generation != expectedGeneration {
            return .superseded(actualGeneration: row.generation)
        }
        return .applied(row.generation)
    }

    private static func currentOutcome(
        schema: String, id: UUID, on sql: any SQLDatabase
    ) async throws -> Outcome {
        guard
            let row = try await sql.raw(
                "SELECT generation FROM \(ident: schema) WHERE id = \(bind: id)"
            ).first(decoding: GenerationRow.self)
        else { return .missing }
        return .superseded(actualGeneration: row.generation)
    }

    private struct GenerationRow: Decodable {
        let generation: Int64
    }
}
