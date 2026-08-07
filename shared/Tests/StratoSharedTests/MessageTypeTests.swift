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
        case .vmReboot: return "vm_reboot"
        case .vmCheckpoint: return "vm_checkpoint"
        case .vmRestore: return "vm_restore"
        case .vmSnapshotDelete: return "vm_snapshot_delete"
        case .volumeSnapshot: return "volume_snapshot"
        case .volumeSnapshotDelete: return "volume_snapshot_delete"
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
        .agentRegister, .agentRegisterResponse, .agentHeartbeat, .agentUnregister,
        .vmReboot, .vmCheckpoint, .vmRestore, .vmSnapshotDelete,
        .volumeSnapshot, .volumeSnapshotDelete,
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

    /// Every wire string that was a `MessageType` case once and must never be
    /// one again.
    ///
    /// Retiring a string is *safe* precisely because of the test above — a
    /// stale peer's frame fails to route instead of decoding into something
    /// else — but only for as long as it stays retired. Agents deploy on their
    /// own schedule, so a fleet always contains peers old enough to still send
    /// some of these; reusing one of their strings for an unrelated payload
    /// would silently misroute rather than error. That is the failure this
    /// pins against, and it is why the list keeps strings whose removal
    /// predates wire versioning entirely.
    ///
    /// Grouped by the change that retired them, oldest first. Extend it in the
    /// same commit that deletes a case.
    private static let retiredWireStrings = [
        // Dead code that never had a live sender (#244).
        "image_info", "image_info_response", "vm_counters", "volume_status",
        // Imperative VM lifecycle and polling reads, superseded by
        // desired-state sync (#512).
        "vm_create", "vm_delete", "vm_boot", "vm_shutdown", "vm_pause", "vm_resume",
        "vm_info", "vm_status", "status_update",
        // Network topology is level-triggered from `DesiredStateMessage.networks`
        // alone; the frames named OVN objects after network names two projects
        // may now share (#781).
        "network_create", "network_delete", "network_attach", "network_detach",
        "network_info", "network_list",
        // An agent's build is desired state, not an action (wire v28, ADR 0001
        // stage 6, STR-145).
        "agent_update",
        // Volumes became desired state (wire v31, ADR 0001 stage 5, STR-148).
        "volume_create", "volume_delete", "volume_attach", "volume_detach",
        "volume_resize", "volume_clone",
        // A read can never be desired state (wire v32, ADR 0001 stage 7,
        // STR-149).
        "volume_info",
    ]

    @Test("retired wire strings stay retired", arguments: retiredWireStrings)
    func retiredStringNeverDecodes(wireString: String) throws {
        #expect(throws: DecodingError.self) {
            try decodeJSON([MessageType].self, from: #"["\#(wireString)"]"#)
        }
    }

    /// The two lists above must stay disjoint. Without this, reviving a retired
    /// string as a live case would only fail the retired-string test — which
    /// reads like a stale expectation to delete, exactly the wrong fix.
    @Test("no live case reuses a retired wire string")
    func retiredAndLiveStringsAreDisjoint() {
        let live = Set(Self.allTypes.map(\.rawValue))
        let collisions = Self.retiredWireStrings.filter(live.contains)
        #expect(collisions.isEmpty, "retired wire strings revived as live cases: \(collisions)")
    }
}
