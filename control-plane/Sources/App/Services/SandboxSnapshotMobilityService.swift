import Fluent
import Foundation
import StratoShared
import Vapor

/// Object-store keys for exported sandbox snapshot artifacts (issue #428).
///
/// The `sandbox-snapshots/` namespace keeps snapshot objects disjoint from
/// image objects, whose keys start with a bare project UUID. Filenames come
/// from `SandboxSnapshotArtifactKind.filename`, matching the agent-side
/// archive layout, so an exported prefix is a byte-for-byte mirror of the
/// on-agent snapshot directory.
enum SandboxSnapshotObjectKey {
    static let namespace = "sandbox-snapshots"

    static func artifact(projectId: UUID, snapshotId: UUID, kind: SandboxSnapshotArtifactKind) -> String {
        "\(snapshotPrefix(projectId: projectId, snapshotId: snapshotId))/\(kind.filename)"
    }

    /// Every object belonging to one exported snapshot.
    static func snapshotPrefix(projectId: UUID, snapshotId: UUID) -> String {
        "\(namespace)/\(projectId)/\(snapshotId)"
    }
}

/// Cross-agent placement rules for snapshot restore and fork (issue #428).
///
/// Firecracker snapshots are tied to the Firecracker build, CPU architecture,
/// and guest-visible CPU features they were captured under, so a restore on a
/// different host must match all three — and the guest CPU surface is only
/// known to match when the snapshot was captured under a CPU template, or
/// when both hosts report an identical CPU model. Every check treats missing
/// information as incompatible: guessing here produces a guest that crashes
/// on the first unsupported instruction.
enum SandboxSnapshotCompatibility {
    /// Whether `agent` can load `snapshot`, with a human-actionable reason
    /// when it cannot. The agent must also speak wire v13 (it has to act on
    /// the download descriptors) — callers check online/capability state
    /// separately because they source it from the live agent registry, not
    /// the row.
    static func restoreBlocker(snapshot: SandboxSnapshot, target agent: Agent) -> String? {
        guard WireProtocol.supportsSandboxSnapshotMobility(agent.wireProtocolVersion ?? 0) else {
            return
                "agent '\(agent.name)' is too old for snapshot mobility (wire protocol \(agent.wireProtocolVersion ?? 0), need >= \(WireProtocol.sandboxSnapshotMobilityMinimumVersion))"
        }
        guard let snapshotArch = snapshot.architecture else {
            return "snapshot records no CPU architecture"
        }
        guard agent.architecture == snapshotArch else {
            return
                "snapshot was taken on \(snapshotArch) but agent '\(agent.name)' is \(agent.architecture ?? "of unknown architecture")"
        }
        guard let snapshotFirecracker = normalizedFirecrackerVersion(snapshot.firecrackerVersion) else {
            return "snapshot records no Firecracker version"
        }
        let agentFirecracker = normalizedFirecrackerVersion(
            agent.hypervisors.first { $0.type == .firecracker && $0.available }?.version)
        guard let agentFirecracker else {
            return "agent '\(agent.name)' reports no Firecracker version"
        }
        guard agentFirecracker == snapshotFirecracker else {
            return
                "snapshot needs Firecracker \(snapshotFirecracker) but agent '\(agent.name)' runs \(agentFirecracker)"
        }
        // Guest CPU surface: a template pins it; without one, only an
        // identical CPU model is known-safe.
        if snapshot.cpuTemplate == nil {
            guard let sourceModel = snapshot.sourceCPUModel,
                let targetModel = agent.hostInfo?.cpuModel,
                sourceModel == targetModel
            else {
                return
                    "snapshot was taken without a CPU template, so it only restores on an identical CPU (source: \(snapshot.sourceCPUModel ?? "unknown"), agent '\(agent.name)': \(agent.hostInfo?.cpuModel ?? "unknown")). Create sandboxes with a cpuTemplate to make their snapshots portable"
            }
        }
        return nil
    }

    /// Firecracker prints "Firecracker v1.7.0" but reports `vmm_version`
    /// "1.7.0"; compare without the cosmetic prefix.
    static func normalizedFirecrackerVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
    }
}

extension SandboxSnapshot {
    /// The control-plane-relative transfer path for one artifact — the same
    /// route serves agent uploads (PUT, during export) and downloads (GET,
    /// during cross-agent restore/fork), both authenticated by the agent's
    /// SVID over mTLS (the v13 image-download model, issue #493).
    static func artifactTransferPath(
        sandboxId: UUID, snapshotId: UUID, kind: SandboxSnapshotArtifactKind
    ) -> String {
        "/api/sandboxes/\(sandboxId.uuidString)/snapshots/\(snapshotId.uuidString)/artifacts/\(kind.rawValue)"
    }

    /// Download descriptors for this snapshot's exported artifacts:
    /// control-plane-relative paths plus the integrity material recorded when
    /// the export streamed through the control plane. Nothing here expires or
    /// is signed — the fetching agent authenticates with its SVID — so the
    /// descriptors are stable across syncs. Returns nil unless the export is
    /// complete.
    func exportedArtifactDescriptors() throws -> [SandboxSnapshotArtifactDescriptor]? {
        guard isExported, let exportedArtifacts else { return nil }
        let sandboxID = self.$sandbox.id
        let snapshotID = try requireID()
        return exportedArtifacts.map { artifact in
            SandboxSnapshotArtifactDescriptor(
                kind: artifact.kind,
                downloadURL: Self.artifactTransferPath(
                    sandboxId: sandboxID, snapshotId: snapshotID, kind: artifact.kind),
                sizeBytes: artifact.sizeBytes,
                sha256: artifact.sha256)
        }
    }

    /// Best-effort removal of this snapshot's exported objects. Failures are
    /// logged, not thrown: every caller sits on a deletion path where the row
    /// (or its sandbox) is already going away, and an orphaned object under a
    /// deterministic prefix is re-deletable by hand while a failed deletion
    /// would strand the user-visible operation.
    func deleteExportedObjects(app: Application) async {
        guard exportedArtifacts?.isEmpty == false || exportedAt != nil else { return }
        guard let snapshotID = id else { return }
        let prefix = SandboxSnapshotObjectKey.snapshotPrefix(
            projectId: self.$project.id, snapshotId: snapshotID)
        do {
            try await app.imageObjectStore.deletePrefix(prefix)
        } catch {
            app.logger.warning(
                "Failed to delete exported snapshot objects; they are orphaned under a deterministic prefix",
                metadata: [
                    "snapshot_id": .string(snapshotID.uuidString),
                    "prefix": .string(prefix),
                    "error": .string(error.localizedDescription),
                ])
        }
    }
}
