import Fluent
import Foundation
import StratoShared
import Vapor

/// Admission for the destructive, full-list side of observed-state ingestion.
/// Agent-supplied completeness is necessary but cannot authorize mass loss.
struct ObservedInventoryGuard {
    enum Section: String, Hashable, Sendable {
        case workloads, volumes, snapshots
    }

    struct Counts: Sendable {
        var placed = 0
        var destructiveAbsences = 0
    }

    let minimumResources: Int
    let percentOfPlaced: Int
    let allowBulkLoss: Bool

    init(configuration: ControlPlaneConfiguration) {
        minimumResources = configuration.int(.observedInventoryMinimumResources)
        percentOfPlaced = configuration.int(.observedInventoryPercentOfPlaced)
        allowBulkLoss = configuration.bool(.observedInventoryAllowBulkLoss)
    }

    func refusal(counts: [Section: Counts], acceptedSections: Set<Section>) -> String? {
        guard !allowBulkLoss else { return nil }
        let destructive = counts.values.reduce(0) { $0 + $1.destructiveAbsences }
        let placed = counts.values.reduce(0) { $0 + $1.placed }
        guard destructive > 0 else { return nil }
        let unproven = counts.keys.filter {
            !acceptedSections.contains($0) && counts[$0]!.destructiveAbsences > 0
        }.map(\.rawValue).sorted()
        let cause: String
        if !unproven.isEmpty {
            cause = "first authoritative inventory after registration for \(unproven.joined(separator: ", "))"
        } else {
            guard destructive > minimumResources,
                Double(destructive) / Double(max(1, placed)) > Double(percentOfPlaced) / 100
            else { return nil }
            cause = "more than \(minimumResources) resources and \(percentOfPlaced)% of placed resources"
        }
        return
            "Control-plane inventory guard refused \(destructive) destructive absences among \(placed) placed resources: "
            + cause + ". No workload or storage observations from this report were applied. "
            + "Restore the host inventory or verify the loss before temporarily setting OBSERVED_INVENTORY_ALLOW_BULK_LOSS=true."
    }

    /// Count only authoritative sections. Nil storage lists cannot establish a
    /// baseline, dilute the percentage, or imply deletion. Pending creates do
    /// not assert presence and therefore are not treated as lost resources.
    static func counts(for report: ObservedStateReport, on db: any Database) async throws -> [Section: Counts] {
        let vms = try await VM.query(on: db).filter(\.$hypervisorId == report.agentId).all()
        let sandboxes = try await Sandbox.query(on: db).filter(\.$hypervisorId == report.agentId).all()
        let establishedVMs = vms.filter { $0.isTerminating || $0.status.assertsAgentPresence }
        let establishedSandboxes = sandboxes.filter {
            $0.isTerminating || ($0.observedGeneration > 0 && $0.status.assertsAgentPresence)
        }
        let vmIDs = Set(report.vms.map(\.vmId))
        let sandboxIDs = Set(report.sandboxes.map(\.sandboxId))
        var counts: [Section: Counts] = [
            .workloads: Counts(
                placed: establishedVMs.count + establishedSandboxes.count,
                destructiveAbsences: establishedVMs.filter { isAbsent($0.id, from: vmIDs) }.count
                    + establishedSandboxes.filter { isAbsent($0.id, from: sandboxIDs) }.count)
        ]
        if let observations = report.volumes {
            let ids = Set(observations.map(\.volumeId))
            let volumes = try await VolumeService.volumes(onAgent: report.agentId, on: db)
            let established = volumes.filter { $0.isTerminating || ($0.observedGeneration > 0 && $0.status != .error) }
            counts[.volumes] = Counts(
                placed: established.count,
                destructiveAbsences: established.filter { isAbsent($0.id, from: ids) }.count)
        }
        if let observations = report.snapshots {
            let ids = Set(observations.map(\.snapshotId))
            var snapshots = Counts()
            func include<A: SnapshotArtifactResource>(_ artifacts: [A]) {
                let established = artifacts.filter {
                    $0.isTerminating || ($0.observedGeneration > 0 && $0.isPresentOnAgent)
                }
                snapshots.placed += established.count
                snapshots.destructiveAbsences += established.filter { isAbsent($0.id, from: ids) }.count
            }
            include(try await VolumeSnapshot.placed(onAgent: report.agentId, on: db))
            include(try await VMSnapshot.placed(onAgent: report.agentId, on: db))
            include(try await SandboxSnapshot.placed(onAgent: report.agentId, on: db))
            counts[.snapshots] = snapshots
        }
        return counts
    }

    private static func isAbsent(_ id: UUID?, from reported: Set<UUID>) -> Bool {
        id.map { !reported.contains($0) } ?? false
    }
}

extension AgentService {
    /// Reset per connection. A replica restart also starts with no accepted
    /// baseline; losing coordination must never authorize deletion.
    func beginObservedInventorySession(for agentKey: String) {
        observedInventorySessions[agentKey] = UUID()
        acceptedInventorySections.removeValue(forKey: agentKey)
    }

    func endObservedInventorySession(for agentKey: String) {
        observedInventorySessions.removeValue(forKey: agentKey)
        acceptedInventorySections.removeValue(forKey: agentKey)
    }
}
