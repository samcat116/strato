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
    func buildGateOpenWithRuntime() throws {
        // No runtimeBuilt override: the build's own constant now permits the
        // capability, so with every host prerequisite satisfied the probe
        // reports capable. The reconciler drives desired sandboxes on this build.
        let dir = try makeGuestImage(capabilities: [])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: dir)

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
    func capableWithAllPrerequisites() throws {
        let dir = try makeGuestImage(capabilities: [])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: dir, runtimeBuilt: true)

        #expect(report.capable)
        #expect(report.unavailabilityReason == nil)
    }

    @Test("a directory with a current manifest satisfies the guest image check")
    func directoryCountsAsPresent() throws {
        let dir = try makeGuestImage(capabilities: [])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: dir, runtimeBuilt: true)

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

    @Test("a required-but-unusable jailer keeps the capability dark (issue #425)")
    func jailerBlockedGatesOff() {
        // Every other prerequisite is satisfied — the jailer block alone must
        // dominate, because running untrusted workloads unjailed on a host
        // whose operator demanded the jailer is not an option.
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: presentPath,
            jailerBlockedReason: "the agent is not running as root")

        #expect(!report.capable)
        #expect(report.unavailabilityReason?.contains("sandbox_jailer_mode") == true)
        #expect(report.unavailabilityReason?.contains("not running as root") == true)
    }

    // MARK: - Sandbox networking (STR-103)

    /// A guest image directory whose `guest.json` advertises `capabilities`.
    private func makeGuestImage(capabilities: [String]?, schemaVersion: Int = 2) throws -> String {
        let dir = NSTemporaryDirectory() + "sandbox-probe-guest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let capabilityField =
            capabilities.map {
                "\"capabilities\": [\($0.map { "\"\($0)\"" }.joined(separator: ", "))],"
            } ?? ""
        let manifest = """
            {
              "schemaVersion": \(schemaVersion),
              "version": "v", "gitSHA": "s",
              \(capabilityField)
              "artifacts": [
                {"arch": "x86_64", "kernel": "vmlinux-x86_64",
                 "initramfs": "initramfs-x86_64.cpio.gz", "bootArgs": "console=ttyS0"}
              ]
            }
            """
        try manifest.write(toFile: dir + "/guest.json", atomically: true, encoding: .utf8)
        return dir
    }

    private func networkingReport(
        guestImagePath: String, jailsNewSandboxes: Bool = true,
        networkCapability: NetworkCapability? = .overlay
    ) -> SandboxRuntimeProbe.Report {
        SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: guestImagePath, runtimeBuilt: true,
            jailsNewSandboxes: jailsNewSandboxes, networkCapability: networkCapability)
    }

    @Test("networking is capable with OVN, the jailer, and a network-capable guest image")
    func networkingCapableWithAllThree() throws {
        let dir = try makeGuestImage(capabilities: ["network"])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = networkingReport(guestImagePath: dir)
        #expect(report.capable)
        #expect(report.networkingCapable)
        #expect(report.networkingUnavailabilityReason == nil)
    }

    @Test("a schema-v1 guest image blocks the sandbox runtime")
    func oldGuestImageBlocksRuntime() throws {
        let dir = try makeGuestImage(capabilities: nil, schemaVersion: 1)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = networkingReport(guestImagePath: dir)
        #expect(!report.capable)
        #expect(!report.networkingCapable)
        #expect(report.unavailabilityReason?.contains("schema version 1") == true)
    }

    @Test("an unreadable manifest blocks the sandbox runtime")
    func unreadableManifestBlocksRuntime() throws {
        let dir = NSTemporaryDirectory() + "sandbox-probe-guest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "not json".write(toFile: dir + "/guest.json", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = networkingReport(guestImagePath: dir)
        #expect(!report.capable)
        #expect(!report.networkingCapable)
        #expect(report.unavailabilityReason?.contains("could not be read") == true)
    }

    @Test("user-mode networking blocks a sandbox NIC — there is no user-mode form of one")
    func userModeBlocksNetworking() throws {
        let dir = try makeGuestImage(capabilities: ["network"])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = networkingReport(guestImagePath: dir, networkCapability: .userMode)
        #expect(report.capable)
        #expect(!report.networkingCapable)
        #expect(report.networkingUnavailabilityReason?.contains("network_mode") == true)
    }

    @Test("an unjailed agent has no namespace to attach a NIC into")
    func unjailedBlocksNetworking() throws {
        let dir = try makeGuestImage(capabilities: ["network"])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = networkingReport(guestImagePath: dir, jailsNewSandboxes: false)
        #expect(report.capable)
        #expect(!report.networkingCapable)
        #expect(report.networkingUnavailabilityReason?.contains("sandbox_jailer_mode") == true)
    }

    /// Networking is strictly downstream of the runtime: a host that cannot run
    /// sandboxes at all still gets a networking reason, restated rather than
    /// left nil, so an operator reading that line alone is not left guessing.
    @Test("a host with no sandbox runtime reports networking unavailable too")
    func networkingFollowsTheBaseCapability() throws {
        let dir = try makeGuestImage(capabilities: ["network"])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerUnavailable, guestImagePath: dir, runtimeBuilt: true,
            jailsNewSandboxes: true, networkCapability: .overlay)
        #expect(!report.capable)
        #expect(!report.networkingCapable)
        #expect(report.networkingUnavailabilityReason?.contains("/dev/kvm not present") == true)
    }

    @Test("networking is off by default, so a caller that asks nothing never over-claims")
    func networkingDefaultsOff() throws {
        let dir = try makeGuestImage(capabilities: [])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let report = SandboxRuntimeProbe.probe(
            firecracker: firecrackerAvailable, guestImagePath: dir)
        #expect(report.capable)
        #expect(!report.networkingCapable)
    }
}
