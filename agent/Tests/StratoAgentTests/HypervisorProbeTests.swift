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

    // MARK: - QEMU

    @Test("QEMU is available and accelerated when binary exists and acceleration is on")
    func qemuAvailableAccelerated() {
        let report = HypervisorProbe.qemuReport(binaryPath: executableBinary, acceleration: accelerationOn)

        #expect(report.type == .qemu)
        #expect(report.available)
        #expect(report.accelerated)
        #expect(report.unavailabilityReason == nil)
        #expect(report.capabilities == .qemu)
    }

    @Test("QEMU stays available without acceleration (TCG fallback)")
    func qemuAvailableUnaccelerated() {
        let report = HypervisorProbe.qemuReport(binaryPath: executableBinary, acceleration: accelerationOff)

        #expect(report.available)
        #expect(!report.accelerated)
    }

    @Test("QEMU is unavailable when the binary is missing")
    func qemuUnavailableWithoutBinary() {
        let report = HypervisorProbe.qemuReport(binaryPath: missingBinary, acceleration: accelerationOn)

        #expect(!report.available)
        #expect(!report.accelerated)
        #expect(report.unavailabilityReason?.contains(missingBinary) == true)
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
        let reports = HypervisorProbe.probeAll(
            qemuBinaryPath: missingBinary,
            firecrackerBinaryPath: missingBinary
        )

        #expect(reports.count == HypervisorType.allCases.count)
        for type in HypervisorType.allCases {
            #expect(reports.filter { $0.type == type }.count == 1)
        }
    }

    @Test("probeAll marks Firecracker unavailable on non-Linux platforms")
    func probeAllFirecrackerPlatformGate() throws {
        #if os(macOS)
        let reports = HypervisorProbe.probeAll(
            qemuBinaryPath: executableBinary,
            firecrackerBinaryPath: executableBinary
        )
        let firecracker = try #require(reports.first { $0.type == .firecracker })
        #expect(!firecracker.available)
        #expect(firecracker.unavailabilityReason != nil)
        #endif
    }
}
