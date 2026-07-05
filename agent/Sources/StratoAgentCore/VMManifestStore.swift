import Foundation
import Logging
import StratoShared

/// One VM's entry in the agent-wide manifest: which hypervisor backend owns the
/// VM and the spec it was created from (the spec carries the resource
/// reservations that must survive a restart).
public struct VMManifestEntry: Codable, Sendable {
    public let hypervisorType: HypervisorType
    public let spec: VMSpec

    public init(hypervisorType: HypervisorType, spec: VMSpec) {
        self.hypervisorType = hypervisorType
        self.spec = spec
    }
}

/// Persists the set of VMs an agent is managing — across all hypervisor backends —
/// to disk so that, after an agent restart, the agent can route operations to the
/// right backend and keep orphaned VMs' resources reserved.
///
/// Option A (reconcile-only): the agent does NOT re-adopt the running hypervisor
/// processes on restart — their control sockets use non-deterministic paths and
/// SwiftQEMU has no attach API. Instead, previously-managed VMs are loaded as
/// orphans at startup, and because they are not placed back under management they
/// are absent from the agent's heartbeat — which the control plane's reconciliation
/// surfaces as `.error` for operator attention. Full re-adoption is the Option B
/// follow-up (reconciliation phase 2, #260) and builds on this same manifest.
public struct VMManifestStore {
    public let path: String
    /// Path of the manifest written by pre-unified agents, which only QEMUService
    /// maintained. Read once for migration; removed after a successful rewrite in
    /// the unified format.
    public let legacyQEMUManifestPath: String?
    let logger: Logger

    public init(path: String, legacyQEMUManifestPath: String? = nil, logger: Logger) {
        self.path = path
        self.legacyQEMUManifestPath = legacyQEMUManifestPath
        self.logger = logger
    }

    /// Loads the previously-persisted VM manifest, or an empty map if none exists
    /// or it cannot be read. If only a legacy QEMU-only manifest exists, its
    /// entries are migrated (they are QEMU VMs by definition), persisted in the
    /// unified format, and the legacy file is removed.
    public func load() -> [String: VMManifestEntry] {
        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                return try JSONDecoder().decode([String: VMManifestEntry].self, from: data)
            } catch {
                logger.error("Failed to read VM manifest at \(path): \(error)")
                return [:]
            }
        }
        return migrateLegacyQEMUManifest()
    }

    /// Atomically writes the current manifest to disk.
    /// - Returns: `true` when the write succeeded; failures are logged.
    @discardableResult
    public func save(_ manifest: [String: VMManifestEntry]) -> Bool {
        do {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(manifest)
            // Atomic write so a crash mid-write can't leave a truncated manifest.
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            logger.error("Failed to write VM manifest at \(path): \(error)")
            return false
        }
    }

    private func migrateLegacyQEMUManifest() -> [String: VMManifestEntry] {
        guard let legacyPath = legacyQEMUManifestPath,
            FileManager.default.fileExists(atPath: legacyPath)
        else { return [:] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: legacyPath))
            let specs: [String: VMSpec]
            do {
                specs = try JSONDecoder().decode([String: VMSpec].self, from: data)
            } catch {
                // Manifests written before the hypervisor-neutral VMSpec stored the
                // QEMU-flavored VmConfig. Salvage the resource reservations (all the
                // orphan-tracking needs) so an upgrade doesn't hand orphaned VMs'
                // capacity to new placements.
                let legacy = try JSONDecoder().decode([String: LegacyVmConfig].self, from: data)
                specs = legacy.mapValues { $0.toSpec() }
            }
            let migrated = specs.mapValues { VMManifestEntry(hypervisorType: .qemu, spec: $0) }
            if !migrated.isEmpty {
                logger.warning("Migrated \(migrated.count) VM manifest entr(ies) from the QEMU-only manifest format")
            }
            // Persist in the unified format before dropping the legacy file, so a
            // crash — or a failed write (disk full, permissions) — between the two
            // steps can't destroy the only readable manifest. On failure the legacy
            // file stays put and the next start retries the migration.
            if save(migrated) {
                try? FileManager.default.removeItem(atPath: legacyPath)
            }
            return migrated
        } catch {
            logger.error("Failed to read legacy VM manifest at \(legacyPath): \(error)")
            return [:]
        }
    }
}

/// Minimal projection of the pre-VMSpec manifest format, kept only to migrate
/// existing on-disk manifests. Decodes just the fields that matter for resource
/// reservation of orphaned VMs.
private struct LegacyVmConfig: Decodable {
    struct Cpus: Decodable {
        let bootVcpus: Int
        let maxVcpus: Int?

        enum CodingKeys: String, CodingKey {
            case bootVcpus = "boot_vcpus"
            case maxVcpus = "max_vcpus"
        }
    }

    struct Memory: Decodable {
        let size: Int64
    }

    let cpus: Cpus?
    let memory: Memory?

    func toSpec() -> VMSpec {
        VMSpec(
            cpus: cpus?.bootVcpus ?? 0,
            maxCpus: cpus?.maxVcpus,
            memoryBytes: memory?.size ?? 0,
            boot: .disk(firmware: nil)
        )
    }
}
