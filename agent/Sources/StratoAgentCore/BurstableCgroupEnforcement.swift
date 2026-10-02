import Foundation
import StratoShared

/// Evidence validation for a process whose identity the backend has pinned.
/// The backend owns the path derivation; this verifier never writes or searches
/// descendants. Failure preserves an adopted process and blocks execution.
public enum BurstableCgroupEnforcement {
    public static var hostPageSizeBytes: Int64 { Int64(NSPageSize()) }

    /// The jailer may create its owned parent, but the host must already
    /// delegate both controllers. This code never enables host controllers.
    public static func requireDelegatedControllers(
        parentPath: String = "/sys/fs/cgroup",
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) throws {
        for file in ["cgroup.controllers", "cgroup.subtree_control"] {
            let controllers = Set((readFile(parentPath + "/" + file) ?? "").split(whereSeparator: { $0.isWhitespace }))
            guard controllers.contains("cpu"), controllers.contains("memory") else {
                throw ConvergenceError.blocked(
                    "Burstable execution requires delegated cgroup-v2 CPU and memory controllers")
            }
        }
    }

    public static func verify(
        processID: Int32, ownedPath: String, expectedPath: String,
        limits: BurstableResourceLimits, pageSize: Int64,
        cgroupRoot: String = "/sys/fs/cgroup", procRoot: String = "/proc",
        allowedMembershipSuffixes: [String] = [], alternativeLimits: BurstableResourceLimits? = nil,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) throws {
        try verifyOwnership(
            processID: processID, ownedPath: ownedPath, expectedPath: expectedPath,
            cgroupRoot: cgroupRoot, procRoot: procRoot,
            allowedMembershipSuffixes: allowedMembershipSuffixes, readFile: readFile)
        guard
            let readback = BurstableCgroupReadback.sample(
                ownedPath: ownedPath, cgroupRoot: cgroupRoot, readFile: readFile)
        else { throw ConvergenceError.blocked("The owned cgroup boundary disappeared") }
        let matches =
            try alternativeLimits.map { try readback.matchesTransition(from: limits, to: $0, pageSize: pageSize) }
            ?? readback.matches(limits, pageSize: pageSize)
        guard matches else {
            throw ConvergenceError.blocked(
                "Effective burstable memory/CPU controls do not match the admitted aligned targets")
        }
    }
    public static func verifyOwnership(
        processID: Int32, ownedPath: String, expectedPath: String,
        cgroupRoot: String = "/sys/fs/cgroup", procRoot: String = "/proc",
        allowedMembershipSuffixes: [String] = [],
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) throws {
        guard processID > 0, ownedPath == expectedPath,
            BurstableCgroupReadback.sample(
                ownedPath: ownedPath, cgroupRoot: cgroupRoot, readFile: readFile) != nil
        else { throw ConvergenceError.blocked("Burstable workload has no exact owned cgroup boundary") }
        let expectedMembership = String(ownedPath.dropFirst(cgroupRoot.count))
        let acceptedMemberships = [expectedMembership] + allowedMembershipSuffixes.map { expectedMembership + $0 }
        guard let membership = readFile("\(procRoot)/\(processID)/cgroup"),
            membership.split(separator: "\n").filter({ $0.hasPrefix("0::") }).count == 1,
            let unified = membership.split(separator: "\n").first(where: { $0.hasPrefix("0::") }),
            let actualMembership = acceptedMemberships.first(where: { $0 == String(unified.dropFirst(3)) }),
            // cgroup.procs is nonrecursive. Read only the exact root or
            // backend-authorized membership suffix; controls stay at the root.
            let members = readFile(cgroupRoot + actualMembership + "/cgroup.procs"),
            members.split(whereSeparator: { $0.isWhitespace }).contains(Substring(String(processID)))
        else { throw ConvergenceError.blocked("Burstable process is outside its exact owned cgroup boundary") }
    }

}
