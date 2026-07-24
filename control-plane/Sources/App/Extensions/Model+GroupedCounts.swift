import Fluent
import Foundation
import SQLKit
import Vapor

/// One `GROUP BY` in place of a `COUNT` per row.
///
/// List endpoints decorate every row they return with a count of the rows
/// pointing at it — VMs per project, members per group, floating IPs per pool.
/// Issued inside the loop that builds the response that is a round-trip per
/// row, on exactly the surfaces the UI polls hardest; issued as one grouped
/// aggregate the cost stops growing with the page.
///
/// Keys with no rows are absent from the result rather than present as zero,
/// so callers read the dictionary with a `?? 0` default.
extension Model {
    /// Counts rows per `@Parent` id, over the given ids only.
    static func counts<Parent: Model>(
        groupedBy parent: KeyPath<Self, ParentProperty<Self, Parent>>,
        in ids: [Parent.IDValue],
        on db: any Database
    ) async throws -> [Parent.IDValue: Int] {
        try await groupedCounts(column: try column(for: parent.appending(path: \.$id)), in: ids, on: db)
    }

    /// Counts rows per `@OptionalParent` id. Rows whose parent is NULL match no
    /// requested id and so are counted under nothing.
    static func counts<Parent: Model>(
        groupedBy parent: KeyPath<Self, OptionalParentProperty<Self, Parent>>,
        in ids: [Parent.IDValue],
        on db: any Database
    ) async throws -> [Parent.IDValue: Int] {
        try await groupedCounts(column: try column(for: parent.appending(path: \.$id)), in: ids, on: db)
    }

    /// Counts rows per value of a plain `@Field` — for the references that are
    /// a stored value rather than a relation, like a NIC's network name.
    static func counts<Value: Codable & Hashable & Sendable>(
        groupedBy field: KeyPath<Self, FieldProperty<Self, Value>>,
        in values: [Value],
        on db: any Database
    ) async throws -> [Value: Int] {
        try await groupedCounts(column: try column(for: field), in: values, on: db)
    }

    private static func groupedCounts<Key: Codable & Hashable & Sendable>(
        column: String,
        in keys: [Key],
        on db: any Database
    ) async throws -> [Key: Int] {
        guard !keys.isEmpty else { return [:] }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Grouped counts require an SQL database")
        }

        let rows = try await sql.select()
            .column(SQLColumn(column), as: "group_key")
            .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "row_count")
            .from(Self.schema)
            .where(SQLColumn(column), .in, SQLBind.group(Array(Set(keys))))
            .groupBy(SQLColumn(column))
            .all(decoding: GroupedCountRow<Key>.self)

        return Dictionary(uniqueKeysWithValues: rows.map { ($0.group_key, $0.row_count) })
    }

    /// The single column a key path names. Nested field paths address JSON
    /// sub-values rather than a column, which no caller here wants to group by.
    private static func column<Property: AnyQueryableProperty>(for field: KeyPath<Self, Property>) throws -> String {
        let path = Self.path(for: field)
        guard path.count == 1, let key = path.first else {
            throw Abort(.internalServerError, reason: "Grouped counts require a column, not a nested field path")
        }
        return key.description
    }
}

private struct GroupedCountRow<Key: Decodable>: Decodable {
    let group_key: Key
    let row_count: Int
}
