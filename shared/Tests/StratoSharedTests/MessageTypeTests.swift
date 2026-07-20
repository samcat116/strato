import Foundation
import Testing
import StratoShared

@Suite("MessageType wire strings")
struct MessageTypeTests {
    /// The wire string each case must serialize to. The switch is exhaustive on
    /// purpose: adding a MessageType case without extending this test is a
    /// compile error, so every new case gets its wire string pinned here.
    private func expectedWireString(for type: MessageType) -> String {
        switch type {
        case .agentRegister: return "agent_register"
        case .agentRegisterResponse: return "agent_register_response"
        case .agentHeartbeat: return "agent_heartbeat"
        case .agentUnregister: return "agent_unregister"
        case .agentUpdate: return "agent_update"
        case .vmReboot: return "vm_reboot"
        case .networkCreate: return "network_create"
        case .networkDelete: return "network_delete"
        case .networkList: return "network_list"
        case .networkInfo: return "network_info"
        case .networkAttach: return "network_attach"
        case .networkDetach: return "network_detach"
        case .volumeCreate: return "volume_create"
        case .volumeDelete: return "volume_delete"
        case .volumeAttach: return "volume_attach"
        case .volumeDetach: return "volume_detach"
        case .volumeResize: return "volume_resize"
        case .volumeSnapshot: return "volume_snapshot"
        case .volumeSnapshotDelete: return "volume_snapshot_delete"
        case .volumeClone: return "volume_clone"
        case .volumeInfo: return "volume_info"
        case .consoleConnect: return "console_connect"
        case .consoleDisconnect: return "console_disconnect"
        case .consoleData: return "console_data"
        case .consoleConnected: return "console_connected"
        case .consoleDisconnected: return "console_disconnected"
        case .desiredState: return "desired_state"
        case .observedState: return "observed_state"
        case .success: return "success"
        case .error: return "error"
        case .vmLog: return "vm_log"
        case .sandboxExecStart: return "sandbox_exec_start"
        case .sandboxExecStarted: return "sandbox_exec_started"
        case .sandboxExecInput: return "sandbox_exec_input"
        case .sandboxExecOutput: return "sandbox_exec_output"
        case .sandboxExecResize: return "sandbox_exec_resize"
        case .sandboxExecExit: return "sandbox_exec_exit"
        case .sandboxExecClose: return "sandbox_exec_close"
        case .sandboxExecClosed: return "sandbox_exec_closed"
        case .sandboxLog: return "sandbox_log"
        case .sandboxSnapshotCreate: return "sandbox_snapshot_create"
        case .sandboxSnapshotDelete: return "sandbox_snapshot_delete"
        case .sandboxRestore: return "sandbox_restore"
        case .sandboxSnapshotExport: return "sandbox_snapshot_export"
        }
    }

    private static let allTypes: [MessageType] = [
        .agentRegister, .agentRegisterResponse, .agentHeartbeat, .agentUnregister, .agentUpdate,
        .vmReboot,
        .networkCreate, .networkDelete, .networkList, .networkInfo, .networkAttach, .networkDetach,
        .volumeCreate, .volumeDelete, .volumeAttach, .volumeDetach, .volumeResize,
        .volumeSnapshot, .volumeSnapshotDelete, .volumeClone, .volumeInfo,
        .consoleConnect, .consoleDisconnect, .consoleData, .consoleConnected, .consoleDisconnected,
        .desiredState, .observedState,
        .success, .error, .vmLog,
        .sandboxExecStart, .sandboxExecStarted, .sandboxExecInput, .sandboxExecOutput,
        .sandboxExecResize, .sandboxExecExit, .sandboxExecClose, .sandboxExecClosed,
        .sandboxLog,
        .sandboxSnapshotCreate, .sandboxSnapshotDelete, .sandboxRestore, .sandboxSnapshotExport,
    ]

    @Test("every case keeps its wire string", arguments: allTypes)
    func wireStringIsStable(type: MessageType) {
        #expect(type.rawValue == expectedWireString(for: type))
    }

    @Test("every case round-trips through JSON", arguments: allTypes)
    func roundTrips(type: MessageType) throws {
        #expect(try roundTrip([type]) == [type])
    }

    @Test("unknown wire string fails to decode")
    func unknownTypeThrows() {
        // MessageType has no tolerant fallback: a peer speaking a newer
        // protocol version produces a decode error, not a silent misroute.
        #expect(throws: DecodingError.self) {
            try decodeJSON([MessageType].self, from: #"["vm_teleport"]"#)
        }
    }
}
