import Fluent
import Foundation
import SQLKit
import StratoShared

/// Maintains the set of sites that must acknowledge each security-group
/// generation and derives the group's API-facing aggregate from those rows.
enum SecurityGroupSiteConvergence {
    private struct GroupIDRow: Decodable {
        let id: UUID
    }

    static func reconcileScopes(projectIDs: Set<UUID>, on db: any Database) async throws {
        for projectID in projectIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await db.transaction { tx in
                try await reconcileScopeInTransaction(projectID: projectID, on: tx)
            }
        }
    }

    static func reconcileScopeInTransaction(
        projectID: UUID, on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw ConvergenceWriteError.unsupportedDatabase
        }

        // Lock every group in a stable order. Observed reports take the same
        // row lock before updating one site's acknowledgement, so scope
        // changes and aggregate derivation cannot overwrite each other.
        let groups = try await sql.raw(
            """
            SELECT id
            FROM security_groups
            WHERE project_id = \(bind: projectID)
            ORDER BY id
            FOR UPDATE
            """
        ).all(decoding: GroupIDRow.self)
        guard !groups.isEmpty else { return }

        // A site's required set is the direct NIC attachments in that site,
        // expanded through remote-group rule references. UNION (not UNION ALL)
        // makes self-references and cycles finite.
        try await sql.raw(
            """
            WITH RECURSIVE direct(site_id, group_id) AS (
                SELECT DISTINCT agents.site_id, memberships.security_group_id
                FROM vm_interface_security_groups memberships
                JOIN security_groups groups ON groups.id = memberships.security_group_id
                JOIN vm_network_interfaces interfaces ON interfaces.id = memberships.interface_id
                JOIN vms ON vms.id = interfaces.vm_id
                JOIN agents ON lower(agents.id::text) = lower(vms.hypervisor_id)
                WHERE groups.project_id = \(bind: projectID)
                UNION
                SELECT DISTINCT agents.site_id, memberships.security_group_id
                FROM sandbox_interface_security_groups memberships
                JOIN security_groups groups ON groups.id = memberships.security_group_id
                JOIN sandbox_network_interfaces interfaces ON interfaces.id = memberships.interface_id
                JOIN sandboxes ON sandboxes.id = interfaces.sandbox_id
                JOIN agents ON lower(agents.id::text) = lower(sandboxes.hypervisor_id)
                WHERE groups.project_id = \(bind: projectID)
            ), required(site_id, group_id) AS (
                SELECT site_id, group_id FROM direct
                UNION
                SELECT required.site_id, rules.remote_group_id
                FROM required
                JOIN security_group_rules rules
                  ON rules.security_group_id = required.group_id
                JOIN security_groups groups ON groups.id = rules.remote_group_id
                WHERE rules.remote_group_id IS NOT NULL
                  AND groups.project_id = \(bind: projectID)
            ), removed AS (
                DELETE FROM security_group_site_observations observations
                USING security_groups groups
                WHERE observations.security_group_id = groups.id
                  AND groups.project_id = \(bind: projectID)
                  AND NOT EXISTS (
                      SELECT 1 FROM required
                      WHERE required.site_id = observations.site_id
                        AND required.group_id = observations.security_group_id
                  )
                RETURNING observations.id
            )
            INSERT INTO security_group_site_observations
                (id, security_group_id, site_id, observed_generation)
            SELECT gen_random_uuid(), required.group_id, required.site_id, 0
            FROM required
            ON CONFLICT (security_group_id, site_id) DO NOTHING
            """
        ).run()

        for row in groups {
            try await refreshAggregate(groupID: row.id, on: db)
        }
    }

    static func apply(
        _ observed: ObservedSecurityGroupState,
        siteID: UUID,
        on db: any Database
    ) async throws {
        try await db.transaction { tx in
            guard let txSQL = tx as? any SQLDatabase else {
                throw ConvergenceWriteError.unsupportedDatabase
            }
            let locked = try await txSQL.raw(
                "SELECT id FROM security_groups WHERE id = \(bind: observed.id) FOR UPDATE"
            ).all(decoding: GroupIDRow.self)
            guard !locked.isEmpty,
                let group = try await SecurityGroup.find(observed.id, on: tx),
                observed.observedGeneration <= group.generation,
                let siteObservation = try await SecurityGroupSiteObservation.query(on: tx)
                    .filter(\.$securityGroup.$id == observed.id)
                    .filter(\.$site.$id == siteID)
                    .first()
            else { return }

            if observed.status == .active {
                guard observed.observedGeneration >= siteObservation.observedGeneration else { return }
            } else {
                guard
                    observed.failedGeneration == group.generation
                        || observed.observedGeneration >= siteObservation.observedGeneration
                else { return }
            }

            let failureChanged =
                siteObservation.observedStatus != observed.status
                || siteObservation.lastError != observed.lastError
                || siteObservation.failedGeneration != observed.failedGeneration
                || siteObservation.observedFailureClassification != observed.failureClassification

            siteObservation.observedGeneration = max(
                siteObservation.observedGeneration, observed.observedGeneration)
            siteObservation.observedStatus = observed.status
            siteObservation.lastError = observed.status == .error ? observed.lastError : nil
            siteObservation.failedGeneration = observed.status == .error ? observed.failedGeneration : nil
            siteObservation.observedFailureClassification =
                observed.status == .error ? observed.failureClassification : nil
            if observed.status != .error {
                siteObservation.lastErrorAt = nil
            } else if failureChanged || siteObservation.lastErrorAt == nil {
                siteObservation.lastErrorAt = Date()
            }
            try await siteObservation.save(on: tx)
            try await refreshAggregate(groupID: observed.id, on: tx)
        }
    }

    /// The caller holds the security-group row lock.
    private static func refreshAggregate(groupID: UUID, on db: any Database) async throws {
        guard let group = try await SecurityGroup.find(groupID, on: db) else { return }
        let previousObservedGeneration = group.observedGeneration
        let previousConvergencePhase = group.convergencePhase
        let previousLastError = group.lastError
        let previousFailedGeneration = group.failedGeneration
        let previousLastErrorAt = group.lastErrorAt
        let previousConvergenceDeadline = group.convergenceDeadline
        let observations = try await SecurityGroupSiteObservation.query(on: db)
            .filter(\.$securityGroup.$id == groupID)
            .all()

        guard !observations.isEmpty else {
            group.convergencePhase = nil
            group.lastError = nil
            group.failedGeneration = nil
            group.lastErrorAt = nil
            group.convergenceDeadline = nil
            if aggregateChanged(
                group,
                observedGeneration: previousObservedGeneration,
                convergencePhase: previousConvergencePhase,
                lastError: previousLastError,
                failedGeneration: previousFailedGeneration,
                lastErrorAt: previousLastErrorAt,
                convergenceDeadline: previousConvergenceDeadline
            ) {
                try await group.save(on: db)
            }
            return
        }

        // This aggregate may decrease when a group enters an additional site:
        // the value is the minimum acknowledgement across the current site set,
        // not a single agent's monotonic cursor.
        group.observedGeneration = observations.map(\.observedGeneration).min() ?? 0
        let currentFailures = observations.filter {
            $0.observedStatus == .error
                && $0.failedGeneration == group.generation
                && $0.lastError != nil
        }.sorted {
            if $0.lastErrorAt != $1.lastErrorAt {
                return ($0.lastErrorAt ?? .distantPast) > ($1.lastErrorAt ?? .distantPast)
            }
            return $0.$site.id.uuidString < $1.$site.id.uuidString
        }

        group.convergencePhase = nil
        if let failure = currentFailures.first {
            group.lastError = failure.lastError
            group.failedGeneration = failure.failedGeneration
            group.lastErrorAt = failure.lastErrorAt
            if failure.observedFailureClassification != .blocked {
                group.convergenceDeadline = nil
            } else if group.convergenceDeadline == nil {
                group.convergenceDeadline = Date().addingTimeInterval(180)
            }
        } else {
            group.lastError = nil
            group.failedGeneration = nil
            group.lastErrorAt = nil
            let allActive = observations.allSatisfy {
                $0.observedStatus == .active
                    && $0.observedGeneration >= group.generation
            }
            if allActive {
                group.convergenceDeadline = nil
            } else if group.convergenceDeadline == nil {
                group.convergenceDeadline = Date().addingTimeInterval(180)
            }
        }
        if aggregateChanged(
            group,
            observedGeneration: previousObservedGeneration,
            convergencePhase: previousConvergencePhase,
            lastError: previousLastError,
            failedGeneration: previousFailedGeneration,
            lastErrorAt: previousLastErrorAt,
            convergenceDeadline: previousConvergenceDeadline
        ) {
            try await group.save(on: db)
        }
    }

    private static func aggregateChanged(
        _ group: SecurityGroup,
        observedGeneration: Int64,
        convergencePhase: String?,
        lastError: String?,
        failedGeneration: Int64?,
        lastErrorAt: Date?,
        convergenceDeadline: Date?
    ) -> Bool {
        group.observedGeneration != observedGeneration
            || group.convergencePhase != convergencePhase
            || group.lastError != lastError
            || group.failedGeneration != failedGeneration
            || group.lastErrorAt != lastErrorAt
            || group.convergenceDeadline != convergenceDeadline
    }
}
