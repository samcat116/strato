import Foundation

/// Access to the reviewed fresh-schema baseline while the legacy Fluent
/// migrator and native migrator coexist during development.
public enum CurrentSchemaBaselineSQL {
    public static func load() throws -> String {
        guard let resource = Bundle.module.url(forResource: "CurrentSchema", withExtension: "sql") else {
            throw CurrentSchemaBaselineSQLError.resourceMissing
        }
        return try String(contentsOf: resource, encoding: .utf8)
    }
}

public enum CurrentSchemaBaselineSQLError: Error, Sendable {
    case resourceMissing
}
