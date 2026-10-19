import Fluent
import SwiftSCIM

/// Shared expression traversal; handlers retain their resource-specific attributes and presence checks.
enum SCIMQueryFilter {
    static func apply<M: Model>(
        _ filter: SCIMFilterExpression,
        to query: QueryBuilder<M>,
        attribute: (String, SCIMFilterOperator, SCIMComparisonValue, QueryBuilder<M>) throws -> QueryBuilder<M>,
        present: (String, QueryBuilder<M>) -> QueryBuilder<M>
    ) throws -> QueryBuilder<M> {
        switch filter {
        case .attribute(let path, let op, let value):
            return try attribute(path, op, value, query)
        case .logical(let op, let left, let right):
            switch op {
            case .and:
                let result = try apply(left, to: query, attribute: attribute, present: present)
                return try apply(right, to: result, attribute: attribute, present: present)
            case .or, .not:
                throw SCIMServerError.invalidFilter(detail: "SCIM logical filter operator '\(op)' is not supported")
            }
        case .not:
            throw SCIMServerError.invalidFilter(detail: "SCIM NOT filter is not supported")
        case .present(let path):
            return present(path, query)
        case .group(let inner):
            return try apply(inner, to: query, attribute: attribute, present: present)
        case .empty:
            return query
        }
    }

    static func string<M: Model>(
        keyPath: KeyPath<M, FieldProperty<M, String>>,
        column: String,
        op: SCIMFilterOperator,
        value: String,
        to query: QueryBuilder<M>
    ) -> QueryBuilder<M> {
        switch op {
        case .equal:
            return query.filter(keyPath == value)
        case .notEqual:
            return query.filter(keyPath != value)
        case .contains:
            return query.filter(.caseInsensitiveContains(schema: M.schema, column: column, value: value))
        case .startsWith:
            return query.filter(.caseInsensitiveStartsWith(schema: M.schema, column: column, value: value))
        case .endsWith:
            return query.filter(.caseInsensitiveEndsWith(schema: M.schema, column: column, value: value))
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .present:
            return query
        }
    }
}
