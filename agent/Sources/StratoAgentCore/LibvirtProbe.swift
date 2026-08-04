import Foundation

/// Probes the libvirt daemon this host manages VMs through.
///
/// The agent drives QEMU through libvirtd at `qemu:///system` (issue #902), so
/// a host where that connection is missing, unreachable, or too old is not a
/// usable hypervisor node — and the failure has to surface at startup, not as
/// every VM create timing out later. `HostPreflight` turns this probe's result
/// into checks with remediation; the probe itself only reports facts.
///
/// Reachability and version come from the same `virsh version --daemon` call
/// because they are the same question: virsh has to complete a connection to
/// answer, and the version it prints is the daemon's, not the client's. Shelling
/// out to virsh rather than linking libvirt keeps this probe free of the
/// swift-libvirt dependency, which arrives with the driver itself (issue #902) —
/// `libvirt-clients` is installed alongside `libvirt-daemon-system` by
/// `deploy/agent/install.sh` either way.
public enum LibvirtProbe {

    /// The connection URI the agent manages VMs over.
    public static let systemURI = "qemu:///system"

    /// Whether this agent build actually manages VMs through libvirt.
    ///
    /// False while the driver is still being written (issue #902): the host
    /// checks below already run and report, but as advisories, because a host
    /// without libvirt runs today's direct-QEMU driver perfectly well and must
    /// not be told it is broken. Flipping this to true with the driver turns the
    /// same checks into gating ones — same probe, same messages, now with
    /// consequences.
    public static let driverBuilt = false

    /// The oldest libvirt a hypervisor node may run.
    ///
    /// Internal snapshots of UEFI guests — how `checkpointVM` works — only
    /// became possible in libvirt 10.9 (and only with a qcow2 NVRAM varstore),
    /// 10.10 fixed revert/delete not accounting for that varstore, and 11.2–11.3
    /// carry a regression that breaks reverting to an internal snapshot. 11.5 is
    /// the first release clear of all of it. Ubuntu 24.04 ships 10.0.0 and is
    /// therefore not a supported hypervisor host; 26.04 ships 12.0.0.
    public static let minimumVersion = Version(major: 11, minor: 5, patch: 0)

    /// A libvirt release number, compared component-wise.
    public struct Version: Comparable, CustomStringConvertible, Sendable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        /// Parses a dotted release number (`11.5.0`, or `11.5` with an implied
        /// patch of 0). Returns nil for anything else.
        public init?(_ string: String) {
            let parts = string.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            var components = [0, 0, 0]
            for (index, part) in parts.enumerated() {
                guard let value = Int(part), value >= 0 else { return nil }
                components[index] = value
            }
            self.init(major: components[0], minor: components[1], patch: components[2])
        }

        public var description: String { "\(major).\(minor).\(patch)" }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// What the probe found. Deliberately three states, not a bool plus an
    /// optional: "libvirt was never installed on this host" and "libvirtd is
    /// installed but refused the connection" need different remediation.
    public enum Status: Sendable, Equatable {
        /// No `virsh` on `PATH` — libvirt is not installed here.
        case clientMissing
        /// The connection failed. The detail is whatever virsh said, trimmed.
        case unreachable(String)
        /// Connected; the daemon reports this version.
        case reachable(Version)
    }

    public static let probeTimeout: Duration = .seconds(10)

    /// Connects to `uri` with virsh and reports what came back.
    ///
    /// - Parameters:
    ///   - searchPath: `PATH` used to locate virsh.
    ///   - uri: Connection URI; the system QEMU driver by default.
    ///   - timeout: Bounds the subprocess, so a wedged daemon delays startup by
    ///     seconds instead of hanging it. virsh has no connect deadline of its
    ///     own.
    public static func probe(
        searchPath: String = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        uri: String = systemURI,
        timeout: Duration = probeTimeout
    ) async -> Status {
        guard let virsh = HostPreflight.locateTool("virsh", searchPath: searchPath) else {
            return .clientMissing
        }

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: virsh),
                arguments: ["-c", uri, "version", "--daemon"],
                timeout: timeout)
        } catch {
            return .unreachable("\(virsh) failed: \(error)")
        }

        let output = String(data: result.standardOutput, encoding: .utf8) ?? ""
        guard result.terminationStatus == 0 else {
            let stderr = String(data: result.standardError, encoding: .utf8) ?? ""
            return .unreachable(
                firstMeaningfulLine(stderr) ?? firstMeaningfulLine(output) ?? "virsh exited \(result.terminationStatus)"
            )
        }
        guard let version = daemonVersion(in: output) else {
            // Connected, but the output was not what we parse. Treat it as
            // unreachable rather than guessing a version: the version floor is
            // the whole reason to ask.
            return .unreachable(
                "could not read the daemon version from `virsh -c \(uri) version --daemon` output")
        }
        return .reachable(version)
    }

    /// Extracts the daemon version from `virsh version --daemon` output, whose
    /// last line is `Running against daemon: 11.5.0`. The other lines report the
    /// client's compiled-against and in-use library versions, which say nothing
    /// about the daemon actually serving this host.
    static func daemonVersion(in output: String) -> Version? {
        let marker = "Running against daemon:"
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: marker) else { continue }
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let version = Version(value) { return version }
        }
        return nil
    }

    private static func firstMeaningfulLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
