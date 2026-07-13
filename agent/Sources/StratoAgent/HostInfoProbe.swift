import Foundation
import StratoShared

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Gathers descriptive hardware, platform, and OS details about the host the
/// agent runs on, for display on the agent object. Every probe is best-effort:
/// a value that can't be read (missing file, unsupported sysctl, parse miss)
/// stays `nil` rather than failing the whole gather, since none of it is load
/// bearing — the scheduler uses the typed `CPUArchitecture`/`HypervisorSupport`
/// fields, not this.
///
/// Reads are cheap and the values are effectively static for the process's
/// lifetime, but the agent re-probes on every (re)registration alongside its
/// other capability probes so a kernel upgrade or hardware change is reflected
/// after the next reconnect.
enum HostInfoProbe {
    static func gather() -> HostInfo {
        HostInfo(
            osName: osName(),
            kernelVersion: kernelVersion(),
            cpuModel: cpuModel(),
            cpuVendor: cpuVendor(),
            physicalCoreCount: physicalCoreCount(),
            logicalCoreCount: ProcessInfo.processInfo.activeProcessorCount,
            totalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
            machineModel: machineModel(),
            bootTime: bootTime()
        )
    }

    // MARK: - Kernel release (uname -r), shared by both platforms

    private static func kernelVersion() -> String? {
        var uts = utsname()
        guard uname(&uts) == 0 else { return nil }
        return withUnsafeBytes(of: &uts.release) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    #if os(Linux)

    // MARK: - Linux probes

    private static func osName() -> String? {
        // /etc/os-release PRETTY_NAME, e.g. PRETTY_NAME="Ubuntu 24.04.1 LTS".
        guard let contents = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
            return nil
        }
        for line in contents.split(separator: "\n") {
            guard line.hasPrefix("PRETTY_NAME=") else { continue }
            let value = line.dropFirst("PRETTY_NAME=".count)
            return unquote(String(value))
        }
        return nil
    }

    private static func cpuModel() -> String? {
        firstCPUInfoValue(key: "model name")
    }

    private static func cpuVendor() -> String? {
        firstCPUInfoValue(key: "vendor_id")
    }

    /// Distinct physical cores across all sockets: count unique
    /// (physical id, core id) pairs in /proc/cpuinfo. Falls back to `nil` when
    /// the fields are absent (e.g. some ARM hosts), letting the UI show only
    /// the logical count rather than a wrong physical one.
    private static func physicalCoreCount() -> Int? {
        guard let contents = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else {
            return nil
        }
        var cores = Set<String>()
        var currentPhysical: String?
        var currentCore: String?
        var sawFields = false
        func flush() {
            if let currentPhysical, let currentCore {
                cores.insert("\(currentPhysical):\(currentCore)")
            }
            currentPhysical = nil
            currentCore = nil
        }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key == "physical id" {
                currentPhysical = value
                sawFields = true
            } else if key == "core id" {
                currentCore = value
                sawFields = true
            }
        }
        flush()
        guard sawFields, !cores.isEmpty else { return nil }
        return cores.count
    }

    private static func machineModel() -> String? {
        // DMI product name; readable without root on most distros. Trim the
        // trailing newline sysfs appends.
        guard let value = try? String(contentsOfFile: "/sys/class/dmi/id/product_name", encoding: .utf8)
        else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bootTime() -> Date? {
        // /proc/stat "btime <seconds since epoch>".
        guard let contents = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else {
            return nil
        }
        for line in contents.split(separator: "\n") where line.hasPrefix("btime ") {
            let value = line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces)
            if let seconds = TimeInterval(value) {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    private static func firstCPUInfoValue(key: String) -> String? {
        guard let contents = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else {
            return nil
        }
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        var result = value
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    #elseif os(macOS)

    // MARK: - macOS probes (sysctl)

    private static func osName() -> String? {
        // "macOS <ProductVersion>"; sysctl kern.osproductversion is the exact
        // marketing version (ProcessInfo would need string assembly).
        if let version = sysctlString("kern.osproductversion") {
            return "macOS \(version)"
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func cpuModel() -> String? {
        sysctlString("machdep.cpu.brand_string")
    }

    private static func cpuVendor() -> String? {
        // Populated on Intel; empty on Apple Silicon, where the vendor is Apple.
        if let vendor = sysctlString("machdep.cpu.vendor"), !vendor.isEmpty {
            return vendor
        }
        return CPUArchitecture.current == .arm64 ? "Apple" : nil
    }

    private static func physicalCoreCount() -> Int? {
        sysctlInt("hw.physicalcpu")
    }

    private static func machineModel() -> String? {
        sysctlString("hw.model")
    }

    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    #else

    // MARK: - Unsupported platforms

    private static func osName() -> String? { nil }
    private static func cpuModel() -> String? { nil }
    private static func cpuVendor() -> String? { nil }
    private static func physicalCoreCount() -> Int? { nil }
    private static func machineModel() -> String? { nil }
    private static func bootTime() -> Date? { nil }

    #endif
}
