import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

/// Owns exported snapshot transfer, import caching, and cross-agent restore staging.
extension FirecrackerSandboxRuntime {
    // MARK: - Snapshot mobility (issue #428)

    /// Root of the import cache: exported archives staged onto this host for
    /// cross-agent restore and fork, one directory per snapshot id. A cache,
    /// not an archive — entries re-download from object storage, so it is
    /// LRU-swept against the same byte budget as the warm-snapshot cache.
    var snapshotImportRoot: String { sandboxStoragePath + "/snapshot-imports" }

    func snapshotImportDirectory(_ snapshotId: String) -> String {
        snapshotImportRoot + "/" + snapshotId
    }

    func exportSandboxSnapshot(
        sandboxId: String, snapshotId: String,
        uploads: [SandboxSnapshotArtifactUploadTarget]
    ) async throws {
        // Export reads only the host-owned archive: the control plane only
        // asks the agent that took the snapshot. The files are immutable
        // after capture, so a running guest needs no pause here.
        let archiveDir = snapshotDirectory(sandboxId, snapshotId: snapshotId)
        for kind in SandboxSnapshotArtifactKind.allCases {
            guard FileManager.default.fileExists(atPath: archiveDir + "/" + kind.filename) else {
                throw SandboxRuntimeError.snapshotNotFound(sandboxId: sandboxId, snapshotId: snapshotId)
            }
        }
        guard let transfer = snapshotTransfer else {
            throw SandboxRuntimeError.snapshotIOFailed(
                "snapshot export requires the SPIFFE mTLS transfer client, which this agent does not have"
            )
        }
        // Sequential by contract: the control plane records each artifact's
        // integrity entry with a read-modify-write on the snapshot row, so
        // concurrent PUTs could drop entries and fail the export closed.
        for kind in SandboxSnapshotArtifactKind.allCases {
            guard let target = uploads.first(where: { $0.kind == kind }) else {
                throw SandboxRuntimeError.snapshotIOFailed(
                    "export request is missing an upload target for artifact '\(kind.rawValue)'")
            }
            do {
                try await transfer.upload(
                    filePath: archiveDir + "/" + kind.filename, to: target.uploadURL, kind: kind)
            } catch {
                throw SandboxRuntimeError.snapshotIOFailed(error.localizedDescription)
            }
        }
        logger.info(
            "Sandbox snapshot exported to object storage",
            metadata: ["sandboxId": .string(sandboxId), "snapshotId": .string(snapshotId)])
    }

    /// Resolve a snapshot's archive directory for restore/fork: the
    /// sandbox-owned archive when this host holds it, otherwise the import
    /// cache — staging a verified download of the exported copy when
    /// `artifacts` descriptors were provided. Every returned directory holds
    /// all four artifacts.
    func stageSnapshotArchive(
        sourceSandboxId: String, snapshotId: String,
        artifacts: [SandboxSnapshotArtifactDescriptor]?
    ) async throws -> String {
        func holdsCompleteArchive(_ directory: String) -> Bool {
            SandboxSnapshotArtifactKind.allCases.allSatisfy {
                FileManager.default.fileExists(atPath: directory + "/" + $0.filename)
            }
        }

        let localDir = snapshotDirectory(sourceSandboxId, snapshotId: snapshotId)
        if holdsCompleteArchive(localDir) {
            return localDir
        }
        let importDir = snapshotImportDirectory(snapshotId)
        if holdsCompleteArchive(importDir) {
            // Mark the entry used so LRU ordering sees cache hits.
            DiskCacheLRU.touch(entryDirectory: importDir)
            return importDir
        }
        guard let artifacts else {
            throw SandboxRuntimeError.snapshotNotFound(
                sandboxId: sourceSandboxId, snapshotId: snapshotId)
        }
        guard let transfer = snapshotTransfer else {
            throw SandboxRuntimeError.snapshotIOFailed(
                "restoring an exported snapshot requires the SPIFFE mTLS transfer client, which this agent does not have"
            )
        }

        if let inFlight = snapshotImportsInFlight[snapshotId] {
            try await inFlight.value
            guard holdsCompleteArchive(importDir) else {
                throw SandboxRuntimeError.snapshotIOFailed(
                    "imported snapshot archive vanished after download")
            }
            return importDir
        }

        guard snapshotImportsInFlight.count < Self.maxConcurrentSnapshotImports else {
            throw SandboxRuntimeError.snapshotIOFailed(
                "\(snapshotImportsInFlight.count) snapshot imports are already in flight on this host; retry once one completes"
            )
        }

        // Make room before pulling multi-gigabyte files in; the fresh entry
        // itself is protected by the sweep's grace window afterwards. The
        // reservation covers every concurrent import, not just this one.
        let incoming = artifacts.reduce(Int64(0)) { $0 + $1.sizeBytes }
        sweepSnapshotImports(incomingBytes: incoming + snapshotImportBytesInFlight)
        snapshotImportBytesInFlight += incoming

        let downloadLogger = logger
        let task = Task {
            for kind in SandboxSnapshotArtifactKind.allCases {
                guard let descriptor = artifacts.first(where: { $0.kind == kind }) else {
                    throw SandboxRuntimeError.snapshotIOFailed(
                        "restore descriptors are missing artifact '\(kind.rawValue)'")
                }
                downloadLogger.info(
                    "Downloading exported snapshot artifact",
                    metadata: [
                        "snapshotId": .string(snapshotId),
                        "kind": .string(kind.rawValue),
                        "sizeBytes": .stringConvertible(descriptor.sizeBytes),
                    ])
                try await transfer.download(descriptor, to: importDir + "/" + kind.filename)
            }
        }
        snapshotImportsInFlight[snapshotId] = task
        defer {
            snapshotImportsInFlight[snapshotId] = nil
            snapshotImportBytesInFlight -= incoming
        }
        do {
            try await task.value
        } catch let error as SandboxRuntimeError {
            discardPartialImport(importDir)
            throw error
        } catch {
            discardPartialImport(importDir)
            throw SandboxRuntimeError.snapshotIOFailed(error.localizedDescription)
        }
        return importDir
    }

    /// Drop a partially downloaded import. Without this the artifacts that
    /// did land stay forever: nothing else removes them, and they are only
    /// reclaimed if some *later* import happens to pick them as an LRU victim
    /// — so a host that takes one failed cross-agent restore and no more
    /// imports strands those bytes permanently (issue #428 review). Safe
    /// because this only runs once the download task has finished failing,
    /// and a concurrent fork of the same snapshot awaits that same task.
    func discardPartialImport(_ importDir: String) {
        try? FileManager.default.removeItem(atPath: importDir)
    }

    /// LRU sweep of the import cache, sharing the warm cache's byte budget:
    /// both hold re-creatable snapshot bytes, and neither is accounted
    /// against control-plane storage quota.
    ///
    /// "Sharing" has to mean net of what the warm cache already occupies. The
    /// two live under different roots, and sweeping each against the full
    /// `warmCacheBudgetBytes` independently made the real steady-state ceiling
    /// twice the configured number (issue #428 review). Warm templates take
    /// priority within the shared budget — rebuilding one costs a full cold
    /// boot, while an evicted import only costs a re-download.
    func sweepSnapshotImports(incomingBytes: Int64) {
        let root = snapshotImportRoot
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        let warmBytes = DiskCacheLRU.directorySize(atPath: warmCache.rootPath)
        DiskCacheLRU.sweep(
            entryDirectories: names.map { root + "/" + $0 },
            budgetBytes: max(0, warmCacheBudgetBytes - warmBytes),
            incomingBytes: incomingBytes,
            logger: logger)
    }

    /// Undo a pause whose request failed after reaching any of the vCPUs.
    ///
    /// Entirely best effort, and deliberately silent about everything except
    /// the case it exists for: the caller is already throwing the error that
    /// matters, and a guest this cannot reach is a guest the next status poll
    /// will report on. What it must not do is leave a workload the operator
    /// never asked to stop wedged at a pause nothing will lift.
    ///
    /// Firecracker's instance-level state cannot answer whether this is needed:
    /// it remains `Running` when one vCPU fails to acknowledge even though the
    /// others may already be paused. `recoverFromFailedPause()` consequently
    /// bypasses the manager's ordinary `.paused` guard and broadcasts the
    /// idempotent `Resumed` transition. The call is best effort because the
    /// original checkpoint error remains the operation's result.
    func resumeAfterFailedPause(managed: Managed, sandboxId: String) async {
        logger.warning(
            "Sandbox pause reported failure; resuming every vCPU defensively",
            metadata: ["sandboxId": .string(sandboxId)])
        do {
            try await managed.manager.recoverFromFailedPause()
        } catch {
            logger.error(
                "Could not confirm recovery from a failed sandbox pause",
                metadata: [
                    "sandboxId": .string(sandboxId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    /// Write a paused microVM's memory + vmstate to the given host paths.
    /// Jailed, Firecracker can only write inside its chroot, so the files are
    /// staged in the in-jail snapshot directory and moved out; unjailed they
    /// are written directly. Shared between sandbox checkpoints and warm
    /// template builds (issue #426).
    func captureSnapshot(
        manager: FirecrackerManager, jail: SandboxJailPlan?,
        memoryTarget: String, vmstateTarget: String
    ) async throws {
        if let plan = jail {
            let stagingHost = plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail)
            try? FileManager.default.removeItem(atPath: stagingHost)
            try FileManager.default.createDirectory(
                atPath: stagingHost, withIntermediateDirectories: true)
            try chownPath(stagingHost, uid: plan.uid, gid: plan.gid)
            try await manager.createSnapshot(
                SnapshotCreateConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail))
            try moveReplacingItem(
                from: plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail),
                to: memoryTarget)
            try moveReplacingItem(
                from: plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail),
                to: vmstateTarget)
            try? FileManager.default.removeItem(atPath: stagingHost)
        } else {
            try await manager.createSnapshot(
                SnapshotCreateConfig(
                    snapshotPath: vmstateTarget,
                    memFilePath: memoryTarget))
        }
    }
}

#endif
