import Fluent
import Foundation
import Vapor

/// Boot-time backfills that populate `role_bindings` from the data that
/// pre-dates it (IAM phase 1, issue #477). Both are idempotent — they only
/// insert bindings that don't exist — and run every startup while SpiceDB
/// remains authoritative, so a dual-write missed by a crashed request is
/// repaired at the next boot.
enum RoleBindingBackfill {
    /// The resource types whose `owner`/`viewer`/`editor` tuples live *only*
    /// in SpiceDB (no relational mirror) and must be exported before cutover.
    static let exportedResourceTypes: [IAMNodeType] = [
        .virtualMachine, .sandbox, .image, .network, .volume, .volumeSnapshot,
    ]
    static let exportedRelations = ["owner", "editor", "viewer"]

    /// Backfill from the relational mirrors: org admins (`user_organizations`),
    /// project user roles (`project_members`), and project group roles
    /// (`project_group_grants`). Bare org membership maps to no binding.
    static func backfillFromMirrors(_ app: Application) async throws {
        let db = app.db
        var existing = try await existingKeys(on: db)
        var inserted = 0

        for membership in try await UserOrganization.query(on: db).all() {
            guard let role = IAMRole.fromOrganizationRole(membership.role) else { continue }
            inserted += try await insertIfMissing(
                RoleBinding(
                    principalType: .user,
                    principalID: membership.$user.id,
                    role: role,
                    nodeType: .organization,
                    nodeID: membership.$organization.id
                ),
                existing: &existing,
                on: db
            )
        }

        for member in try await ProjectMember.query(on: db).all() {
            guard let projectRole = ProjectRole(rawValue: member.role) else { continue }
            inserted += try await insertIfMissing(
                RoleBinding(
                    principalType: .user,
                    principalID: member.$user.id,
                    role: .fromProjectRole(projectRole),
                    nodeType: .project,
                    nodeID: member.$project.id
                ),
                existing: &existing,
                on: db
            )
        }

        for grant in try await ProjectGroupGrant.query(on: db).all() {
            guard let projectRole = ProjectRole(rawValue: grant.role) else { continue }
            inserted += try await insertIfMissing(
                RoleBinding(
                    principalType: .group,
                    principalID: grant.$group.id,
                    role: .fromProjectRole(projectRole),
                    nodeType: .project,
                    nodeID: grant.$project.id
                ),
                existing: &existing,
                on: db
            )
        }

        if inserted > 0 {
            app.logger.info(
                "Role bindings backfilled from relational mirrors",
                metadata: ["inserted": .string(String(inserted))])
        }
    }

    /// Backfill from a SpiceDB relationship export: resource-level
    /// `owner`/`viewer`/`editor` tuples have no relational mirror, so they are
    /// read out of SpiceDB directly (`owner` becomes an `admin` binding).
    static func backfillFromSpiceDB(_ app: Application) async throws {
        let spicedb = try app.spicedb
        let db = app.db
        var existing = try await existingKeys(on: db)
        var inserted = 0

        for nodeType in exportedResourceTypes {
            for relation in exportedRelations {
                let tuples = try await spicedb.readRelationships(
                    resourceType: nodeType.rawValue, relation: relation)
                for tuple in tuples {
                    // Resource role tuples are user grants; SpiceDB returns
                    // uppercase UUID object ids, which UUID(uuidString:) accepts.
                    guard tuple.subject == "user",
                        let principalID = UUID(uuidString: tuple.subjectId),
                        let nodeID = UUID(uuidString: tuple.entityId),
                        let role = IAMRole.fromResourceRelation(tuple.relation)
                    else { continue }
                    inserted += try await insertIfMissing(
                        RoleBinding(
                            principalType: .user,
                            principalID: principalID,
                            role: role,
                            nodeType: nodeType,
                            nodeID: nodeID
                        ),
                        existing: &existing,
                        on: db
                    )
                }
            }
        }

        if inserted > 0 {
            app.logger.info(
                "Role bindings backfilled from SpiceDB export",
                metadata: ["inserted": .string(String(inserted))])
        }
    }

    // MARK: - Helpers

    private static func key(_ binding: RoleBinding) -> String {
        "\(binding.principalType)|\(binding.principalID.uuidString)|\(binding.role)"
            + "|\(binding.nodeType)|\(binding.nodeID.uuidString)"
    }

    private static func existingKeys(on db: Database) async throws -> Set<String> {
        Set(try await RoleBinding.query(on: db).all().map(key))
    }

    private static func insertIfMissing(
        _ binding: RoleBinding, existing: inout Set<String>, on db: Database
    ) async throws -> Int {
        let bindingKey = key(binding)
        guard !existing.contains(bindingKey) else { return 0 }
        do {
            try await binding.save(on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Another replica's backfill inserted the same binding between our
            // key-set snapshot and this insert; the row exists, which is all
            // this backfill wants.
            existing.insert(bindingKey)
            return 0
        }
        existing.insert(bindingKey)
        return 1
    }
}
