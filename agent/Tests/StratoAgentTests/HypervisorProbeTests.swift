import Foundation
import Testing
import StratoShared
@testable import StratoAgentCore

@Suite("Hypervisor Probe Tests")
struct HypervisorProbeTests {

    private let accelerationOn = HypervisorProbe.AccelerationProbe(available: true, reason: nil)
    private let accelerationOff = HypervisorProbe.AccelerationProbe(available: false, reason: "/dev/kvm not present")

    // An executable that exists on every macOS/Linux host running these tests.
    private let executableBinary = "/bin/ls"
    private let missingBinary = "/nonexistent/path/to/hypervisor"

    private let libvirtOK = LibvirtProbe.Status.reachable(LibvirtProbe.Version(major: 11, minor: 5, patch: 0))

    // MARK: - QEMU

    /// There is no QEMU binary to look for any more (STR-136): the agent drives
    /// libvirtd, which picks the emulator from its own capabilities. What
    /// decides availability is that daemon.
    @Test("QEMU availability is a libvirt fact")
    func qemuAvailabilityIsALibvirtFact() {
        let report = HypervisorProbe.qemuReport(libvirt: libvirtOK, acceleration: accelerationOn)

        #expect(report.type == .qemu)
        #expect(report.capabilities == .qemu)
        #if os(Linux)
        #expect(report.available)
        #expect(report.accelerated)
        #expect(report.unavailabilityReason == nil)
        #else
        // Off Linux the registered `.qemu` backend is a mock, so the host must
        // not advertise itself as able to run VMs — otherwise the scheduler
        // places real workloads onto it.
        #expect(!report.available)
        #expect(report.unavailabilityReason?.contains("Linux") == true)
        #endif
    }

    /// The gate would demote these too, but a caller that never reaches the gate
    /// must not come away believing a host with no libvirt can run VMs.
    @Test(
        "an unusable libvirt is unavailable at the probe, not only at the gate",
        arguments: [
            LibvirtProbe.Status.clientMissing, .unreachable("Failed to connect to the hypervisor"),
            .unrecognizedOutput("Using library: libvirt 12.0.0"),
        ])
    func unusableLibvirtIsUnavailable(_ status: LibvirtProbe.Status) {
        let report = HypervisorProbe.qemuReport(libvirt: status, acceleration: accelerationOn)
        #expect(!report.available)
        #expect(!report.accelerated)
        #expect(report.unavailabilityReason != nil)
    }

    /// The version floor lives in `HostPreflight`, which owns the remediation;
    /// duplicating the comparison here would give two places to get it wrong.
    @Test("the version floor is left to the preflight, not applied twice")
    func versionFloorIsNotDuplicated() {
        let tooOld = LibvirtProbe.Status.reachable(LibvirtProbe.Version(major: 10, minor: 0, patch: 0))
        let report = HypervisorProbe.qemuReport(libvirt: tooOld, acceleration: accelerationOn)
        #if os(Linux)
        #expect(report.available)
        #endif
    }

    @Test("QEMU stays available without acceleration (TCG fallback)")
    func qemuAvailableUnaccelerated() {
        let report = HypervisorProbe.qemuReport(libvirt: libvirtOK, acceleration: accelerationOff)

        #expect(!report.accelerated)
        #if os(Linux)
        #expect(report.available)
        #endif
    }

    // MARK: - Firecracker

    @Test("Firecracker is available only with both binary and KVM")
    func firecrackerAvailable() {
        let report = HypervisorProbe.firecrackerReport(binaryPath: executableBinary, acceleration: accelerationOn)

        #expect(report.type == .firecracker)
        #expect(report.available)
        #expect(report.accelerated)
        #expect(report.unavailabilityReason == nil)
        #expect(report.capabilities == .firecracker)
    }

    @Test("Firecracker is unavailable without acceleration even if the binary exists")
    func firecrackerUnavailableWithoutAcceleration() {
        let report = HypervisorProbe.firecrackerReport(binaryPath: executableBinary, acceleration: accelerationOff)

        #expect(!report.available)
        #expect(!report.accelerated)
        #expect(report.unavailabilityReason == "/dev/kvm not present")
    }

    @Test("Firecracker is unavailable without its binary")
    func firecrackerUnavailableWithoutBinary() {
        let report = HypervisorProbe.firecrackerReport(binaryPath: missingBinary, acceleration: accelerationOn)

        #expect(!report.available)
        #expect(report.unavailabilityReason?.contains(missingBinary) == true)
    }

    // MARK: - probeAll

    @Test("probeAll reports both hypervisor types exactly once")
    func probeAllCoversAllTypes() {
        let reports = HypervisorProbe.probeAll(libvirt: libvirtOK, firecrackerBinaryPath: missingBinary)

        #expect(reports.count == HypervisorType.allCases.count)
        for type in HypervisorType.allCases {
            #expect(reports.filter { $0.type == type }.count == 1)
        }
    }

    @Test("probeAll marks Firecracker unavailable on non-Linux platforms")
    func probeAllFirecrackerPlatformGate() throws {
        #if os(macOS)
        let reports = HypervisorProbe.probeAll(libvirt: libvirtOK, firecrackerBinaryPath: executableBinary)
        let firecracker = try #require(reports.first { $0.type == .firecracker })
        #expect(!firecracker.available)
        #expect(firecracker.unavailabilityReason != nil)
        #endif
    }

    // MARK: - Firecracker version (issue #428)

    @Test("firecrackerVersion parses and normalizes `firecracker --version` output")
    func firecrackerVersionParsesOutput() async throws {
        // A stand-in binary printing Firecracker's version banner.
        let scriptPath = NSTemporaryDirectory() + "fake-firecracker-\(UUID().uuidString)"
        try "#!/bin/sh\necho \"Firecracker v1.7.0\"\n".write(
            toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        let version = await HypervisorProbe.firecrackerVersion(binaryPath: scriptPath)
        #expect(version == "1.7.0")
    }

    @Test("firecrackerVersion is nil for a missing binary")
    func firecrackerVersionMissingBinary() async {
        let version = await HypervisorProbe.firecrackerVersion(binaryPath: missingBinary)
        #expect(version == nil)
    }

    @Test("stampingFirecrackerVersion only touches the Firecracker entry")
    func stampingTargetsFirecrackerOnly() throws {
        let reports = HypervisorProbe.probeAll(libvirt: libvirtOK, firecrackerBinaryPath: executableBinary)
        let stamped = HypervisorProbe.stampingFirecrackerVersion(reports, version: "1.7.0")
        let firecracker = try #require(stamped.first { $0.type == .firecracker })
        let qemu = try #require(stamped.first { $0.type == .qemu })
        #expect(firecracker.version == "1.7.0")
        #expect(qemu.version == nil)
        // Nil leaves the reports untouched.
        #expect(HypervisorProbe.stampingFirecrackerVersion(reports, version: nil) == reports)
    }

    @Test("A hanging firecracker binary cannot wedge the version probe")
    func firecrackerVersionTimesOut() async throws {
        // This probe runs inline on the agent's registration path, which has
        // no other escape hatch: a binary that blocks (a wrapper waiting on a
        // lock, a stalled mount) would otherwise hang registration and every
        // reconnect after it (issue #428 review).
        let script = NSTemporaryDirectory() + "hanging-firecracker-\(UUID().uuidString)"
        try "#!/bin/sh\nsleep 60\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let started = Date()
        let version = await HypervisorProbe.firecrackerVersion(
            binaryPath: script, timeout: .milliseconds(200))
        let elapsed = Date().timeIntervalSince(started)

        // A timed-out probe is indistinguishable from a failed one: nil keeps
        // the host ineligible as a cross-agent restore target.
        #expect(version == nil)
        #expect(elapsed < 10)
    }
}
