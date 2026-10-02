import Foundation

/// A host/backend ownership authority must supply the stable root; discovering
/// a matching descendant is insufficient. All controller writes remain libvirt
/// RPCs. Readback validates UUID, process incarnation and known emulator paths.
public enum BurstableQEMUOwnership {
    public static func verify(
        vmID: String, ownedPath: String, limits: BurstableResourceLimits, pageSize: Int64,
        pidFilePath: String, procRoot: String = "/proc", cgroupRoot: String = "/sys/fs/cgroup",
        alternativeLimits: BurstableResourceLimits? = nil, requireMatchingLimits: Bool = true,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) throws {
        guard let expectedID = UUID(uuidString: vmID),
            let rawPID = readFile(pidFilePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(rawPID), pid > 0,
            let before = readFile("\(procRoot)/\(pid)/stat"),
            let command = readFile("\(procRoot)/\(pid)/cmdline")
        else { throw ConvergenceError.blocked("Cannot prove the QEMU process incarnation for burstable readback") }
        let arguments = command.split(separator: "\0")
        guard let uuidIndex = arguments.firstIndex(of: "-uuid"), arguments.indices.contains(uuidIndex + 1),
            UUID(uuidString: String(arguments[uuidIndex + 1])) == expectedID
        else { throw ConvergenceError.blocked("QEMU process identity does not match its libvirt domain") }
        if requireMatchingLimits {
            try BurstableCgroupEnforcement.verify(
                processID: pid, ownedPath: ownedPath, expectedPath: ownedPath,
                limits: limits, pageSize: pageSize, cgroupRoot: cgroupRoot, procRoot: procRoot,
                allowedMembershipSuffixes: ["/emulator", "/libvirt/emulator"], alternativeLimits: alternativeLimits,
                readFile: readFile)
        } else {
            try BurstableCgroupEnforcement.verifyOwnership(
                processID: pid, ownedPath: ownedPath, expectedPath: ownedPath,
                cgroupRoot: cgroupRoot, procRoot: procRoot,
                allowedMembershipSuffixes: ["/emulator", "/libvirt/emulator"], readFile: readFile)
        }
        guard let after = readFile("\(procRoot)/\(pid)/stat"), incarnation(before) == incarnation(after),
            incarnation(before) != nil, readFile(pidFilePath)?.trimmingCharacters(in: .whitespacesAndNewlines) == rawPID
        else { throw ConvergenceError.blocked("QEMU process changed during burstable readback") }
    }

    private static func incarnation(_ stat: String) -> String? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(whereSeparator: { $0.isWhitespace })
        // The suffix starts at field3; Linux starttime is field22.
        guard fields.count > 19, UInt64(fields[19]) != nil else { return nil }
        return String(fields[19])
    }
}
