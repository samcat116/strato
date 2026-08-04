import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Libvirt Probe Tests")
struct LibvirtProbeTests {

    // MARK: - Version parsing and ordering

    @Test("Dotted release numbers parse, with an implied patch")
    func parsesVersions() throws {
        #expect(LibvirtProbe.Version("11.5.0") == LibvirtProbe.Version(major: 11, minor: 5, patch: 0))
        #expect(LibvirtProbe.Version("11.5") == LibvirtProbe.Version(major: 11, minor: 5, patch: 0))
        #expect(LibvirtProbe.Version("12") == LibvirtProbe.Version(major: 12, minor: 0, patch: 0))
        #expect(LibvirtProbe.Version("10.0.0")?.description == "10.0.0")
    }

    @Test("Anything that is not a release number is rejected rather than guessed")
    func rejectsNonVersions() throws {
        #expect(LibvirtProbe.Version("") == nil)
        #expect(LibvirtProbe.Version("11.5.0.1") == nil)
        #expect(LibvirtProbe.Version("11.5-rc1") == nil)
        #expect(LibvirtProbe.Version("v11.5.0") == nil)
        #expect(LibvirtProbe.Version("11..0") == nil)
    }

    @Test("Versions order component-wise, not lexically")
    func ordersVersions() throws {
        #expect(LibvirtProbe.Version("10.0.0")! < LibvirtProbe.Version("11.5.0")!)
        // Lexically "9" > "11"; numerically it is not.
        #expect(LibvirtProbe.Version("9.10.0")! < LibvirtProbe.Version("11.5.0")!)
        #expect(LibvirtProbe.Version("11.4.99")! < LibvirtProbe.Version("11.5.0")!)
        #expect(LibvirtProbe.Version("11.5.0")! >= LibvirtProbe.minimumVersion)
        #expect(LibvirtProbe.Version("12.0.0")! >= LibvirtProbe.minimumVersion)
    }

    // MARK: - virsh output parsing

    @Test("The daemon version is read from the daemon line, not the library lines")
    func parsesDaemonVersion() throws {
        // Real `virsh -c qemu:///system version --daemon` output. The client's
        // compiled-against and in-use library versions say nothing about the
        // daemon serving this host, so picking the wrong line would report a
        // version floor pass on a host that cannot meet it.
        let output = """
            Compiled against library: libvirt 12.0.0
            Using library: libvirt 12.0.0
            Using API: QEMU 12.0.0
            Running hypervisor: QEMU 9.2.0
            Running against daemon: 11.5.0

            """
        #expect(LibvirtProbe.daemonVersion(in: output) == LibvirtProbe.Version(major: 11, minor: 5, patch: 0))
    }

    @Test("Output without a daemon line yields no version")
    func noDaemonLine() throws {
        let output = """
            Compiled against library: libvirt 10.0.0
            Using library: libvirt 10.0.0
            """
        #expect(LibvirtProbe.daemonVersion(in: output) == nil)
        #expect(LibvirtProbe.daemonVersion(in: "") == nil)
        #expect(LibvirtProbe.daemonVersion(in: "Running against daemon: unknown") == nil)
    }

    // MARK: - Probing

    @Test("A host with no virsh on PATH reports the client missing, not an unreachable daemon")
    func clientMissingWhenNoVirsh() async throws {
        let status = await LibvirtProbe.probe(searchPath: "/nonexistent-bin")
        #expect(status == .clientMissing)
    }

    @Test("A virsh that fails reports the reason it printed")
    func unreachableReportsStderr() async throws {
        let dir = NSTemporaryDirectory() + "libvirt-probe-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Stands in for a virsh that cannot reach the daemon.
        let script = """
            #!/bin/sh
            echo "error: failed to connect to the hypervisor" >&2
            exit 1
            """
        let path = "\(dir)/virsh"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        let status = await LibvirtProbe.probe(searchPath: dir)
        #expect(status == .unreachable("error: failed to connect to the hypervisor"))
    }

    @Test("A virsh that connects but prints nothing parseable is unreachable, not silently accepted")
    func unparseableOutputIsUnreachable() async throws {
        let dir = NSTemporaryDirectory() + "libvirt-probe-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = "\(dir)/virsh"
        try "#!/bin/sh\necho 'Using library: libvirt 12.0.0'\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        let status = await LibvirtProbe.probe(searchPath: dir)
        guard case .unreachable(let detail) = status else {
            Issue.record("expected .unreachable, got \(status)")
            return
        }
        #expect(detail.contains("could not read the daemon version"))
    }

    @Test("A connecting virsh reports the daemon's version")
    func reachableReportsVersion() async throws {
        let dir = NSTemporaryDirectory() + "libvirt-probe-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = "\(dir)/virsh"
        try "#!/bin/sh\necho 'Running against daemon: 12.0.0'\n".write(
            toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)

        let status = await LibvirtProbe.probe(searchPath: dir)
        #expect(status == .reachable(LibvirtProbe.Version(major: 12, minor: 0, patch: 0)))
    }
}
