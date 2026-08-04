import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Libvirt Probe Tests")
struct LibvirtProbeTests {

    private func makeStubDirectory() throws -> String {
        let dir = NSTemporaryDirectory() + "libvirt-probe-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Drops a stub `virsh` on a directory used as the probe's search path, so
    /// the probe's own PATH lookup and subprocess handling are exercised rather
    /// than mocked.
    private func writeStubVirsh(in directory: String, script: String) throws {
        let path = "\(directory)/virsh"
        try "#!/bin/sh\n\(script)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

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

    @Test("A translated daemon line does not parse — which is why the probe pins the C locale")
    func translatedOutputDoesNotParse() throws {
        // virsh prints the marker through gettext. This documents the failure
        // mode `cLocaleEnvironment` exists to prevent: without it, a host whose
        // locale has a libvirt catalog reports a healthy daemon as unusable.
        let french = "Exécution sur le démon : 11.5.0"
        #expect(LibvirtProbe.daemonVersion(in: french) == nil)
    }

    @Test("The probe's child environment pins LC_ALL and drops LANGUAGE")
    func cLocaleEnvironment() throws {
        let environment = LibvirtProbe.cLocaleEnvironment(inheriting: [
            "PATH": "/usr/bin", "LANG": "fr_FR.UTF-8", "LC_MESSAGES": "fr_FR.UTF-8",
            "LANGUAGE": "fr", "XDG_RUNTIME_DIR": "/run/user/1000",
        ])

        #expect(environment["LC_ALL"] == "C")
        #expect(environment["LANGUAGE"] == nil)
        // Inherited, not replaced: virsh needs PATH and the session's runtime
        // directory as much as any other child.
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["XDG_RUNTIME_DIR"] == "/run/user/1000")
    }

    // MARK: - Probing

    @Test("A host with no virsh on PATH reports the client missing, not an unreachable daemon")
    func clientMissingWhenNoVirsh() async throws {
        let status = await LibvirtProbe.probe(searchPath: "/nonexistent-bin")
        #expect(status == .clientMissing)
    }

    @Test("A virsh that fails reports the reason it printed")
    func unreachableReportsStderr() async throws {
        let dir = try makeStubDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Stands in for a virsh that cannot reach the daemon.
        try writeStubVirsh(
            in: dir,
            script: """
                echo "error: failed to connect to the hypervisor" >&2
                exit 1
                """)

        let status = await LibvirtProbe.probe(searchPath: dir)
        #expect(status == .unreachable("error: failed to connect to the hypervisor"))
    }

    @Test("A virsh that connects but prints nothing parseable is reported separately from unreachable")
    func unparseableOutputIsItsOwnState() async throws {
        let dir = try makeStubDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeStubVirsh(in: dir, script: "echo 'Using library: libvirt 12.0.0'")

        let status = await LibvirtProbe.probe(searchPath: dir)
        // Not `.unreachable`: the daemon answered, so advising someone to start
        // it or join the libvirt group would be wrong.
        #expect(status == .unrecognizedOutput("Using library: libvirt 12.0.0"))
    }

    @Test("A virsh that never exits is bounded by the probe timeout")
    func hangingVirshTimesOut() async throws {
        let dir = try makeStubDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // `exec` so the sleep *is* the child rather than a grandchild holding the
        // pipes open: same timeout path, without waiting out ProcessRunner's
        // drain deadline for an orphan it cannot signal.
        try writeStubVirsh(in: dir, script: "exec sleep 60")

        let status = await LibvirtProbe.probe(searchPath: dir, timeout: .milliseconds(300))
        // The registration path cannot afford to park on a wedged libvirtd, and
        // the operator needs to see *why* the check failed, not a bare timeout.
        guard case .unreachable(let detail) = status else {
            Issue.record("expected .unreachable, got \(status)")
            return
        }
        #expect(detail.contains("virsh"))
    }

    @Test("The daemon version is read under a forced C locale, whatever the parent's locale")
    func forcesCLocaleOnTheChild() async throws {
        let dir = try makeStubDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Stands in for a real virsh, which prints the marker through gettext:
        // English only when the message locale is C.
        try writeStubVirsh(
            in: dir,
            script: """
                if [ "$LC_ALL" = "C" ]; then
                  echo 'Running against daemon: 12.0.0'
                else
                  echo 'Exécution sur le démon : 12.0.0'
                fi
                """)

        let status = await LibvirtProbe.probe(searchPath: dir)
        #expect(status == .reachable(LibvirtProbe.Version(major: 12, minor: 0, patch: 0)))
    }

    @Test("A connecting virsh reports the daemon's version")
    func reachableReportsVersion() async throws {
        let dir = try makeStubDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeStubVirsh(in: dir, script: "echo 'Running against daemon: 12.0.0'")

        let status = await LibvirtProbe.probe(searchPath: dir)
        #expect(status == .reachable(LibvirtProbe.Version(major: 12, minor: 0, patch: 0)))
    }
}
