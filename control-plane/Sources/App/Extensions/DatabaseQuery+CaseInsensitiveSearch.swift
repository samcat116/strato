import Fluent
import FluentSQL
import SQLKit

extension DatabaseQuery.Filter {
    /// A cross-engine, case-insensitive substring match: `LOWER(schema.column) LIKE LOWER('%needle%')`.
    ///
    /// Fluent's `~~` ("contains") operator compiles to a bare `LIKE`, which is
    /// case-*insensitive* on SQLite but case-*sensitive* on Postgres. Searches
    /// that passed against the SQLite test database silently returned nothing in
    /// production against Postgres (issue #195). Lowering both operands makes the
    /// match behave identically on both engines.
    ///
    /// The column is schema-qualified so the filter is unambiguous inside joined
    /// queries where more than one table exposes the same column name. User input
    /// has its `LIKE` metacharacters (`%`, `_`, `\`) escaped so it is treated as a
    /// literal substring rather than a pattern.
    static func caseInsensitiveContains(
        schema: String,
        column: String,
        value: String
    ) -> DatabaseQuery.Filter {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return .sql(embed: "LOWER(\(ident: schema).\(ident: column)) LIKE LOWER(\(bind: "%\(escaped)%")) ESCAPE '\\'")
    }
}
