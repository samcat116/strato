import Foundation
import StratoShared

/// Read-only evidence for an exact backend-owned boundary. Construction does
/// not establish ownership: the backend must prove process identity and the
/// stable boundary before supplying this path. Never search descendants for a
/// directory whose values happen to match the desired plan.
public struct BurstableCgroupReadback: Sendable, Equatable {
    public let memoryHighBytes: Int64?
    public let memoryMaxBytes: Int64?
    public let cpuWeight: Int?
    public let cpuQuotaUnlimited: Bool?

    public static func sample(
        ownedPath: String,
        cgroupRoot: String = "/sys/fs/cgroup",
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Self? {
        // Refuse the shared root, relative paths, aliases and traversal. The
        // ownership authority supplies a canonical path, not arbitrary input.
        guard canonical(ownedPath), canonical(cgroupRoot), ownedPath.hasPrefix(cgroupRoot + "/") else { return nil }
        func contents(_ name: String) -> String? {
            readFile(ownedPath + "/" + name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func finite(_ name: String) -> Int64? {
            guard let raw = contents(name), !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
                let value = Int64(raw), value > 0
            else { return nil }
            return value
        }
        let weight = finite("cpu.weight").flatMap { (1...10_000).contains($0) ? Int($0) : nil }
        let quota = contents("cpu.max").flatMap { raw -> Bool? in
            let fields = raw.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let period = Int64(fields[1]), (1000...1_000_000).contains(period) else {
                return nil
            }
            if fields[0] == "max" { return true }
            guard let quota = Int64(fields[0]), quota > 0 else { return nil }
            return false
        }
        return Self(
            memoryHighBytes: finite("memory.high"), memoryMaxBytes: finite("memory.max"),
            cpuWeight: weight, cpuQuotaUnlimited: quota)
    }

    /// Unknown data is never a successful acknowledgement. A finite quota
    /// violates shared-tier CPU behavior even when all other controls match.
    public func matches(_ limits: BurstableResourceLimits, pageSize: Int64) throws -> Bool {
        let aligned = try limits.kernelMemoryBytes(pageSize: pageSize)
        return memoryHighBytes == aligned.high && memoryMaxBytes == aligned.maximum
            && cpuWeight == limits.cpuWeight && cpuQuotaUnlimited == true
    }

    private static func canonical(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
