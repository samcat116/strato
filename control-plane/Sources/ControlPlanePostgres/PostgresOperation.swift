/// A bounded, code-authored name for a PostgreSQL operation.
///
/// Operation names are metric dimensions and span names. Accepting only string
/// literals prevents resource IDs, SQL, or caller input from creating
/// high-cardinality telemetry or leaking bindings.
public struct PostgresOperation: Sendable, Hashable, ExpressibleByStringLiteral {
    public let name: String

    public init(stringLiteral value: StaticString) {
        self.name = value.description
    }
}
