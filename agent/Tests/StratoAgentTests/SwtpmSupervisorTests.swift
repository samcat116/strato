import Foundation
import Logging
import Testing

@testable import StratoAgentCore

/// The vTPM host process (issue #565). The lifecycle itself needs a real swtpm
/// binary, so what is covered here is everything that must hold *without* one:
/// the paths QEMU and teardown agree on, the invocation, and the liveness rule
/// that keeps a replayed create from starting a second swtpm on one state dir.
@Suite("SwtpmSupervisor")
struct SwtpmSupervisorTests {

    private func makeTempDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "swtpm-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("Paths derive from the VM directory alone, so re-adoption can find them")
    func deterministicPaths() {
        let vmDir = "/var/lib/strato/vms/abc"
        #expect(SwtpmSupervisor.socketPath(vmDirectory: vmDir) == "/var/lib/strato/vms/abc/swtpm.sock")
        #expect(SwtpmSupervisor.stateDirectory(vmDirectory: vmDir) == "/var/lib/strato/vms/abc/tpm")
        #expect(SwtpmSupervisor.pidFilePath(vmDirectory: vmDir) == "/var/lib/strato/vms/abc/swtpm.pid")
    }

    @Test("The invocation is a TPM 2.0 socket daemon over the VM's own state and control paths")
    func argumentShape() {
        let vmDir = "/var/lib/strato/vms/abc"
        let arguments = SwtpmSupervisor.arguments(vmDirectory: vmDir)

        #expect(arguments.first == "socket")
        // TPM 1.2 is not what Windows 11 asks for, and swtpm defaults to it.
        #expect(arguments.contains("--tpm2"))
        #expect(arguments.contains("dir=\(vmDir)/tpm"))
        #expect(arguments.contains("type=unixio,path=\(vmDir)/swtpm.sock"))
        #expect(arguments.contains("file=\(vmDir)/swtpm.pid"))
        // Without --daemon the spawn would never return: swtpm serves in the
        // foreground and the agent has no supervisor to park it in.
        #expect(arguments.contains("--daemon"))
    }

    @Test("No pid file means nothing is running")
    func noPIDFileMeansStopped() throws {
        let vmDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: vmDir) }

        let supervisor = SwtpmSupervisor(binaryPath: "/nonexistent/swtpm", logger: Logger(label: "test"))
        #expect(supervisor.runningPID(vmDirectory: vmDir) == nil)
    }

    @Test("A pid file whose process is gone counts as stopped, not running")
    func stalePIDFileIsNotRunning() throws {
        let vmDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: vmDir) }

        // A pid that cannot be live: the agent must treat this as "start a
        // fresh swtpm", not "reuse the one recorded here" — otherwise a VM
        // whose swtpm died would silently boot with no TPM backend at all.
        let stalePID = 0x7FFF_FFFF
        try "\(stalePID)\n".write(
            toFile: SwtpmSupervisor.pidFilePath(vmDirectory: vmDir), atomically: true, encoding: .utf8)

        let supervisor = SwtpmSupervisor(binaryPath: "/nonexistent/swtpm", logger: Logger(label: "test"))
        #expect(supervisor.runningPID(vmDirectory: vmDir) == nil)
    }

    @Test("A live process in the pid file is reported as running")
    func livePIDIsRunning() throws {
        let vmDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: vmDir) }

        // This test process is, definitionally, alive. Reuse rather than
        // respawn is what stops a replayed create from putting two swtpm
        // processes on one state directory.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        try "\(selfPID)".write(
            toFile: SwtpmSupervisor.pidFilePath(vmDirectory: vmDir), atomically: true, encoding: .utf8)

        let supervisor = SwtpmSupervisor(binaryPath: "/nonexistent/swtpm", logger: Logger(label: "test"))
        #expect(supervisor.runningPID(vmDirectory: vmDir) == selfPID)
    }

    @Test("Stopping a VM with no swtpm is a no-op and clears its socket and pid file")
    func stopIsSafeWhenNothingRuns() async throws {
        let vmDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: vmDir) }

        let socketPath = SwtpmSupervisor.socketPath(vmDirectory: vmDir)
        let pidPath = SwtpmSupervisor.pidFilePath(vmDirectory: vmDir)
        let statePath = SwtpmSupervisor.stateDirectory(vmDirectory: vmDir)
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        try "999999999".write(toFile: pidPath, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

        let supervisor = SwtpmSupervisor(binaryPath: "/nonexistent/swtpm", logger: Logger(label: "test"))
        await supervisor.stop(vmDirectory: vmDir, vmId: "vm-1")

        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(!FileManager.default.fileExists(atPath: pidPath))
        // The state directory holds the TPM's seeds; discarding it on stop
        // would break anything the guest sealed to the TPM (BitLocker) on the
        // next start. Only delete removes it.
        #expect(FileManager.default.fileExists(atPath: statePath))
    }
}
