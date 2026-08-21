import ControlPlanePostgres
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
    private static let platformOwnerID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    static func sync(using iam: IAMPersistence, logger: Logger) async throws {
        try await iam.withPolicySetChange { transaction in
            try await reconcile(in: transaction, logger: logger)
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
    private static func reconcile(
        in transaction: IAMPolicySetTransaction,
        logger: Logger
    ) async throws {
        let managed = try await transaction.allRoles().filter(\.managed)
        let byID = Dictionary(uniqueKeysWithValues: managed.map { ($0.id, $0) })

        var changes = 0
        for desired in RoleDescriptor.seededDefaults() {
            if let row = byID[desired.id] {
                if row.name != desired.name || row.cedarText != desired.cedarText || row.actions != desired.actions {
                    _ = try await transaction.reconcileManagedRole(
                        IAMRoleSnapshot(
                            id: row.id,
                            name: desired.name,
                            description: row.description,
                            ownerType: row.ownerType,
                            ownerID: row.ownerID,
                            cedarText: desired.cedarText,
                            actions: desired.actions,
                            managed: true,
                            createdBy: row.createdBy,
                            createdAt: row.createdAt,
                            updatedAt: row.updatedAt
                        )
                    )
                    changes += 1
                }
            } else {
                _ = try await transaction.reconcileManagedRole(
                    IAMRoleSnapshot(
                    id: desired.id,
                    name: desired.name,
                    description: nil,
                    ownerType: IAMRoleOwnerType.platform.rawValue,
                    ownerID: platformOwnerID,
                    cedarText: desired.cedarText,
                    actions: desired.actions,
                    managed: true,
                    createdBy: nil
                    )
                )
                changes += 1
            }
        }

        // A managed row whose id the code no longer seeds is a default that
        // was removed by an upgrade.
        for row in managed {
            guard IAMRole(seededID: row.id) == nil else { continue }
            _ = try await transaction.deleteRole(id: row.id)
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
        let version = try await transaction.bumpPolicySetVersion(
            reason: "seeded roles synced (\(changes) changes)",
        )
        logger.info("Policy set version bumped", metadata: ["version": .stringConvertible(version)])
    }
}
