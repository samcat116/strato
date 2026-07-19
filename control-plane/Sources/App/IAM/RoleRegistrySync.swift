import Fluent
import Foundation
import Vapor

/// Reconciles the `iam_roles` / `iam_role_actions` tables with the code-side
/// `IAMRoleRegistry` at boot. The code is the curated source of truth — an
/// action joins or leaves a role via a reviewed change to `RoleRegistry.swift`,
/// and this sync propagates it — so the tables are safe to rebuild
/// incrementally on every startup.
///
/// The registry is part of the policy set, so a sync that changes anything
/// cuts a policy-set version. Reconciliation and bump run in **one
/// transaction**: if they were separate, a deploy killed between them would
/// leave a changed registry with no version behind it, and the failure would
/// never repair itself — the next boot finds nothing left to reconcile and so
/// bumps nothing, while every replica keeps its stale compiled policy set.
enum RoleRegistrySync {
    static func sync(on db: Database, logger: Logger) async throws {
        try await PolicySetVersionService.withPolicySetChange(on: db) { transaction in
            try await reconcile(on: transaction, logger: logger)
        }
    }

    /// One reconciliation pass, inside the transaction.
    ///
    /// Concurrent boots are handled by the transaction retry rather than by
    /// swallowing constraint failures here: on Postgres a violated uniqueness
    /// constraint aborts the whole transaction, so catching it in place would
    /// only make every later statement fail. Letting it propagate re-runs the
    /// pass against a fresh transaction, where the other replica's row is
    /// visible and there is simply nothing left to insert.
    private static func reconcile(on db: Database, logger: Logger) async throws {
        // Roles: upsert by name, keeping `implies` current.
        let existingRoles = try await IAMRoleRecord.query(on: db).all()
        var rolesByName = [String: IAMRoleRecord]()
        for record in existingRoles {
            rolesByName[record.name] = record
        }
        // Any change here is a policy-set change: the role registry is part of
        // what the evaluator compiles, so replicas have to recompile.
        var roleChanges = 0
        for role in IAMRole.allCases {
            if let record = rolesByName[role.rawValue] {
                if record.implies != role.implies?.rawValue {
                    record.implies = role.implies?.rawValue
                    try await record.save(on: db)
                    roleChanges += 1
                }
            } else {
                try await IAMRoleRecord(name: role.rawValue, implies: role.implies?.rawValue).save(on: db)
                roleChanges += 1
            }
        }
        let knownRoles = Set(IAMRole.allCases.map(\.rawValue))
        for record in existingRoles where !knownRoles.contains(record.name) {
            try await record.delete(on: db)
            roleChanges += 1
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
                try await IAMRoleAction(role: role, action: action).save(on: db)
                inserted += 1
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
        guard inserted > 0 || removed > 0 || roleChanges > 0 else { return }

        logger.info(
            "IAM role registry synced",
            metadata: [
                "actions_added": .string(String(inserted)),
                "actions_removed": .string(String(removed)),
                "role_changes": .string(String(roleChanges)),
            ])

        // Bump after the tables are consistent, so a replica that reacts to the
        // new version reads the finished registry. A replica that finds nothing
        // to reconcile bumps nothing — so a rolling deploy of an unchanged
        // registry is silent, and the worst a simultaneous cold boot costs is a
        // few redundant invalidations of a policy set nobody has compiled yet.
        let version = try await PolicySetVersionService.bump(
            reason:
                "role registry synced (\(inserted) actions added, \(removed) removed, \(roleChanges) role changes)",
            on: db
        )
        logger.info("Policy set version bumped", metadata: ["version": .stringConvertible(version)])
    }
}
