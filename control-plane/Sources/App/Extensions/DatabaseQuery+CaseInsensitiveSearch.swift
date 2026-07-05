import Fluent
import SQLKit

// MARK: - Engine-agnostic case-insensitive search filters
//
// PostgreSQL supports `ILIKE` for case-insensitive matching, but SQLite does not.
// To keep behaviour identical across both engines (production runs Postgres, tests
// may run either), these helpers emit `LOWER(<column>) LIKE LOWER(<pattern>) ESCAPE '\'`,
// which is valid on both SQLite and PostgreSQL.
//
// The filter is built as a `DatabaseQuery.Filter.custom` wrapping a `SQLQueryString`.
// The Fluent → SQL converter serializes a `.custom` payload that is an `SQLExpression`
// directly, so this needs only SQLKit (no `FluentSQL` import). Column and schema names
// are interpolated as identifiers and the search value is bound as a parameter, so the
// input is never concatenated into raw SQL.

extension DatabaseQuery.Filter {
    /// Case-insensitive "contains" match (SCIM `co`): rows where `column` contains `value`.
    static func caseInsensitiveContains(schema: String, column: String, value: String) -> DatabaseQuery.Filter {
        caseInsensitiveLike(schema: schema, column: column, pattern: "%\(escapeLikePattern(value))%")
    }

    /// Case-insensitive "starts with" match (SCIM `sw`): rows where `column` begins with `value`.
    static func caseInsensitiveStartsWith(schema: String, column: String, value: String) -> DatabaseQuery.Filter {
        caseInsensitiveLike(schema: schema, column: column, pattern: "\(escapeLikePattern(value))%")
    }

    /// Case-insensitive "ends with" match (SCIM `ew`): rows where `column` ends with `value`.
    static func caseInsensitiveEndsWith(schema: String, column: String, value: String) -> DatabaseQuery.Filter {
        caseInsensitiveLike(schema: schema, column: column, pattern: "%\(escapeLikePattern(value))")
    }

    /// Builds `LOWER(<schema>.<column>) LIKE LOWER(<pattern>) ESCAPE '\'`.
    ///
    /// `pattern` is expected to already contain the `%`/`_` wildcards for the desired
    /// match and to have had literal wildcard characters escaped via `escapeLikePattern`.
    private static func caseInsensitiveLike(schema: String, column: String, pattern: String) -> DatabaseQuery.Filter {
        let expression: SQLQueryString =
            "LOWER(\(ident: schema).\(ident: column)) LIKE LOWER(\(bind: pattern)) ESCAPE '\\'"
        return .custom(expression)
    }

    /// Escapes the LIKE metacharacters (`\`, `%`, `_`) in user input so they match
    /// literally. Pairs with the `ESCAPE '\'` clause emitted by `caseInsensitiveLike`.
    /// The backslash must be escaped first so the escapes added for `%`/`_` are preserved.
    static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
