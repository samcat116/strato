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
    /// root, `/bin/ls` standing in for qemu-img, a libvirt above the floor, no
    /// OVN, no free-space floor.
    ///
    /// `libvirt` has to be set for this to be a genuinely passing baseline: the
    /// vTPM check reports "not checked" without a usable daemon, because on such
    /// a host nothing asked it.
    private func passingInputs(root: String) -> HostPreflight.Inputs {
        HostPreflight.Inputs(
            vmStoragePath: "\(root)/vms",
            volumeStoragePath: "\(root)/volumes",
            imageCachePath: "\(root)/images",
            qemuImgPath: "/bin/ls",
            firmwarePath: "/bin/ls",
            tpmSupport: .supported,
            libvirt: .reachable(LibvirtProbe.minimumVersion),
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

    @Test(
        "No vTPM backend is advisory and only withholds the TPM capability",
        arguments: [LibvirtProbe.TPMSupport.unsupported, .unknown("virsh not found on PATH")])
    func missingTPMSupportIsAdvisory(_ support: LibvirtProbe.TPMSupport) throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.tpmSupport = support
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.vtpmSupport))
        #expect(!check.passed)
        #expect(check.severity == .advisory)
        // The remedy is the same either way, and it includes the restart:
        // libvirtd caches its capabilities, so installing the package alone
        // leaves the host still refusing to advertise a TPM.
        #expect(check.detail?.contains("apt install swtpm swtpm-tools") == true)
        #expect(check.detail?.contains("restart libvirtd") == true)
        // A host with no vTPM runs every VM that doesn't ask for one exactly as
        // before, so nothing about it may gate the hypervisor.
        #expect(!report.tpmAvailable)
        #expect(report.storageReady)

        let qemu = HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu)
        #expect(report.gate([qemu]) == [qemu])
    }

    /// A host whose libvirt is unusable was never asked about a vTPM, and the
    /// gating libvirt failure directly above already says what to fix. Telling
    /// that operator to install swtpm would be a second message contradicting
    /// the first.
    @Test("an unusable libvirt suppresses the swtpm remedy rather than adding to it")
    func unusableLibvirtSuppressesTheTPMRemedy() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.libvirt = .clientMissing
        inputs.tpmSupport = .unknown("virsh not found on PATH")
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.vtpmSupport))
        #expect(!check.passed)
        #expect(check.severity == .advisory)
        #expect(check.detail?.contains("not checked") == true)
        #expect(check.detail?.contains("apt install swtpm") == false)
        // And the gating failure it defers to is in the report, ahead of it.
        let kinds = report.checks.map(\.kind)
        #expect(kinds.firstIndex(of: .libvirtConnection)! < kinds.firstIndex(of: .vtpmSupport)!)
    }

    /// The two failures are not the same fact, and an operator told to install
    /// swtpm on a host whose libvirtd simply never answered would go after the
    /// wrong thing.
    @Test("'libvirt says no' and 'we could not ask' read differently")
    func tpmFailuresAreDistinguishable() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.tpmSupport = .unsupported
        #expect(HostPreflight.run(inputs).check(.vtpmSupport)?.detail?.contains("reports no emulated TPM") == true)

        inputs.tpmSupport = .unknown("virsh exited 1")
        let unknown = try #require(HostPreflight.run(inputs).check(.vtpmSupport))
        #expect(unknown.detail?.contains("could not ask libvirt") == true)
        #expect(unknown.detail?.contains("virsh exited 1") == true)
    }

    @Test("An emulated TPM backend lights up the TPM capability")
    func supportedTPMIsReported() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let report = HostPreflight.run(passingInputs(root: root))
        #expect(report.tpmAvailable)
    }

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

    // MARK: - libvirt

    @Test("No libvirt probe result skips both libvirt checks")
    func libvirtChecksSkippedWhenNotProbed() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Nil is the non-Linux case, where libvirt cannot exist.
        var inputs = passingInputs(root: root)
        inputs.libvirt = nil
        let report = HostPreflight.run(inputs)

        #expect(report.check(.libvirtConnection) == nil)
        #expect(report.check(.libvirtVersion) == nil)
        // A host that was never asked about libvirt must not read as broken:
        // `HypervisorProbe.qemuReport` already reports `.qemu` unavailable
        // there, so there is nothing left for the gate to do.
        #expect(report.libvirtReady)
        #expect(report.libvirtFailureDetail == nil)
        // The vTPM answer is still unknown, and says why without sending anyone
        // after swtpm on a host that has no libvirt to run it.
        #expect(report.check(.vtpmSupport)?.detail?.contains("not checked") == true)
        #expect(!report.tpmAvailable)
    }

    @Test("A libvirt new enough to drive passes both checks")
    func reachableLibvirtPasses() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.libvirt = .reachable(LibvirtProbe.Version(major: 12, minor: 0, patch: 0))
        let report = HostPreflight.run(inputs)

        #expect(report.failures.isEmpty)
        #expect(report.libvirtReady)
    }

    @Test("An uninstalled libvirt reports how to install it")
    func missingLibvirtIsReported() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.libvirt = .clientMissing
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.libvirtConnection))
        #expect(!check.passed)
        #expect(check.detail?.contains("libvirt-daemon-system") == true)
        #expect(!report.libvirtReady)
        // The version check is not reported at all: there is no version to
        // compare, and two failures for one cause is noise.
        #expect(report.check(.libvirtVersion) == nil)
    }

    @Test("An unreachable libvirtd names the daemon error and the socket-permission fix")
    func unreachableLibvirtIsReported() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.libvirt = .unreachable("Failed to connect socket to '/var/run/libvirt/virtqemud-sock'")
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.libvirtConnection))
        #expect(!check.passed)
        #expect(check.detail?.contains("virtqemud-sock") == true)
        #expect(check.detail?.contains("libvirt` group") == true)
        #expect(report.libvirtFailureDetail == check.detail)
    }

    @Test("A libvirt below the version floor fails with the OS requirement, having connected fine")
    func oldLibvirtFailsVersionFloor() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        // Ubuntu 24.04's libvirt: reachable, and too old to snapshot UEFI guests.
        inputs.libvirt = .reachable(LibvirtProbe.Version(major: 10, minor: 0, patch: 0))
        let report = HostPreflight.run(inputs)

        #expect(report.check(.libvirtConnection)?.passed == true)
        let version = try #require(report.check(.libvirtVersion))
        #expect(!version.passed)
        #expect(version.detail?.contains("10.0.0") == true)
        #expect(version.detail?.contains("11.5.0") == true)
        #expect(version.detail?.contains("Ubuntu 24.04") == true)
        #expect(!report.libvirtReady)
    }

    @Test("The version floor is exclusive of older patch releases only")
    func versionFloorBoundary() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // 11.5.0 exactly is enough; 11.4.99 is not.
        for (version, ready) in [
            (LibvirtProbe.Version(major: 11, minor: 5, patch: 0), true),
            (LibvirtProbe.Version(major: 11, minor: 4, patch: 99), false),
            (LibvirtProbe.Version(major: 11, minor: 5, patch: 1), true),
        ] {
            var inputs = passingInputs(root: root)
            inputs.libvirt = .reachable(version)
            #expect(HostPreflight.run(inputs).libvirtReady == ready, "libvirt \(version)")
        }
    }

    /// There is no second QEMU driver to hedge for (STR-136): a host that
    /// cannot reach libvirtd cannot run a VM, so the check is gating outright
    /// and the message reads as a live fault rather than a heads-up.
    @Test("libvirt failures are gating, with no not-yet-required wording left")
    func libvirtFailuresAreGating() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.libvirt = .clientMissing
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.libvirtConnection))
        #expect(check.severity == .gating)
        #expect(check.detail?.contains("this node does not use") == false)
        #expect(check.detail?.contains("apt install libvirt-daemon-system") == true)
    }

    /// A node whose QEMU placements are realized through libvirtd cannot serve
    /// them with the daemon unreachable, so it must stop attracting them —
    /// rather than accepting a VM and failing every operation on it.
    @Test("An unusable libvirt takes a libvirt-driver node out of service for QEMU")
    func unusableLibvirtGatesQEMUOnLibvirtNodes() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let qemu = HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu)
        let firecracker = HypervisorSupport(
            type: .firecracker, available: true, accelerated: true, capabilities: .firecracker)

        var inputs = passingInputs(root: root)
        inputs.libvirt = .reachable(LibvirtProbe.Version(major: 10, minor: 0, patch: 0))
        let gated = HostPreflight.run(inputs).gate([qemu, firecracker])

        #expect(gated[0].available == false)
        #expect(gated[0].unavailabilityReason?.contains("libvirt not usable") == true)
        // Only the QEMU driver goes through libvirtd; Firecracker is untouched.
        #expect(gated[1] == firecracker)

        // And a libvirt that is fine leaves both alone.
        inputs.libvirt = .reachable(LibvirtProbe.Version(major: 12, minor: 0, patch: 0))
        #expect(HostPreflight.run(inputs).gate([qemu, firecracker]) == [qemu, firecracker])
    }

    @Test("A daemon that answered unparseably is not told to start itself")
    func unrecognizedLibvirtOutputGetsHonestRemediation() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.libvirt = .unrecognizedOutput("Using library: libvirt 12.0.0")
        let report = HostPreflight.run(inputs)

        let check = try #require(report.check(.libvirtConnection))
        #expect(!check.passed)
        #expect(check.detail?.contains("Using library: libvirt 12.0.0") == true)
        // The connection succeeded, so none of the unreachable remediation applies.
        #expect(check.detail?.contains("libvirt` group") == false)
        #expect(check.detail?.contains("Start the daemon") == false)
        #expect(!report.libvirtReady)
    }

    // MARK: - QEMU firmware descriptors

    @Test("Firmware descriptors present pass; an empty directory is advisory")
    func firmwareDescriptorChecks() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let descriptors = "\(root)/firmware"
        try FileManager.default.createDirectory(atPath: descriptors, withIntermediateDirectories: true)

        var inputs = passingInputs(root: root)
        inputs.qemuFirmwareDescriptorPath = descriptors
        let empty = HostPreflight.run(inputs)
        let check = try #require(empty.check(.qemuFirmwareDescriptors))
        #expect(!check.passed)
        #expect(check.severity == .advisory)
        #expect(empty.storageReady)

        FileManager.default.createFile(atPath: "\(descriptors)/60-edk2-x86_64.json", contents: Data())
        #expect(HostPreflight.run(inputs).check(.qemuFirmwareDescriptors)?.passed == true)
    }

    @Test("A missing firmware descriptor directory is advisory, not a crash")
    func firmwareDescriptorDirectoryMissing() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }

        var inputs = passingInputs(root: root)
        inputs.qemuFirmwareDescriptorPath = "\(root)/nonexistent"
        let check = try #require(HostPreflight.run(inputs).check(.qemuFirmwareDescriptors))
        #expect(!check.passed)
        #expect(check.severity == .advisory)
    }

    @Test("A globally strict rp_filter is reported, because it overrides the per-device one")
    func globalStrictReversePathFilterIsReported() {
        // The kernel validates against `max(conf.all, conf.<dev>)`, so the
        // loose value `ResolverHostPortPlan` sets on the resolver's foot does
        // nothing on a host whose `all` is 1 — every guest query is dropped and
        // nothing on the host says why. Advisory rather than fixed: lowering
        // `all` would weaken source validation on the hypervisor's own NICs.
        let strict = HostPreflight.checkGlobalReversePathFilter(1)
        #expect(!strict.passed)
        #expect(strict.severity == .advisory)
        #expect(strict.detail?.contains("net.ipv4.conf.all.rp_filter") == true)
    }

    @Test("Loose, disabled, and unreadable rp_filter all pass")
    func acceptableReversePathFilterValues() {
        // 2 is loose and 0 disables validation entirely (Ubuntu's default);
        // nil is a kernel or platform that does not expose the knob, which is
        // not a misconfiguration.
        #expect(HostPreflight.checkGlobalReversePathFilter(2).passed)
        #expect(HostPreflight.checkGlobalReversePathFilter(0).passed)
        #expect(HostPreflight.checkGlobalReversePathFilter(nil).passed)
    }
}
