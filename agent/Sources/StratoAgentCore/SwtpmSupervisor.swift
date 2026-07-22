import Foundation
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Runs the per-VM `swtpm` process that backs a guest's emulated TPM 2.0
/// (issue #565).
///
/// One swtpm per VM, living in the VM's own directory alongside its disks and
/// sockets:
///
/// ```
/// <vmStoragePath>/<vmId>/tpm/        TPM state (EK/SRK seeds, NV storage)
/// <vmStoragePath>/<vmId>/swtpm.sock  control channel QEMU's tpmdev connects to
/// <vmStoragePath>/<vmId>/swtpm.pid   pid file, so teardown and re-adoption
///                                    can find a process this agent did not spawn
/// ```
///
/// The state directory is durable on purpose: a TPM whose seeds change across a
/// restart invalidates everything sealed to it, which for a Windows guest means
/// BitLocker demanding its recovery key.
///
/// ## Lifetime, and what happens across an agent restart
///
/// swtpm is spawned with `--daemon`, so it reparents to init and survives the
/// agent exactly like QEMU does — a re-adopted VM keeps talking to the swtpm a
/// previous agent incarnation started, which is why `ensureRunning` is
/// idempotent against a live pid file rather than starting a second process.
///
/// The converse does not hold: a *dead* swtpm under a live QEMU cannot be
/// recovered mid-flight, because the guest's TPM sessions live in the process
/// that died. Such a VM needs a stop/start; its state directory is intact, so
/// nothing sealed to the TPM is lost.
public struct SwtpmSupervisor: Sendable {
    private let binaryPath: String
    private let logger: Logger

    public init(binaryPath: String, logger: Logger) {
        self.binaryPath = binaryPath
        self.logger = logger
    }

    // MARK: - Deterministic paths

    /// The control-channel socket QEMU's `-tpmdev emulator` chardev connects
    /// to. Derived only from the VM directory, so it resolves for re-adopted
    /// VMs too.
    public static func socketPath(vmDirectory: String) -> String {
        (vmDirectory as NSString).appendingPathComponent("swtpm.sock")
    }

    /// Where the TPM's persistent state lives.
    public static func stateDirectory(vmDirectory: String) -> String {
        (vmDirectory as NSString).appendingPathComponent("tpm")
    }

    public static func pidFilePath(vmDirectory: String) -> String {
        (vmDirectory as NSString).appendingPathComponent("swtpm.pid")
    }

    static func logFilePath(vmDirectory: String) -> String {
        (vmDirectory as NSString).appendingPathComponent("swtpm.log")
    }

    // MARK: - Lifecycle

    public enum SwtpmError: Error, CustomStringConvertible, Sendable {
        case launchFailed(String)
        case socketNeverAppeared(String)

        public var description: String {
            switch self {
            case .launchFailed(let detail):
                return "failed to start swtpm: \(detail)"
            case .socketNeverAppeared(let path):
                return "swtpm started but never created its control socket at \(path)"
            }
        }
    }

    /// Starts swtpm for `vmId` if it is not already running, and returns the
    /// control socket path to hand to QEMU.
    ///
    /// Idempotent: a live process recorded in the pid file is reused, so a
    /// replayed create — or a `bootVM` respawn after the guest powered off —
    /// never leaves two swtpm processes fighting over one state directory.
    @discardableResult
    public func ensureRunning(vmDirectory: String, vmId: String) async throws -> String {
        let socketPath = Self.socketPath(vmDirectory: vmDirectory)
        if let pid = runningPID(vmDirectory: vmDirectory) {
            logger.debug(
                "Reusing running swtpm",
                metadata: ["vmId": .string(vmId), "pid": .stringConvertible(pid)])
            return socketPath
        }

        let stateDirectory = Self.stateDirectory(vmDirectory: vmDirectory)
        try FileManager.default.createDirectory(
            atPath: stateDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // A socket left by a dead process would let QEMU connect to nothing.
        try? FileManager.default.removeItem(atPath: socketPath)

        let arguments = Self.arguments(vmDirectory: vmDirectory)
        logger.info(
            "Starting swtpm",
            metadata: [
                "vmId": .string(vmId),
                "socket": .string(socketPath),
                "stateDir": .string(stateDirectory),
            ])

        let result: ProcessResult
        do {
            // `--daemon` makes swtpm fork and reparent, so this call returns as
            // soon as the parent exits — it is not a long-lived wait.
            result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: binaryPath),
                arguments: arguments,
                timeout: .seconds(15))
        } catch {
            throw SwtpmError.launchFailed(error.localizedDescription)
        }
        guard result.terminationStatus == 0 else {
            throw SwtpmError.launchFailed(
                "\(binaryPath) exited \(result.terminationStatus): "
                    + result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard await waitForSocket(at: socketPath) else {
            throw SwtpmError.socketNeverAppeared(socketPath)
        }
        return socketPath
    }

    /// The swtpm invocation for a VM. Split out so tests can assert the
    /// argument shape without a swtpm binary on the host.
    public static func arguments(vmDirectory: String) -> [String] {
        [
            "socket",
            "--tpm2",
            "--tpmstate", "dir=\(stateDirectory(vmDirectory: vmDirectory))",
            "--ctrl", "type=unixio,path=\(socketPath(vmDirectory: vmDirectory))",
            "--pid", "file=\(pidFilePath(vmDirectory: vmDirectory))",
            "--log", "file=\(logFilePath(vmDirectory: vmDirectory)),level=1",
            "--daemon",
        ]
    }

    /// Stops the VM's swtpm and removes its socket and pid file. The state
    /// directory is left alone — `deleteVM` removes the whole VM directory, and
    /// a stop that discarded TPM state would silently break BitLocker on the
    /// next start.
    public func stop(vmDirectory: String, vmId: String) async {
        defer {
            try? FileManager.default.removeItem(atPath: Self.socketPath(vmDirectory: vmDirectory))
            try? FileManager.default.removeItem(atPath: Self.pidFilePath(vmDirectory: vmDirectory))
        }
        guard let pid = runningPID(vmDirectory: vmDirectory) else { return }

        logger.info("Stopping swtpm", metadata: ["vmId": .string(vmId), "pid": .stringConvertible(pid)])
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if !processIsAlive(pid) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        logger.warning(
            "swtpm did not exit after SIGTERM; killing",
            metadata: ["vmId": .string(vmId), "pid": .stringConvertible(pid)])
        kill(pid, SIGKILL)
    }

    /// The pid of a live swtpm for this VM, or nil when none is running.
    /// A pid file whose process is gone counts as not running.
    public func runningPID(vmDirectory: String) -> pid_t? {
        let pidFile = Self.pidFilePath(vmDirectory: vmDirectory)
        guard let contents = try? String(contentsOfFile: pidFile, encoding: .utf8),
            let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0,
            processIsAlive(pid)
        else {
            return nil
        }
        return pid
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        // ESRCH means gone; EPERM means alive but owned by someone else, which
        // still counts as running (and is what a re-adopted VM's swtpm looks
        // like when the agent dropped privileges between incarnations).
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForSocket(at path: String) async -> Bool {
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return FileManager.default.fileExists(atPath: path)
    }
}
