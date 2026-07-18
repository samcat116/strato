import Foundation
import Logging
import StratoShared

/// One workload's entry in the agent-wide manifest: which backend owns it and
/// the spec it was created from (the spec carries the resource reservations
/// that must survive a restart).
///
/// Issue #417 generalized the manifest over `WorkloadKind` so sandbox orphans
/// are detected on restart, keep their resources reserved, and can be
/// re-adopted, exactly like VMs. Entries written before sandboxes existed
/// carry no `kind` key and decode as `.vm`.
public struct VMManifestEntry: Codable, Sendable {
    public let kind: WorkloadKind
    public let hypervisorType: HypervisorType
    /// Creation spec and resource reservation. For sandbox entries this is a
    /// reservation-only projection of `sandboxSpec` (cpus/memory), so
    /// restart-survival capacity accounting reads one shape for both kinds.
    public let spec: VMSpec
    /// The sandbox's own spec (present iff `kind == .sandbox`), kept so the
    /// sandbox runtime can re-adopt the orphan after a restart.
    public let sandboxSpec: SandboxSpec?

    public init(hypervisorType: HypervisorType, spec: VMSpec) {
        self.kind = .vm
        self.hypervisorType = hypervisorType
        self.spec = spec
        self.sandboxSpec = nil
    }

    /// A sandbox entry. Sandboxes boot through Firecracker only, so the
    /// backend routing field is pinned.
    public init(sandboxSpec: SandboxSpec) {
        self.kind = .sandbox
        self.hypervisorType = .firecracker
        self.spec = VMSpec(
            cpus: sandboxSpec.cpus, memoryBytes: sandboxSpec.memoryBytes, boot: .disk(firmware: nil))
        self.sandboxSpec = sandboxSpec
    }

    // Custom decode so `kind` tolerates absence: entries persisted by a
    // pre-sandbox agent decode as VMs rather than throwing. `encode(to:)`
    // stays synthesized.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(WorkloadKind.self, forKey: .kind) ?? .vm
        hypervisorType = try c.decode(HypervisorType.self, forKey: .hypervisorType)
        spec = try c.decode(VMSpec.self, forKey: .spec)
        sandboxSpec = try c.decodeIfPresent(SandboxSpec.self, forKey: .sandboxSpec)
    }
}

extension Sequence where Element == VMManifestEntry {
    /// Total disk committed across these workloads' specs. Specs from a
    /// control plane that predates `VMSpec.diskBytes` (issue #473) count as 0
    /// — under-reporting matches the old behavior rather than blocking
    /// placement. Sandbox entries carry no `diskBytes` and naturally add 0,
    /// mirroring the scheduler (sandboxes reserve no disk).
    public var totalReservedDiskBytes: Int64 {
        reduce(0) { $0 + ($1.spec.diskBytes ?? 0) }
    }
}

/// Persists the set of workloads (VMs and sandboxes) an agent is managing —
/// across all backends — to disk so that, after an agent restart, the agent can
/// route operations to the right backend and keep orphaned workloads' resources
/// reserved.
///
/// On restart, previously-managed VMs are loaded from this manifest as orphans,
/// and the reconciler re-adopts them when the backend supports it (the `.adopt`
/// step in `Reconciliation.swift`): QEMU reconnects to the still-running process
/// via its deterministic per-VM QMP socket path, and Firecracker reconnects to
/// its deterministic per-VM API socket (issue #433). Backends without adoption
/// support — e.g. the Mock hypervisor, which keeps the throwing `adoptVM`
/// default in `HypervisorProtocol.swift` — and VMs created before deterministic
/// socket paths remain orphaned; they keep their resources reserved but are
/// absent from the agent's heartbeat, which the control plane's reconciliation
/// surfaces as `.error` for operator attention.
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
