import ControlPlanePostgres
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit

/// The STR-234 baseline mechanism.
///
/// Fresh databases are created from `CurrentSchema.sql`. Databases whose
/// `public` schema contains any application table are rejected: this cutover
/// deliberately requires a fresh database instead of guessing that an
/// arbitrary historical schema is safe to mark as current.
///
/// The bundled SQL was captured after STR-234's prerequisite schema cutovers;
/// see ADR 0009 for provenance and the rebuild-only transition decision.
struct CurrentSchemaBaseline: AsyncMigration {
    var name: String { "App.CurrentSchemaBaseline.v1" }

    func prepare(on database: any Database) async throws {
        guard
            let sql = database as? any SQLDatabase,
            sql.dialect.name == "postgresql"
        else {
            throw CurrentSchemaBaselineError.postgresRequired
        }

        let existingTables = try await sql.raw(
            """
            SELECT tablename
            FROM pg_tables
            WHERE schemaname = 'public'
              AND tablename <> '_fluent_migrations'
            ORDER BY tablename
            """
        ).all(decodingColumn: "tablename", as: String.self)

        guard existingTables.isEmpty else {
            throw CurrentSchemaBaselineError.freshDatabaseRequired(tables: existingTables)
        }

        let ddl: String
        do {
            ddl = try CurrentSchemaBaselineSQL.load()
        } catch {
            throw CurrentSchemaBaselineError.resourceMissing
        }

        // pg_dump emits a complete dependency-ordered script. PostgresNIO uses
        // the extended protocol, which intentionally accepts one statement per
        // request, so split only on semicolons outside quoted strings, comments,
        // and dollar-quoted function bodies. The surrounding SchemaMigrator
        // transaction still keeps the full script and its log row atomic.
        for statement in SQLScript.statements(in: ddl) {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
    }

    func revert(on database: any Database) async throws {
        throw CurrentSchemaBaselineError.irreversible
    }
}

private enum SQLScript {
    private enum State {
        case normal
        case singleQuoted
        case doubleQuoted
        case lineComment
        case blockComment(depth: Int)
        case dollarQuoted(tag: [UInt8])
    }

    static func statements(in script: String) -> [String] {
        let bytes = Array(script.utf8)
        var statements: [String] = []
        var state = State.normal
        var statementStart = 0
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil

            switch state {
            case .normal:
                switch (byte, next) {
                case (39, _):
                    state = .singleQuoted
                case (34, _):
                    state = .doubleQuoted
                case (45, 45):
                    state = .lineComment
                    index += 1
                case (47, 42):
                    state = .blockComment(depth: 1)
                    index += 1
                case (36, _):
                    if let tag = dollarQuoteTag(in: bytes, startingAt: index) {
                        state = .dollarQuoted(tag: tag)
                        index += tag.count - 1
                    }
                case (59, _):
                    let statement = String(decoding: bytes[statementStart...index], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !statement.isEmpty { statements.append(statement) }
                    statementStart = index + 1
                default:
                    break
                }

            case .singleQuoted:
                if byte == 39 {
                    if next == 39 { index += 1 } else { state = .normal }
                }

            case .doubleQuoted:
                if byte == 34 {
                    if next == 34 { index += 1 } else { state = .normal }
                }

            case .lineComment:
                if byte == 10 { state = .normal }

            case .blockComment(let depth):
                if byte == 47, next == 42 {
                    state = .blockComment(depth: depth + 1)
                    index += 1
                } else if byte == 42, next == 47 {
                    state = depth == 1 ? .normal : .blockComment(depth: depth - 1)
                    index += 1
                }

            case .dollarQuoted(let tag):
                if bytes[index...].starts(with: tag) {
                    state = .normal
                    index += tag.count - 1
                }
            }

            index += 1
        }

        return statements
    }

    private static func dollarQuoteTag(in bytes: [UInt8], startingAt start: Int) -> [UInt8]? {
        var end = start + 1
        while end < bytes.count {
            let byte = bytes[end]
            if byte == 36 { return Array(bytes[start...end]) }
            let isIdentifier =
                byte == 95 || (48...57).contains(byte)
                || (65...90).contains(byte) || (97...122).contains(byte)
            guard isIdentifier else { return nil }
            end += 1
        }
        return nil
    }
}

enum CurrentSchemaBaselineError: Error, CustomStringConvertible, Sendable {
    case postgresRequired
    case resourceMissing
    case freshDatabaseRequired(tables: [String])
    case irreversible

    var description: String {
        switch self {
        case .postgresRequired:
            return "The current-schema baseline requires PostgreSQL"
        case .resourceMissing:
            return "The bundled CurrentSchema.sql baseline is missing"
        case .freshDatabaseRequired(let tables):
            return """
                The STR-234 schema baseline requires a fresh database, but the public schema already has \(tables.count) \(tables.count == 1 ? "table" : "tables"): \(tables.joined(separator: ", ")). No existing table was changed. Export any data that must be retained, rebuild the database, and import it through the current application model.
                """
        case .irreversible:
            return "The current-schema baseline is irreversible; discard and recreate the database instead"
        }
    }
}
