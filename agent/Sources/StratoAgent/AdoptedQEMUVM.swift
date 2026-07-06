import Foundation
import Logging
import StratoShared

#if canImport(SwiftQEMU)
import SwiftQEMU

// Orphan re-adoption (reconciliation phase 2, issue #260).
//
// `QEMUManager` can only drive a QEMU process it spawned itself: its QMP
// socket lives at a random /tmp path and there is no connect-to-existing API.
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
    func shutdown() async throws
    func destroy() async throws
    func getStatus() async throws -> QEMUVMStatus
    func attachDisk(path: String, deviceName: String, readOnly: Bool) async throws
    func detachDisk(deviceName: String) async throws
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
    /// connection drops) or reports shutdown; after 30s the VM is destroyed,
    /// matching `QEMUManager.shutdown`'s force-quit fallback.
    func shutdown() async throws {
        guard isConnected else { throw QMPError.notConnected }
        try await qmp.systemPowerdown()

        for _ in 0..<30 {
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
        try await destroy()
    }

    func destroy() async throws {
        if isConnected {
            do {
                try await qmp.quit()
            } catch {
                logger.debug("QMP quit failed, process may already be terminating")
            }
            try? await qmp.disconnect()
            isConnected = false
        }
        // The adopting side owns the deterministic socket file's cleanup.
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func getStatus() async throws -> QEMUVMStatus {
        guard isConnected else { return .stopped }
        return try await queryStatus()
    }

    func attachDisk(path: String, deviceName: String, readOnly: Bool) async throws {
        guard isConnected else { throw QMPError.notConnected }
        let nodeName = "drive-\(deviceName)"
        try await qmp.blockdevAdd(nodeName: nodeName, filename: path, readOnly: readOnly)
        do {
            try await qmp.deviceAdd(deviceId: deviceName, driveId: nodeName)
        } catch {
            try? await qmp.blockdevDel(nodeName: nodeName)
            throw error
        }
    }

    func detachDisk(deviceName: String) async throws {
        guard isConnected else { throw QMPError.notConnected }
        let nodeName = "drive-\(deviceName)"
        try await qmp.deviceDel(deviceId: deviceName)
        try await qmp.blockdevDel(nodeName: nodeName)
    }

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
