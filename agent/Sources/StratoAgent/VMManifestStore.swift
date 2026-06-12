import Foundation
import Logging
import StratoShared

/// Persists the set of VMs an agent is managing to disk so that, after an agent
/// restart, the agent and the control plane can tell which VMs it previously owned.
///
/// Option A (reconcile-only): the agent does NOT re-adopt the running QEMU processes
/// on restart — their QMP sockets use non-deterministic paths and SwiftQEMU has no
/// attach API. Instead, previously-managed VMs are loaded and logged at startup, and
/// because they are not placed back under management they are absent from the agent's
/// heartbeat — which the control plane's reconciliation surfaces as `.error` for
/// operator attention. Full re-adoption is the Option B follow-up and can build on
/// this same on-disk manifest.
struct VMManifestStore {
    let path: String
    let logger: Logger

    /// Loads the previously-persisted VM manifest, or an empty map if none exists
    /// or it cannot be read.
    func load() -> [String: VmConfig] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode([String: VmConfig].self, from: data)
        } catch {
            logger.error("Failed to read VM manifest at \(path): \(error)")
            return [:]
        }
    }

    /// Atomically writes the current manifest to disk.
    func save(_ manifest: [String: VmConfig]) {
        do {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(manifest)
            // Atomic write so a crash mid-write can't leave a truncated manifest.
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("Failed to write VM manifest at \(path): \(error)")
        }
    }
}
