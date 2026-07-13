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

    @Test("the runtime (issue #421) has landed: the build gate no longer forces the capability off")
    func buildGateOpenWithRuntime() {
        // No runtimeBuilt override: the build's own constant now permits the
        // capability, so with every host prerequisite satisfied the probe
        // reports capable. The reconciler drives desired sandboxes on this build.
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: presentPath)

        #expect(report.capable)
        #expect(report.unavailabilityReason == nil)
    }

    @Test("an explicit unbuilt runtime still forces the capability off")
    func explicitUnbuiltRuntimeGatesOff() {
        // Injecting runtimeBuilt: false proves the build gate still dominates
        // every host prerequisite when a build genuinely lacks the runtime.
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: presentPath, runtimeBuilt: false)

        #expect(!report.capable)
        #expect(report.unavailabilityReason?.contains("does not include the sandbox runtime") == true)
    }

    @Test("capable when Firecracker is usable and the guest image is present")
    func capableWithAllPrerequisites() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: presentPath, runtimeBuilt: true)

        #expect(report.capable)
        #expect(report.unavailabilityReason == nil)
    }

    @Test("a directory satisfies the guest image presence check")
    func directoryCountsAsPresent() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: "/tmp", runtimeBuilt: true)

        #expect(report.capable)
    }

    @Test("not capable when Firecracker is unavailable, carrying its reason")
    func notCapableWithoutFirecracker() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerUnavailable, guestImagePath: presentPath, runtimeBuilt: true)

        #expect(!report.capable)
        #expect(report.unavailabilityReason == "/dev/kvm not present")
    }

    @Test("not capable when Firecracker was never probed")
    func notCapableWithoutProbe() {
        let report = SandboxRuntimeProbe.probe(firecracker: nil, guestImagePath: presentPath, runtimeBuilt: true)

        #expect(!report.capable)
        #expect(report.unavailabilityReason?.contains("not probed") == true)
    }

    @Test("a non-Firecracker report is rejected rather than misread")
    func rejectsWrongHypervisorReport() {
        let qemu = HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu)
        let report = SandboxRuntimeProbe.probe(firecracker: qemu, guestImagePath: presentPath, runtimeBuilt: true)

        #expect(!report.capable)
    }

    @Test("not capable when the guest image path is unconfigured or empty")
    func notCapableWithoutConfiguredPath() {
        let unconfigured = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: nil, runtimeBuilt: true)
        #expect(!unconfigured.capable)
        #expect(unconfigured.unavailabilityReason?.contains("sandbox_guest_image_path") == true)

        let empty = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: "", runtimeBuilt: true)
        #expect(!empty.capable)
    }

    @Test("not capable when nothing exists at the guest image path")
    func notCapableWithoutGuestImage() {
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: missingPath, runtimeBuilt: true)

        #expect(!report.capable)
        #expect(report.unavailabilityReason?.contains(missingPath) == true)
    }
}
