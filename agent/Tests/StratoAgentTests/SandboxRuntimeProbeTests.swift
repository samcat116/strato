import Foundation
import Testing
import StratoShared
@testable import StratoAgentCore

@Suite("Sandbox Runtime Probe Tests")
struct SandboxRuntimeProbeTests {

    private let firecrackerAvailable = HypervisorSupport(
        type: .firecracker,
        available: true,
        accelerated: true,
        capabilities: .firecracker
    )

    private let firecrackerUnavailable = HypervisorSupport(
        type: .firecracker,
        available: false,
        accelerated: false,
        unavailabilityReason: "/dev/kvm not present",
        capabilities: .firecracker
    )

    /// A path that exists on every host running these tests.
    private let presentPath = "/bin/ls"
    private let missingPath = "/nonexistent/sandbox/guest"

    @Test("capable when Firecracker is usable and the guest image is present")
    func capableWithAllPrerequisites() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: presentPath)

        #expect(report.capable)
        #expect(report.unavailabilityReason == nil)
    }

    @Test("a directory satisfies the guest image presence check")
    func directoryCountsAsPresent() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: "/tmp")

        #expect(report.capable)
    }

    @Test("not capable when Firecracker is unavailable, carrying its reason")
    func notCapableWithoutFirecracker() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerUnavailable, guestImagePath: presentPath)

        #expect(!report.capable)
        #expect(report.unavailabilityReason == "/dev/kvm not present")
    }

    @Test("not capable when Firecracker was never probed")
    func notCapableWithoutProbe() {
        let report = SandboxRuntimeProbe.probe(firecracker: nil, guestImagePath: presentPath)

        #expect(!report.capable)
        #expect(report.unavailabilityReason?.contains("not probed") == true)
    }

    @Test("a non-Firecracker report is rejected rather than misread")
    func rejectsWrongHypervisorReport() {
        let qemu = HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu)
        let report = SandboxRuntimeProbe.probe(firecracker: qemu, guestImagePath: presentPath)

        #expect(!report.capable)
    }

    @Test("not capable when the guest image path is unconfigured or empty")
    func notCapableWithoutConfiguredPath() {
        let unconfigured = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: nil)
        #expect(!unconfigured.capable)
        #expect(unconfigured.unavailabilityReason?.contains("sandbox_guest_image_path") == true)

        let empty = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: "")
        #expect(!empty.capable)
    }

    @Test("not capable when nothing exists at the guest image path")
    func notCapableWithoutGuestImage() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: missingPath)

        #expect(!report.capable)
        #expect(report.unavailabilityReason?.contains(missingPath) == true)
    }
}
