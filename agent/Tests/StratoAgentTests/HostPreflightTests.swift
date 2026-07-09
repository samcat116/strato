import Foundation
import Testing
import StratoShared

@testable import StratoAgentCore

@Suite("Host Preflight Tests")
struct HostPreflightTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "host-preflight-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Inputs where everything passes: directories under a writable temp
    /// root, `/bin/ls` standing in for qemu-img, no OVN, no free-space floor.
    private func passingInputs(root: String) -> HostPreflight.Inputs {
        HostPreflight.Inputs(
            vmStoragePath: "\(root)/vms",
            volumeStoragePath: "\(root)/volumes",
            imageCachePath: "\(root)/images",
            qemuImgPath: "/bin/ls",
            firmwarePath: "/bin/ls",
            minimumFreeDiskBytes: 0
        )
    }

    // MARK: - Directory checks

    @Test("Owned directories are created with intermediate directories and probed writable")
    func createsOwnedDirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = HostPreflight.run(passingInputs(root: root))

        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: "\(root)/vms"))
        #expect(FileManager.default.fileExists(atPath: "\(root)/volumes"))
        #expect(FileManager.default.fileExists(atPath: "\(root)/images"))
        // The writability probe file must not be left behind.
        #expect(!FileManager.default.fileExists(atPath: "\(root)/vms/.strato-preflight-probe"))
    }

    @Test("A directory path occupied by a regular file fails with remediation")
    func fileInPlaceOfDirectoryFails() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: "\(root)/vms", contents: Data())

        var inputs = passingInputs(root: root)
        inputs.vmStoragePath = "\(root)/vms"
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.vmStorageDirectory))
        #expect(!check.passed)
        #expect(check.detail?.contains("not a directory") == true)
        #expect(!report.storageReady)
    }

    @Test("A directory that cannot be created fails the check")
    func uncreatableDirectoryFails() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A file as a path component makes mkdir -p fail deterministically,
        // even when the test runs as root (unlike permission-based setups).
        FileManager.default.createFile(atPath: "\(root)/blocker", contents: Data())

        var inputs = passingInputs(root: root)
        inputs.volumeStoragePath = "\(root)/blocker/volumes"
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.volumeStorageDirectory))
        #expect(!check.passed)
        #expect(check.detail?.contains("cannot create") == true)
        #expect(!report.storageReady)
    }

    // MARK: - Binary and tool checks

    @Test("qemu-img must be executable, not merely present")
    func qemuImgMustBeExecutable() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let nonExecutable = "\(root)/qemu-img"
        FileManager.default.createFile(atPath: nonExecutable, contents: Data())

        var inputs = passingInputs(root: root)
        inputs.qemuImgPath = nonExecutable
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.qemuImgBinary))
        #expect(!check.passed)
        #expect(check.detail?.contains("qemu-utils") == true)
        #expect(!report.storageReady)
    }

    @Test("Tool lookup walks the provided search path")
    func toolLookupUsesSearchPath() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let binDir = "\(root)/bin"
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: "\(binDir)/ip", contents: Data(),
            attributes: [.posixPermissions: 0o755])

        let found = HostPreflight.checkTool("ip", kind: .ipTool, searchPath: "/nonexistent:\(binDir)", hint: "install")
        #expect(found.passed)

        let missing = HostPreflight.checkTool(
            "ovs-vsctl", kind: .ovsVsctlTool, searchPath: "/nonexistent:\(binDir)", hint: "install openvswitch")
        #expect(!missing.passed)
        #expect(missing.detail?.contains("openvswitch") == true)
    }

    // MARK: - OVN checks

    @Test("OVN socket and tool checks only run in OVN mode")
    func ovnChecksGatedOnMode() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.ovnMode = false
        let withoutOVN = HostPreflight.run(inputs)
        #expect(withoutOVN.check(.ovnDatabaseSocket) == nil)
        #expect(withoutOVN.check(.ipTool) == nil)

        inputs.ovnMode = true
        inputs.ovnNBConnection = "unix:\(root)/missing-ovn.sock"
        inputs.ovsSocketPath = "\(root)/missing-ovs.sock"
        inputs.searchPath = "/nonexistent"
        let withOVN = HostPreflight.run(inputs)
        #expect(withOVN.check(.ovnDatabaseSocket)?.passed == false)
        #expect(withOVN.check(.ovsDatabaseSocket)?.passed == false)
        #expect(withOVN.check(.ipTool)?.passed == false)
        #expect(withOVN.check(.ovsVsctlTool)?.passed == false)
        #expect(!withOVN.ovnReady)
        // OVN problems never gate storage readiness.
        #expect(withOVN.storageReady)
    }

    @Test("A remote NB connection skips the local socket check")
    func remoteNBSkipsSocketCheck() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.ovnMode = true
        // A shared site central (issue #343) has no local NB socket to probe;
        // reachability surfaces at connect time instead of failing preflight.
        inputs.ovnNBConnection = "tcp:central.example:6641"
        inputs.ovsSocketPath = "\(root)/missing-ovs.sock"
        let report = HostPreflight.run(inputs)
        #expect(report.check(.ovnDatabaseSocket)?.passed == true)
        // The OVS database is still host-local and still checked.
        #expect(report.check(.ovsDatabaseSocket)?.passed == false)
    }

    @Test("Configured NB TLS files must exist; missing ones gate OVN readiness")
    func nbTLSFilesChecked() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.ovnMode = true
        inputs.ovnNBConnection = "ssl:central.example:6641"
        let caPath = "\(root)/cacert.pem"
        FileManager.default.createFile(atPath: caPath, contents: Data())
        inputs.ovnNBTLSFilePaths = [caPath, "\(root)/missing-cert.pem"]

        let report = HostPreflight.run(inputs)
        let check = try #require(report.check(.ovnDatabaseTLSFiles))
        #expect(!check.passed)
        #expect(check.detail?.contains("missing-cert.pem") == true)
        // The file that exists is not reported as missing.
        #expect(check.detail?.contains("cacert.pem") == false)
        #expect(!report.ovnReady)
    }

    @Test("NB TLS file check passes when every configured file exists, and is skipped when none are configured")
    func nbTLSFilesPassOrSkip() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.ovnMode = true
        inputs.ovnNBConnection = "ssl:central.example:6641"

        let noFiles = HostPreflight.run(inputs)
        #expect(noFiles.check(.ovnDatabaseTLSFiles) == nil)

        let caPath = "\(root)/cacert.pem"
        FileManager.default.createFile(atPath: caPath, contents: Data())
        inputs.ovnNBTLSFilePaths = [caPath]
        let withFiles = HostPreflight.run(inputs)
        #expect(withFiles.check(.ovnDatabaseTLSFiles)?.passed == true)
    }

    @Test("Missing ovn-appctl is advisory: verification is skipped, capability is not gated")
    func missingOVNAppctlIsAdvisory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let binDir = "\(root)/bin"
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        for tool in ["ip", "ovs-vsctl"] {
            FileManager.default.createFile(
                atPath: "\(binDir)/\(tool)", contents: Data(),
                attributes: [.posixPermissions: 0o755])
        }

        var inputs = passingInputs(root: root)
        inputs.ovnMode = true
        inputs.searchPath = binDir
        for socket in ["ovn.sock", "ovs.sock"] {
            FileManager.default.createFile(atPath: "\(root)/\(socket)", contents: Data())
        }
        inputs.ovnNBConnection = "unix:\(root)/ovn.sock"
        inputs.ovsSocketPath = "\(root)/ovs.sock"

        let report = HostPreflight.run(inputs)
        let check = try #require(report.check(.ovnAppctlTool))
        #expect(!check.passed)
        #expect(check.severity == .advisory)
        #expect(check.detail?.contains("ovn-host") == true)
        // The diagnostic tool being absent must not demote OVN readiness.
        #expect(report.ovnReady)
    }

    // MARK: - Advisory checks

    @Test("Missing firmware is advisory: logged, not gating")
    func missingFirmwareIsAdvisory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.firmwarePath = nil
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.uefiFirmware))
        #expect(!check.passed)
        #expect(check.severity == .advisory)
        #expect(report.storageReady)

        let qemu = HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu)
        #expect(report.gate([qemu]) == [qemu])
    }

    @Test("Low free space is advisory and carries the observed numbers")
    func lowFreeSpaceIsAdvisory() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.minimumFreeDiskBytes = Int64.max
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.storageFreeSpace))
        #expect(!check.passed)
        #expect(check.severity == .advisory)
        #expect(report.storageReady)
    }

    // MARK: - Capability gating

    @Test("Storage failures gate every available hypervisor with the reason")
    func storageFailureGatesHypervisors() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.qemuImgPath = "/nonexistent/qemu-img"
        let report = HostPreflight.run(inputs)
        #expect(!report.storageReady)

        let probes = [
            HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu),
            HypervisorSupport(
                type: .firecracker, available: false, accelerated: false,
                unavailabilityReason: "KVM unavailable", capabilities: .firecracker),
        ]
        let gated = report.gate(probes)

        #expect(gated[0].available == false)
        #expect(gated[0].unavailabilityReason?.contains("host storage not ready") == true)
        #expect(gated[0].unavailabilityReason?.contains("qemu-img") == true)
        // Already-unavailable probes keep their own (more specific) reason.
        #expect(gated[1].unavailabilityReason == "KVM unavailable")
    }

    @Test("A broken Firecracker socket directory gates only Firecracker")
    func firecrackerSocketDirGatesOnlyFirecracker() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: "\(root)/fc", contents: Data())

        var inputs = passingInputs(root: root)
        inputs.firecrackerSocketDirectory = "\(root)/fc/sockets"
        let report = HostPreflight.run(inputs)
        #expect(report.storageReady)

        let probes = [
            HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu),
            HypervisorSupport(type: .firecracker, available: true, accelerated: true, capabilities: .firecracker),
        ]
        let gated = report.gate(probes)

        #expect(gated[0].available)
        #expect(gated[1].available == false)
        #expect(gated[1].unavailabilityReason?.contains("cannot create") == true)
    }
}
