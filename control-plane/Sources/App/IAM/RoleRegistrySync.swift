import Fluent
import Foundation
import Vapor

/// Reconciles the `iam_roles` / `iam_role_actions` tables with the code-side
/// `IAMRoleRegistry` at boot. The code is the curated source of truth — an
/// action joins or leaves a role via a reviewed change to `RoleRegistry.swift`,
/// and this sync propagates it — so the tables are safe to rebuild
/// incrementally on every startup.
enum RoleRegistrySync {
    static func sync(on db: Database, logger: Logger) async throws {
        // Roles: upsert by name, keeping `implies` current.
        let existingRoles = try await IAMRoleRecord.query(on: db).all()
        var rolesByName = [String: IAMRoleRecord]()
        for record in existingRoles {
            rolesByName[record.name] = record
        }
        for role in IAMRole.allCases {
            if let record = rolesByName[role.rawValue] {
                if record.implies != role.implies?.rawValue {
                    record.implies = role.implies?.rawValue
                    try await record.save(on: db)
                }
            } else {
                do {
                    try await IAMRoleRecord(name: role.rawValue, implies: role.implies?.rawValue).save(on: db)
                } catch let error as any DatabaseError where error.isConstraintFailure {
                    // Another replica booting concurrently inserted this role;
                    // the reconciled end state is identical.
                }
            }
        }
        let knownRoles = Set(IAMRole.allCases.map(\.rawValue))
        for record in existingRoles where !knownRoles.contains(record.name) {
            try await record.delete(on: db)
        }

        // Actions: rows mirror each role's *expanded* action group. Insert
        // what's missing, delete what the registry no longer contains.
        let existingActions = try await IAMRoleAction.query(on: db).all()
        var existingByRole = [String: Set<String>]()
        for record in existingActions {
            existingByRole[record.role, default: []].insert(record.action)
        }
        var inserted = 0
        var removed = 0
        for role in IAMRole.allCases {
            let desired = IAMRoleRegistry.actions(for: role)
            let current = existingByRole[role.rawValue] ?? []
            for action in desired.subtracting(current) {
                do {
                    try await IAMRoleAction(role: role, action: action).save(on: db)
                    inserted += 1
                } catch let error as any DatabaseError where error.isConstraintFailure {
                    // Concurrent boot already inserted this (role, action) row.
                }
            }
            let stale = current.subtracting(desired)
            if !stale.isEmpty {
                try await IAMRoleAction.query(on: db)
                    .filter(\.$role == role.rawValue)
                    .filter(\.$action ~~ Array(stale))
                    .delete()
                removed += stale.count
            }
        }
        for record in existingActions where !knownRoles.contains(record.role) {
            try await record.delete(on: db)
            removed += 1
        }
        if inserted > 0 || removed > 0 {
            logger.info(
                "IAM role registry synced",
                metadata: [
                    "actions_added": .string(String(inserted)),
                    "actions_removed": .string(String(removed)),
                ])
        }
    }
}
