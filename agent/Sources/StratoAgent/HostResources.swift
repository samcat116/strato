import Foundation

/// Probes the host machine for real CPU, memory, and disk capacity.
///
/// Used by the agent to report accurate resource availability to the control-plane
/// scheduler instead of hardcoded mock values. All probes rely on Foundation APIs
/// that are available on both macOS and Linux (swift-corelibs-foundation), so no
/// platform-specific `/proc` parsing is required.
enum HostResources {
    /// Number of logical CPU cores currently available to the agent process.
    static var logicalCoreCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    /// Total physical RAM on the host, in bytes.
    static var physicalMemoryBytes: Int64 {
        Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    }

    /// Total and free bytes of the filesystem backing the given path.
    ///
    /// If `path` does not yet exist (e.g. the VM storage directory hasn't been
    /// created), the nearest existing ancestor directory is queried instead, since
    /// it resolves to the same filesystem. Returns `nil` if capacity cannot be read.
    static func diskCapacity(forPath path: String) -> (total: Int64, free: Int64)? {
        let fileManager = FileManager.default

        // Resolve to the nearest existing ancestor so statfs has a real entry to inspect.
        var probePath = path.isEmpty ? "/" : path
        while !fileManager.fileExists(atPath: probePath) {
            let parent = (probePath as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == probePath {
                probePath = "/"
                break
            }
            probePath = parent
        }

        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: probePath),
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            return nil
        }

        return (total: total, free: free)
    }
}
