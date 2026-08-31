import Foundation
import Testing
import StratoShared

@Suite("MessageType wire strings")
struct MessageTypeTests {
    /// These strings are a compatibility contract with independently deployed
    /// peers, not an implementation inventory. Keep this switch exhaustive so
    /// every new live frame gets an explicit, reviewed wire spelling.
    private func expectedWireString(for type: MessageType) -> String {
        switch type {
        case .agentRegister: return "agent_register"
        case .agentRegisterResponse: return "agent_register_response"
        case .agentHeartbeat: return "agent_heartbeat"
        case .agentUnregister: return "agent_unregister"
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
        case .guestExecStart: return "guest_exec_start"
        case .guestExecStarted: return "guest_exec_started"
        case .guestExecInput: return "guest_exec_input"
        case .guestExecOutput: return "guest_exec_output"
        case .guestExecResize: return "guest_exec_resize"
        case .guestExecExit: return "guest_exec_exit"
        case .guestExecClose: return "guest_exec_close"
        case .guestExecClosed: return "guest_exec_closed"
        case .guestExecRecordedState: return "guest_exec_recorded_state"
        case .guestExecRecordedAck: return "guest_exec_recorded_ack"
        case .sandboxLog: return "sandbox_log"
        }
    }

    private static let liveTypes: [MessageType] = [
        .agentRegister, .agentRegisterResponse, .agentHeartbeat, .agentUnregister,
        .consoleConnect, .consoleDisconnect, .consoleData, .consoleConnected, .consoleDisconnected,
        .desiredState, .observedState,
        .success, .error, .vmLog,
        .guestExecStart, .guestExecStarted, .guestExecInput, .guestExecOutput,
        .guestExecResize, .guestExecExit, .guestExecClose, .guestExecClosed,
        .guestExecRecordedState, .guestExecRecordedAck,
        .sandboxLog,
    ]

    @Test("live wire strings stay compatible", arguments: liveTypes)
    func liveWireStringIsStable(type: MessageType) throws {
        let expected = expectedWireString(for: type)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: encodeJSON(type), options: .fragmentsAllowed) as? String
        )
        #expect(encoded == expected)
        #expect(try decodeJSON(MessageType.self, from: encodeJSON(expected)) == type)
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
    /// Retiring a string is *safe* because an unknown type fails to decode — a
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
        // An artifact's *existence* is a state even though capturing it is an
        // action (wire v33, ADR 0001 stage 8, STR-150).
        "volume_snapshot", "volume_snapshot_delete",
        "vm_checkpoint", "vm_snapshot_delete",
        "sandbox_snapshot_create", "sandbox_snapshot_delete", "sandbox_snapshot_export",
        // An edge becomes a state once how many times it was asked for is part
        // of the state (wire v34, ADR 0001 stage 9, STR-151). These three were
        // the last durable-resource RPCs on the wire.
        "vm_reboot", "vm_restore", "sandbox_restore",
        // The v43 sandbox-only exec stream was replaced by generalized guest
        // exec messages in v44 and its temporary aliases were removed in v47
        // (STR-244).
        "sandbox_exec_start", "sandbox_exec_started", "sandbox_exec_input", "sandbox_exec_output",
        "sandbox_exec_resize", "sandbox_exec_exit", "sandbox_exec_close", "sandbox_exec_closed",
    ]

    @Test("retired wire strings stay retired", arguments: retiredWireStrings)
    func retiredStringNeverDecodes(wireString: String) throws {
        #expect(throws: DecodingError.self) {
            try decodeJSON([MessageType].self, from: #"["\#(wireString)"]"#)
        }
    }

    @Test("retired wire strings are never reused")
    func retiredAndLiveStringsAreDisjoint() {
        let live = Set(Self.liveTypes.map(\.rawValue))
        let collisions = Self.retiredWireStrings.filter(live.contains)
        #expect(collisions.isEmpty, "retired wire strings revived as live cases: \(collisions)")
    }
}
