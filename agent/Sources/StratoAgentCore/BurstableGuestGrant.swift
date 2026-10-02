import Foundation

/// Snapshot configuration must match the admitted grant before guest execution.
public enum BurstableGuestGrant {
    public static func verify(cpuCount: Int, memoryMiB: Int, admittedCPUs: Int, admittedBytes: Int64) throws {
        let bytes = Int64(memoryMiB).multipliedReportingOverflow(by: 1024 * 1024)
        guard cpuCount > 0, memoryMiB > 0, !bytes.overflow,
            cpuCount == admittedCPUs, bytes.partialValue == admittedBytes
        else { throw ConvergenceError.blocked("Restored Firecracker grant differs from admitted sizing") }
    }
}
