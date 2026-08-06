import Foundation
import Logging
import NIOCore
import NIOPosix
import StratoAgentCore
import StratoShared

#if canImport(SwiftQEMU)
import SwiftQEMU

// Orphan re-adoption (reconciliation phase 2, issue #260).
//
// `QEMUManager` can only drive a QEMU process it spawned itself: its QMP
// socket lives in a private per-instance directory under the process's runtime
// directory, and there is no connect-to-existing API.
// So `QEMUService` gives every VM a *second*, deterministic QMP monitor at
// `<vmStoragePath>/<vmId>/qmp.sock` (QEMU supports multiple `-qmp` sockets),
// and after an agent restart an orphan is re-adopted by attaching a fresh
// `QMPClient` to that socket. `QEMUVMHandle` abstracts over the two kinds of
// handle so the rest of QEMUService doesn't care whether it spawned the
// process or inherited it.

/// The operations QEMUService needs from a VM's control session, satisfied by
/// both a spawning `QEMUManager` and a re-adopted `AdoptedQEMUVM`.
protocol QEMUVMHandle: Sendable {
    func start() async throws
    func pause() async throws
    func reset() async throws
    /// - Parameter timeout: how long the guest gets to power itself off before
    ///   termination is forced.
    func shutdown(timeout: Duration) async throws
    /// - Parameter terminationTimeout: how long QEMU gets to honour SIGTERM
    ///   before it is killed outright, and again after SIGKILL.
    func destroy(terminationTimeout: Duration) async throws
    func getStatus() async throws -> QEMUVMStatus
    /// - Parameter bus: the bus to hot-plug onto, or `nil` to let the handle
    ///   pick — which on a machine type whose default bus refuses hot-plug
    ///   (q35, arm `virt`) means one of the `pcie-root-port` devices the VM was
    ///   launched with.
    func attachDisk(path: String, deviceName: String, readOnly: Bool, bus: String?) async throws
    /// - Parameter timeout: how long to wait for QEMU's `DEVICE_DELETED` before
    ///   giving up. Hot-unplug needs the guest to release the device, so a guest
    ///   that ignores the request never answers.
    func detachDisk(deviceName: String, timeout: Duration) async throws
}

/// The defaults SwiftQEMU spells as default arguments, which a protocol
/// requirement cannot carry. They are kept deliberately shorter than the
/// `StageBudget` each call site wraps these in, so the handle's own escalation
/// (force-quit on a guest that won't shut down, SIGKILL on one that won't die)
/// gets to run before the outer budget abandons the call.
extension QEMUVMHandle {
    func shutdown() async throws { try await shutdown(timeout: .seconds(30)) }

    func destroy() async throws {
        try await destroy(terminationTimeout: QEMUProcess.defaultTerminationTimeout)
    }

    func attachDisk(path: String, deviceName: String, readOnly: Bool) async throws {
        try await attachDisk(path: path, deviceName: deviceName, readOnly: readOnly, bus: nil)
    }

    func detachDisk(deviceName: String) async throws {
        try await detachDisk(deviceName: deviceName, timeout: .seconds(5))
    }
}

extension QEMUManager: QEMUVMHandle {}

/// A QEMU VM inherited from a previous agent incarnation, driven purely over
/// its deterministic QMP socket. Unlike `QEMUManager` there is no `Process`
/// handle: lifecycle actions that QEMUManager implements via the child
/// process (waiting for exit, terminating) are done via QMP and status
/// polling instead.
actor AdoptedQEMUVM: QEMUVMHandle {
    private let qmp: QMPClient
    private let socketPath: String
    private let logger: Logger
    private var isConnected = false

    init(socketPath: String, logger: Logger) {
        self.socketPath = socketPath
        self.logger = logger
        self.qmp = QMPClient(logger: logger)
    }

    /// Attach to the running process's QMP socket and return its status.
    /// Throws if the socket cannot be connected (e.g. the process died and
    /// left a stale socket file) — the caller decides what to do with the
    /// still-orphaned VM.
    func connect() async throws -> QEMUVMStatus {
        try await qmp.connectUnix(path: socketPath)
        isConnected = true
        let status = try await queryStatus()
        logger.info(
            "Re-adopted QEMU VM via deterministic QMP socket",
            metadata: [
                "socket": .string(socketPath),
                "status": .string(status.rawValue),
            ])
        return status
    }

    func start() async throws {
        guard isConnected else { throw QMPError.notConnected }
        try await qmp.cont()
    }

    func pause() async throws {
        guard isConnected else { throw QMPError.notConnected }
        try await qmp.stop()
    }

    func reset() async throws {
        guard isConnected else { throw QMPError.notConnected }
        try await qmp.systemReset()
    }

    /// Graceful shutdown. With no child-process handle to wait on, completion
    /// is detected by polling status until the process exits (the QMP
    /// connection drops) or reports shutdown; once `timeout` is spent the VM is
    /// destroyed, matching `QEMUManager.shutdown`'s force-quit fallback.
    func shutdown(timeout: Duration) async throws {
        guard isConnected else { throw QMPError.notConnected }
        try await qmp.systemPowerdown()

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            do {
                let response = try await qmp.queryStatus()
                if ["shutdown", "poweroff"].contains(response.status.lowercased()) {
                    return
                }
            } catch {
                // Connection dropped: the process exited.
                isConnected = false
                return
            }
        }

        logger.warning("Adopted VM did not shut down gracefully, forcing termination")
        try await destroy(terminationTimeout: QEMUProcess.defaultTerminationTimeout)
    }

    /// Force quit, returning only once the process is confirmed gone.
    ///
    /// There is no child-process handle here, so `quit` over QMP is the only
    /// lever — nothing to escalate to. What `terminationTimeout` bounds is
    /// therefore not an escalation but the wait for the exit: `quit` itself
    /// cannot report one. It legitimately errors on the *success* path (QEMU
    /// can exit before it replies), so its failure is swallowed — and callers
    /// act on this return by unlinking the VM's disk (STR-179), which a guest
    /// still running would keep executing from unlinked inodes.
    func destroy(terminationTimeout: Duration) async throws {
        if isConnected {
            do {
                try await qmp.quit()
            } catch {
                logger.debug("QMP quit failed, process may already be terminating")
            }
            try? await qmp.disconnect()
            isConnected = false
        }
        try await waitForExit(within: terminationTimeout)
        // The adopting side owns the deterministic socket file's cleanup. Only
        // once the process is gone: unlinking it while QEMU still holds the
        // listener would make every later probe fail for the wrong reason.
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Waits for the QEMU process behind `socketPath` to exit.
    ///
    /// The listening socket is the evidence: a connect succeeds only while a
    /// process holds it, and is refused (or the path is gone, QEMU unlinks it
    /// on the way out) the moment one does not. Deliberately a bare connect
    /// with no QMP negotiation — whether the peer still speaks the protocol is
    /// a different question from whether it exists, and a wedged QEMU that
    /// answers neither is exactly the case this must not read as dead.
    private func waitForExit(within timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while await Self.socketIsListening(path: socketPath) {
            guard ContinuousClock.now < deadline else {
                throw HypervisorServiceError.timeout(
                    "QEMU behind \(socketPath) was still running \(timeout) after quit")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func socketIsListening(path: String) async -> Bool {
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        guard let channel = try? await bootstrap.connect(unixDomainSocketPath: path).get() else {
            return false
        }
        try? await channel.close().get()
        return true
    }

    func getStatus() async throws -> QEMUVMStatus {
        guard isConnected else { return .stopped }
        return try await queryStatus()
    }

    /// Hot-plug, without the port bookkeeping `QEMUManager` keeps.
    ///
    /// q35 and arm `virt` refuse hot-plug on their default bus, so the disk has
    /// to name one of the `pcie-root-port` devices the VM was launched with. A
    /// spawning `QEMUManager` remembers which of those it has handed out; an
    /// adopted VM cannot — that state died with the previous agent process, and
    /// SwiftQEMU's command vocabulary has no `query-pci` to rebuild it from. So
    /// the ports are tried in order and QEMU arbitrates: a port already holding
    /// a device rejects the second with `slot 0 function 0 already occupied`.
    /// `nil` comes last, for a machine type whose default bus does accept
    /// hot-plug and where none of these ports exist at all.
    func attachDisk(path: String, deviceName: String, readOnly: Bool, bus: String?) async throws {
        guard isConnected else { throw QMPError.notConnected }
        let nodeName = "drive-\(deviceName)"

        let candidates: [String?] = if let bus { [bus] } else { Self.hotplugPortCandidates }

        try await qmp.blockdevAdd(nodeName: nodeName, filename: path, readOnly: readOnly)

        // The *first* failure is the one worth reporting. Walking the list is
        // normal — an occupied port is how a busy pool answers — so the last
        // error is whatever the machine-default attempt said, which is the
        // least informative of the candidates. A real fault (a bad path, a
        // dropped connection, a duplicate device id) shows up on the first
        // attempt and would otherwise be buried by four follow-on rejections.
        var firstError: (any Error)?
        for candidate in candidates {
            do {
                try await qmp.deviceAdd(deviceId: deviceName, driveId: nodeName, bus: candidate)
                return
            } catch {
                if firstError == nil { firstError = error }
                logger.debug(
                    "Hot-plug port rejected the disk; trying the next one",
                    metadata: [
                        "deviceName": .string(deviceName),
                        "bus": .string(candidate ?? "<machine default>"),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        try? await qmp.blockdevDel(nodeName: nodeName)
        throw firstError ?? QMPError.invalidConfiguration
    }

    func detachDisk(deviceName: String, timeout: Duration) async throws {
        guard isConnected else { throw QMPError.notConnected }
        let nodeName = "drive-\(deviceName)"
        try await qmp.deviceDel(deviceId: deviceName, timeout: timeout)
        try await qmp.blockdevDel(nodeName: nodeName)
    }

    /// The buses `attachDisk` tries, in order, when the caller names none.
    ///
    /// The port ids are derived from a default `QEMUConfiguration` rather than
    /// hard-coded, so they track SwiftQEMU's own naming. Deriving them from the
    /// *default* configuration is sound because the list does not vary across
    /// the machine types this agent spawns: q35 on x86 and `virt` on arm64 both
    /// need root ports, and both therefore get the same
    /// `automaticHotplugPortCount` ids.
    private static let hotplugPortCandidates: [String?] =
        QEMUConfiguration().hotplugPortIDs.map { $0 } + [nil]

    /// Same QMP status mapping as `QEMUManager.updateStatus`, minus the
    /// stateful bookkeeping.
    private func queryStatus() async throws -> QEMUVMStatus {
        let response = try await qmp.queryStatus()
        switch response.status.lowercased() {
        case "running":
            return response.running ? .running : .paused
        case "paused", "suspended":
            return .paused
        case "shutdown", "poweroff":
            return .stopped
        case "inmigrate", "prelaunch":
            return .creating
        default:
            logger.warning("Unknown QMP status: \(response.status)")
            return .unknown
        }
    }
}
#endif
