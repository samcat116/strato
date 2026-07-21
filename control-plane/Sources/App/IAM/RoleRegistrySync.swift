import Fluent
import Foundation
import Vapor

/// Reconciles the seeded (managed) rows of `iam_roles` with the code-side
/// `IAMRoleRegistry` at boot. The code stays the curated source of truth for
/// the *defaults* — an action joins or leaves a seeded role via a reviewed
/// change to `RoleRegistry.swift`, and this sync propagates it — while
/// user-created rows (`managed == false`) are never touched: they are policy
/// data owned by their org or project.
///
/// The role store is part of the policy set, so a sync that changes anything
/// cuts a policy-set version. Reconciliation and bump run in **one
/// transaction**: if they were separate, a deploy killed between them would
/// leave changed rows with no version behind them, and the failure would
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
        let managed = try await IAMRoleDefinition.query(on: db)
            .filter(\.$managed == true)
            .all()
        var byID = [UUID: IAMRoleDefinition]()
        for row in managed {
            if let id = row.id { byID[id] = row }
        }

        var changes = 0
        for desired in RoleDescriptor.seededDefaults() {
            if let row = byID[desired.id] {
                if row.name != desired.name || row.cedarText != desired.cedarText || row.actions != desired.actions {
                    row.name = desired.name
                    row.cedarText = desired.cedarText
                    row.actions = desired.actions
                    try await row.save(on: db)
                    changes += 1
                }
            } else {
                let row = IAMRoleDefinition(
                    id: desired.id,
                    name: desired.name,
                    ownerType: .platform,
                    ownerID: IAMRoleDefinition.platformOwnerID,
                    cedarText: desired.cedarText,
                    actions: desired.actions,
                    managed: true
                )
                try await row.create(on: db)
                changes += 1
            }
        }

        // A managed row whose id the code no longer seeds is a default that
        // was removed by an upgrade.
        for row in managed {
            guard let id = row.id, IAMRole(seededID: id) == nil else { continue }
            try await row.delete(on: db)
            changes += 1
        }

        guard changes > 0 else { return }

        logger.info(
            "IAM seeded roles synced",
            metadata: ["changes": .string(String(changes))])

        // Bump after the rows are consistent, so a replica that reacts to the
        // new version reads the finished store. A replica that finds nothing
        // to reconcile bumps nothing — so a rolling deploy of an unchanged
        // registry is silent, and the worst a simultaneous cold boot costs is
        // a few redundant invalidations of a policy set nobody has compiled
        // yet.
        let version = try await PolicySetVersionService.bump(
            reason: "seeded roles synced (\(changes) changes)",
            on: db
        )
        logger.info("Policy set version bumped", metadata: ["version": .stringConvertible(version)])
    }
}
