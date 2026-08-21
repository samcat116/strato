import Foundation
import PostgresNIO

/// Fresh-install baseline with the exact legacy ledger name.
struct CurrentSchemaBaselineMigration: StratoMigration {
    let name = "App.CurrentSchemaBaseline.v1"

    func apply(on session: PostgresSession) async throws {
        let rows = try await session.query(
            """
            SELECT tablename
            FROM pg_tables
            WHERE schemaname = 'public'
              AND tablename <> '_fluent_migrations'
            ORDER BY tablename
            """,
            operation: "schema_baseline.existing_tables"
        )
        let tables = try rows.map { try $0.decode(String.self) }
        guard tables.isEmpty else {
            throw CurrentSchemaBaselineMigrationError.freshDatabaseRequired(tables: tables)
        }

        let script = try CurrentSchemaBaselineSQL.load()
        for statement in PostgreSQLScript.statements(in: script) {
            try await session.command(statement, operation: "schema_baseline.statement")
        }
    }
}

public enum CurrentSchemaBaselineMigrationError: Error, CustomStringConvertible, Sendable {
    case freshDatabaseRequired(tables: [String])

    public var description: String {
        switch self {
        case .freshDatabaseRequired(let tables):
            "The current-schema baseline requires a fresh database; existing tables: \(tables.joined(separator: ", "))"
        }
    }
}

enum PostgreSQLScript {
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
                case (39, _): state = .singleQuoted
                case (34, _): state = .doubleQuoted
                case (45, 45): state = .lineComment; index += 1
                case (47, 42): state = .blockComment(depth: 1); index += 1
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
                default: break
                }
            case .singleQuoted:
                if byte == 39 { if next == 39 { index += 1 } else { state = .normal } }
            case .doubleQuoted:
                if byte == 34 { if next == 34 { index += 1 } else { state = .normal } }
            case .lineComment:
                if byte == 10 { state = .normal }
            case .blockComment(let depth):
                if byte == 47, next == 42 {
                    state = .blockComment(depth: depth + 1); index += 1
                } else if byte == 42, next == 47 {
                    state = depth == 1 ? .normal : .blockComment(depth: depth - 1); index += 1
                }
            case .dollarQuoted(let tag):
                if bytes[index...].starts(with: tag) { state = .normal; index += tag.count - 1 }
            }
            index += 1
        }
        let tail = String(decoding: bytes[statementStart...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { statements.append(tail) }
        return statements
    }

    private static func dollarQuoteTag(in bytes: [UInt8], startingAt start: Int) -> [UInt8]? {
        var end = start + 1
        while end < bytes.count {
            let byte = bytes[end]
            if byte == 36 { return Array(bytes[start...end]) }
            let isIdentifier = byte == 95 || (48...57).contains(byte)
                || (65...90).contains(byte) || (97...122).contains(byte)
            guard isIdentifier else { return nil }
            end += 1
        }
        return nil
    }
}
