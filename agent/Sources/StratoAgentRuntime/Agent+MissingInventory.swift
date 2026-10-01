import Foundation
import StratoAgentCore
import StratoShared

extension Agent {
    func quarantineMissingManifest(_ reason: String) {
        let failure = ManifestReadFailure(path: manifestStore.path, reason: reason, preservedCopyPath: nil)
        if manifestReadFailure != failure {
            logger.warning(
                "Missing workload manifest; host inventory is unproven",
                metadata: ["inventoryState": "absent", "reason": .string(reason)])
        }
        manifestReadFailure = failure
    }

    /// Registration's baseline must remain blind until BOTH sides corroborate
    /// emptiness. Host probes alone miss an unmounted volume (and shared RBD
    /// artifacts); desired state alone misses surviving, untracked processes.
    func verifyMissingInventories(using desired: DesiredStateMessage) async {
        guard manifestAbsent || snapshotInventoryAbsent, !verifyingMissingInventory else { return }
        verifyingMissingInventory = true
        defer { verifyingMissingInventory = false }

        // A late mount or operator restoration takes precedence over bootstrap.
        if manifestAbsent {
            let load = manifestStore.load()
            if case .absent = load {} else { await applyManifestLoad(load) }
        }
        if snapshotInventoryAbsent {
            let load = snapshotRecordStore.load()
            if case .absent = load {} else { applySnapshotInventory(load) }
        }

        if manifestAbsent {
            guard desired.vms.isEmpty, desired.sandboxes.isEmpty, desired.volumes.isEmpty,
                desired.snapshots.isEmpty, desired.tombstones.isEmpty
            else {
                quarantineMissingManifest(
                    "is missing but the control plane still has workloads, volumes, snapshots or tombstones for this host"
                )
                return
            }
            do {
                try await verifyEmptyHost()
            } catch {
                quarantineMissingManifest("is missing; empty-host verification failed: \(error.localizedDescription)")
                return
            }
            // Probes suspend this actor. A state volume may have mounted while
            // they ran; recover its bytes rather than initializing over them.
            if manifestAbsent {
                let latest = manifestStore.load()
                if case .absent = latest {
                    await applyManifestLoad(.fresh)
                    // Make this proof durable before the scheduler can place
                    // work. A later restart must not have to infer freshness
                    // from a pending first create in desired state.
                    guard persistManifest() else {
                        manifestAbsent = true
                        quarantineMissingManifest("is missing; could not persist the verified empty inventory")
                        return
                    }
                    logger.info("Missing workload manifest corroborated by empty host and control-plane inventories")
                } else {
                    await applyManifestLoad(latest)
                }
            }
        }

        // Older hosts may never have captured a snapshot. Do not infer that
        // from a missing file: a full desired sync must first confirm there
        // are no snapshot rows (including pending deletions) to preserve.
        // With an unknown workload inventory we cannot safely capture either.
        if snapshotInventoryAbsent, manifestReadFailure == nil, desired.snapshots.isEmpty {
            let latest = snapshotRecordStore.load()
            if case .absent = latest {
                guard snapshotRecordStore.save([:]) else { return }
                applySnapshotInventory(.fresh)
                logger.info("Missing snapshot records corroborated by the control plane: no snapshots placed here")
            } else {
                applySnapshotInventory(latest)
            }
        }
    }

    private func verifyEmptyHost() async throws {
        guard managedVMs.isEmpty, orphanedVMs.isEmpty, managedSandboxes.isEmpty,
            orphanedSandboxes.isEmpty, quarantinedWorkloads.isEmpty
        else { throw MissingInventoryEvidence("the agent already knows workloads on this host") }

        // QEMU inventories come from libvirt, including inactive domains. A
        // Firecracker driver's in-memory reservation map cannot prove absence
        // across restarts, so real Firecracker uses the process/filesystem
        // check below instead. Simulation has no surviving host processes.
        let types: [HypervisorType] = isSimulationMode ? HypervisorType.allCases : [.qemu]
        var needsLibvirtFilesystemProof = false
        for type in types {
            guard let ids = await hypervisorServices[type]?.bootstrapWorkloadIDs() else {
                if !isSimulationMode, type == .qemu {
                    // Firecracker-only nodes need no libvirt daemon. Its absence
                    // is not proof, but empty system domain/state directories
                    // AND a process sweep can independently corroborate it.
                    needsLibvirtFilesystemProof = true
                    continue
                }
                throw MissingInventoryEvidence("\(type.rawValue) inventory is unavailable")
            }
            guard ids.isEmpty else {
                throw MissingInventoryEvidence("\(type.rawValue) still holds \(ids.sorted().joined(separator: ", "))")
            }
        }
        guard let storageBackends else { throw MissingInventoryEvidence("storage inventory is unavailable") }
        let volumes = try await storageBackends.localInventory()
        guard volumes.isEmpty else {
            throw MissingInventoryEvidence("local storage still holds \(volumes.count) volume(s)")
        }
        if !isSimulationMode {
            try MissingInventoryHostProbe.verify(
                vmStoragePath: configuration.vmStoragePath,
                socketDirectory: configuration.firecrackerSocketDir,
                jailDirectory: configuration.sandboxJailerChrootDir,
                firecrackerBinaryPath: configuration.firecrackerBinaryPath,
                needsLibvirtFilesystemProof: needsLibvirtFilesystemProof)
        }
    }
}

struct MissingInventoryEvidence: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// Conservative startup-only evidence. Stale artifacts require inspection;
/// failed enumeration is never an empty inventory. Kept separate so tests can
/// model lost manifests and surviving processes without launching a guest.
enum MissingInventoryHostProbe {
    static func verify(
        vmStoragePath: String, socketDirectory: String, jailDirectory: String,
        firecrackerBinaryPath: String, procDirectory: String = "/proc",
        needsLibvirtFilesystemProof: Bool = false,
        libvirtConfigurationDirectory: String = "/etc/libvirt/qemu",
        libvirtStateDirectory: String = "/var/lib/libvirt/qemu"
    ) throws {
        if needsLibvirtFilesystemProof {
            // The shipping driver uses qemu:///system. Network definitions do
            // not name domains; every other surviving config/state artifact
            // withholds bootstrap, including inactive and autostart domains.
            for name in try children(libvirtConfigurationDirectory) where name != "networks" {
                try requireEmptyTree((libvirtConfigurationDirectory as NSString).appendingPathComponent(name))
            }
            for name in try children(libvirtStateDirectory) {
                try requireEmptyTree((libvirtStateDirectory as NSString).appendingPathComponent(name))
            }
        }
        for path in [socketDirectory, jailDirectory] {
            guard try children(path).isEmpty else {
                throw MissingInventoryEvidence("surviving Firecracker artifacts at \(path)")
            }
        }
        let bookkeeping: Set<String> = ["vm-manifest.json", "snapshot-records.json", "instance-metadata.json"]
        for name in try children(vmStoragePath) where !bookkeeping.contains(name) {
            let path = (vmStoragePath as NSString).appendingPathComponent(name)
            // An empty jail root can be created during runtime initialization.
            if path == jailDirectory, try children(path).isEmpty { continue }
            throw MissingInventoryEvidence("unaccounted workload artifact at \(path)")
        }
        #if os(Linux)
        let binaryName = (firecrackerBinaryPath as NSString).lastPathComponent
        // /proc itself is mandatory: unlike an absent artifact directory, a
        // missing process inventory cannot establish emptiness.
        for pid in try FileManager.default.contentsOfDirectory(atPath: procDirectory) where Int(pid) != nil {
            let path = "\(procDirectory)/\(pid)/cmdline"
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch CocoaError.fileReadNoSuchFile {
                continue  // The process exited during the sweep.
            }
            let args = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            guard let command = args.first else { continue }  // Kernel thread.
            let name = (command as NSString).lastPathComponent
            if name == binaryName || name == "firecracker" || name == "jailer" || args.contains("--api-sock")
                || name.hasPrefix("qemu-system-") || name == "qemu-kvm"
            {
                throw MissingInventoryEvidence("surviving hypervisor/jailer process \(pid)")
            }
        }
        #endif
    }

    private static func requireEmptyTree(_ path: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MissingInventoryEvidence("surviving libvirt domain/state artifact at \(path)")
        }
        for name in try children(path) {
            try requireEmptyTree((path as NSString).appendingPathComponent(name))
        }
    }

    private static func children(_ path: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }
}
