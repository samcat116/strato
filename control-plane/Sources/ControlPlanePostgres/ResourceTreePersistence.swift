import Foundation
import PostgresNIO

public struct ResourceTreeParentSnapshot: Equatable, Sendable {
    public let type: String
    public let id: UUID

    public init(type: String, id: UUID) {
        self.type = type
        self.id = id
    }
}

public struct ResourceTreeStepSnapshot: Equatable, Sendable {
    public let id: UUID
    public let parent: ResourceTreeParentSnapshot?
    public let environment: String?
    public let materializedPath: String?

    public init(
        id: UUID,
        parent: ResourceTreeParentSnapshot?,
        environment: String?,
        materializedPath: String?
    ) {
        self.id = id
        self.parent = parent
        self.environment = environment
        self.materializedPath = materializedPath
    }
}

public enum ResourceTreePersistenceError: Error, Equatable, Sendable {
    case unsupportedNodeType(String)
}

/// Resolves one parent edge for IAM tree nodes. The SQL is fixed and
/// allowlisted by node discriminator; callers cannot supply a table or column
/// fragment.
public struct ResourceTreePersistence: Sendable {
    private static let storedNodeTypes: Set<String> = [
        "organizational_unit",
        "project",
        "virtual_machine",
        "sandbox",
        "image",
        "network",
        "floating_ip",
        "load_balancer",
        "security_group",
        "dns_zone",
        "dns_record",
        "volume",
        "volume_snapshot",
        "sandbox_snapshot",
        "vm_snapshot",
        "site",
        "agent",
        "service_account",
    ]

    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func steps(
        nodeType: String,
        ids: [UUID]
    ) async throws -> [UUID: ResourceTreeStepSnapshot] {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return [:] }

        // These two node kinds are intentionally parentless and historically
        // do not verify row existence during an ancestry walk.
        if nodeType == "organization" || nodeType == "user" {
            return Dictionary(
                uniqueKeysWithValues: uniqueIDs.map {
                    (
                        $0,
                        ResourceTreeStepSnapshot(
                            id: $0,
                            parent: nil,
                            environment: nil,
                            materializedPath: nil
                        )
                    )
                }
            )
        }
        guard Self.storedNodeTypes.contains(nodeType) else {
            throw ResourceTreePersistenceError.unsupportedNodeType(nodeType)
        }

        return try await database.withSession(operation: "iam.resource_tree.steps") { session in
            let rows = try await session.execute(
                ResolveResourceTreeSteps(nodeType: nodeType, ids: uniqueIDs),
                operation: "iam.resource_tree.steps.query"
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        }
    }
}

private struct ResolveResourceTreeSteps: PostgresPreparedStatement {
    static let sql = """
        SELECT id,
               CASE WHEN parent_ou_id IS NULL THEN 'organization'
                    ELSE 'organizational_unit' END AS parent_type,
               COALESCE(parent_ou_id, organization_id) AS parent_id,
               NULL::text AS environment,
               path AS materialized_path
        FROM organizational_units AS ou
        WHERE $1 = 'organizational_unit'
          AND (
            ou.id = ANY($2::uuid[])
            OR EXISTS (
                SELECT 1
                FROM organizational_units AS requested
                WHERE requested.id = ANY($2::uuid[])
                  AND ou.id::text = ANY(
                    string_to_array(trim(both '/' from requested.path), '/')
                  )
            )
          )

        UNION ALL
        SELECT id,
               CASE WHEN organizational_unit_id IS NOT NULL THEN 'organizational_unit'
                    WHEN organization_id IS NOT NULL THEN 'organization'
                    ELSE NULL END,
               COALESCE(organizational_unit_id, organization_id),
               NULL::text,
               path
        FROM projects
        WHERE $1 = 'project' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, environment, NULL::text
        FROM vms
        WHERE $1 = 'virtual_machine' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, environment, NULL::text
        FROM sandboxes
        WHERE $1 = 'sandbox' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM images
        WHERE $1 = 'image' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM logical_networks
        WHERE $1 = 'network' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM floating_ips
        WHERE $1 = 'floating_ip' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM load_balancers
        WHERE $1 = 'load_balancer' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM security_groups
        WHERE $1 = 'security_group' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM dns_zones
        WHERE $1 = 'dns_zone' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'dns_zone', zone_id, NULL::text, NULL::text
        FROM dns_records
        WHERE $1 = 'dns_record' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM volumes
        WHERE $1 = 'volume' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM volume_snapshots
        WHERE $1 = 'volume_snapshot' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, environment, NULL::text
        FROM sandbox_snapshots
        WHERE $1 = 'sandbox_snapshot' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, environment, NULL::text
        FROM vm_snapshots
        WHERE $1 = 'vm_snapshot' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id,
               CASE WHEN organizational_unit_id IS NOT NULL THEN 'organizational_unit'
                    WHEN organization_id IS NOT NULL THEN 'organization'
                    ELSE NULL END,
               COALESCE(organizational_unit_id, organization_id),
               NULL::text,
               NULL::text
        FROM sites
        WHERE $1 = 'site' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id,
               CASE WHEN organizational_unit_id IS NOT NULL THEN 'organizational_unit'
                    WHEN organization_id IS NOT NULL THEN 'organization'
                    ELSE NULL END,
               COALESCE(organizational_unit_id, organization_id),
               NULL::text,
               NULL::text
        FROM agents
        WHERE $1 = 'agent' AND id = ANY($2::uuid[])

        UNION ALL
        SELECT id, 'project', project_id, NULL::text, NULL::text
        FROM service_accounts
        WHERE $1 = 'service_account' AND id = ANY($2::uuid[])

        ORDER BY id
        """

    typealias Row = ResourceTreeStepSnapshot
    let nodeType: String
    let ids: [UUID]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(nodeType)
        bindings.append(ids)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> ResourceTreeStepSnapshot {
        let value = try row.decode((UUID, String?, UUID?, String?, String?).self)
        let parent = try value.1.map { type in
            guard let id = value.2 else {
                throw ResourceTreePersistenceError.unsupportedNodeType(type)
            }
            return ResourceTreeParentSnapshot(type: type, id: id)
        }
        return ResourceTreeStepSnapshot(
            id: value.0,
            parent: parent,
            environment: value.3,
            materializedPath: value.4
        )
    }
}
