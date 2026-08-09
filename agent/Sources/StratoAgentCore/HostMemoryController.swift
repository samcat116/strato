import Foundation

/// Shared cgroup-v2 memory-controller detection for every VMM backend.
public enum HostMemoryController {
    public static let controllersPath = "/sys/fs/cgroup/cgroup.controllers"

    public static func isAvailable(
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Bool {
        guard let controllers = readFile(controllersPath) else { return false }
        return controllers.split(whereSeparator: { $0.isWhitespace }).contains("memory")
    }
}

/// QEMU's process ceiling is current guest RAM plus a fixed VMM allowance. It
/// is a host-protection backstop and never enters placement accounting.
public enum QEMUMemoryCeiling {
    public static func bytes(guestMemoryBytes: Int64, overheadBytes: Int64) -> Int64 {
        let guest = max(0, guestMemoryBytes)
        let overhead = max(0, overheadBytes)
        let (sum, overflow) = guest.addingReportingOverflow(overhead)
        return overflow ? Int64.max : sum
    }

    /// libvirt memory parameters use KiB. Round up so the requested byte
    /// ceiling is never weakened by unit conversion.
    public static func kibibytes(guestMemoryBytes: Int64, overheadBytes: Int64) -> UInt64 {
        let ceiling = bytes(guestMemoryBytes: guestMemoryBytes, overheadBytes: overheadBytes)
        return (UInt64(ceiling) + 1023) / 1024
    }
}
