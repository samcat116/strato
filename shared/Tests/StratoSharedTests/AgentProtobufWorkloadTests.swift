import Foundation
import SwiftProtobuf
import Testing
import StratoShared

@Suite("AgentProtobuf workload boundaries and legacy JSON")
struct AgentProtobufWorkloadTests {
    @Test("default protobuf values cannot replace missing idle evidence")
    func missingIdleEvidenceIsNotQuiet() throws {
        let guest = SandboxGuestIdleActivity(
            sandboxId: UUID().uuidString, nonce: "fixture", probeId: UUID(), monitorIncarnation: UUID(),
            sampleSequence: 1, activityEpoch: 1, quietForMilliseconds: 400_000,
            coverage: .complete, trusted: true, activeExecSessionIds: [], anonymousExecCount: 0,
            pendingExecCount: 0, workloadCpuMicroseconds: 0, workloadReadBytes: 0, workloadWriteBytes: 0,
            externalSocketCount: 0, nicCount: 0)
        let quiet = SandboxIdleActivityReport(
            agentIncarnation: UUID(), connectionEpoch: UUID(), residencyEpoch: UUID(), sequence: 1,
            generation: 1, activityEpoch: 1, evidenceAgeMilliseconds: 0, residentForMilliseconds: 400_000,
            guest: guest, activeExecSessionIds: [], pendingCommandCount: 0,
            snapshotOrRestoreInProgress: false, idleFenceSupported: true, hostQuietMilliseconds: 400_000,
            hostPendingCommandCount: 0, controlPlaneActivityRevision: 1)
        try quiet.validateProtocol()
        #expect(quiet.isCompleteQuiet)
        var absentSessions = quiet
        absentSessions.clearActiveExecSessionIds()
        var absentCommands = quiet
        absentCommands.clearHostPendingCommandCount()
        var absentLifecycle = quiet
        absentLifecycle.clearSnapshotOrRestoreInProgress()
        var absentGuest = quiet
        absentGuest.clearGuest()
        for value in [absentSessions, absentCommands, absentLifecycle, absentGuest] {
            try value.validateProtocol()  // Optional absence is valid, but cannot authorize reclamation.
            #expect(!value.isCompleteQuiet)
        }
    }

    @Test("authoritative empty lists are explicit and omitted required lists reject the entire message")
    func mandatoryListPresence() throws {
        let empty = DesiredStateMessage(requestId: "request", timestamp: Fixtures.timestamp, syncId: "sync", vms: [])
        let decoded = try WireProtocol.decodeEnvelope(WireProtocol.encodeEnvelope(empty))
            .decode(as: DesiredStateMessage.self)
        #expect(decoded.hasVms && decoded.vms.values.isEmpty)
        #expect(decoded.hasNetworks && decoded.networks.values.isEmpty)
        #expect(!decoded.hasSecurityGroups)
        var missing = empty
        missing.clearVms()
        let unsafeBytes = try MessageEnvelope(message: missing).serializedData()
        #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.decodeEnvelope(unsafeBytes) }
        #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.encodeEnvelope(missing) }
    }

    @Test("optional absence and present empty collections survive binary and legacy JSON distinctly")
    func optionalListPresence() throws {
        let omitted = DesiredStateMessage(requestId: "request", timestamp: Fixtures.timestamp, syncId: "sync", vms: [])
        var empty = omitted
        empty.securityGroups = .init()
        for value in [omitted, empty] {
            let binary = try WireProtocol.decodeEnvelope(WireProtocol.encodeEnvelope(value))
                .decode(as: DesiredStateMessage.self)
            let json = try WireProtocol.makeEncoder().encode(value)
            let dictionary = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
            let restored = try WireProtocol.makeDecoder().decode(DesiredStateMessage.self, from: json)
            #expect(binary.hasSecurityGroups == value.hasSecurityGroups)
            #expect(restored.hasSecurityGroups == value.hasSecurityGroups)
            #expect((dictionary["securityGroups"] != nil) == value.hasSecurityGroups)
            #expect(dictionary["vms"] as? [String] == [])
        }
    }

    @Test("invalid UUIDs timestamps enums and oneofs fail before a workload becomes actionable")
    func rejectsMalformedValues() throws {
        let validVM = DesiredVMState(
            vmId: Fixtures.uuidA, hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil)),
            desiredStatus: .running, generation: 1)
        var badUUID = validVM
        badUUID.vmID = "invalid"
        var unknownEnum = validVM
        unknownEnum.desiredStatus = .UNRECOGNIZED(932)
        var missingOneof = validVM
        missingOneof.spec.boot = .init()
        for vm in [badUUID, unknownEnum, missingOneof] {
            let message = DesiredStateMessage(vms: [vm])
            let bytes = try MessageEnvelope(message: message).serializedData()
            #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.decodeEnvelope(bytes) }
            #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.makeEncoder().encode(vm) }
        }
        var timestamp = DesiredStateMessage(vms: [])
        timestamp.timestamp.nanos = -1
        #expect(throws: AgentProtocolDecodeError.self) { try WireProtocol.encodeEnvelope(timestamp) }
        #expect(throws: AgentProtocolDecodeError.self) { try UUID(protocolString: "invalid") }
    }

    @Test("UUID spellings canonicalize throughout nested messages without losing future fields")
    func canonicalizesProtocolIdentifiers() throws {
        let id = UUID(uuidString: "ABCD1234-ABCD-4BCD-8BCD-ABCD1234ABCD")!
        var vm = DesiredVMState(
            vmId: id, hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 512 * 1024 * 1024, boot: .disk(firmware: nil)),
            desiredStatus: .running, generation: 1)
        vm.vmID = id.uuidString.lowercased()
        var network = NetworkSpec(network: "fixture", networkId: id, macAddress: "02:00:00:00:00:01")
        network.networkID = "aBcD1234-abCD-4bCd-8BcD-AbCd1234aBcD"
        network.securityGroupIds = .with { $0.values = [id.uuidString.lowercased()] }
        vm.spec.networks.values = [network]
        let message = DesiredStateMessage(vms: [vm])
        let futureField = Data([0xc0, 0x0c, 0x01])
        var originalBytes = try MessageEnvelope(message: message).serializedData()
        originalBytes.append(futureField)
        let originalCopy = originalBytes
        let decoded = try WireProtocol.decodeEnvelope(originalBytes)
        let canonical = try decoded.decode(as: DesiredStateMessage.self).vms.values[0]
        #expect(canonical.vmID == id.uuidString)
        #expect(canonical.spec.networks.values[0].networkID == id.uuidString)
        #expect(canonical.spec.networks.values[0].securityGroupIds.values == [id.uuidString])
        #expect(originalBytes == originalCopy)  // Replica forwarding keeps its original encoded bytes.
        #expect(try WireProtocol.encodeEnvelope(decoded).suffix(futureField.count) == futureField)
        let encoded = try MessageEnvelope(serializedBytes: WireProtocol.encodeEnvelope(message))
        #expect(try encoded.decode(as: DesiredStateMessage.self).vms.values[0].vmID == id.uuidString)
        #expect(message.vms.values[0].vmID == id.uuidString.lowercased())  // Encoding normalizes a copy.
    }

    @Test("unknown fields remain intact for replica forwarding")
    func preservesUnknownFields() throws {
        var bytes = try WireProtocol.encodeEnvelope(SuccessMessage(requestId: "request", timestamp: Fixtures.timestamp))
        let futureField = Data([0xc0, 0x0c, 0x01])  // unknown field 200, varint 1
        bytes.append(futureField)
        let decoded = try WireProtocol.decodeEnvelope(bytes)
        #expect(try WireProtocol.encodeEnvelope(decoded).suffix(futureField.count) == futureField)
    }

    @Test("guest configuration and machine policy factories explicitly initialize required defaults")
    func explicitDefaults() throws {
        let empty = GuestConfig.empty
        try empty.validateProtocol()
        #expect(empty.hasPackages && empty.hasFiles && empty.hasServices && empty.hasSysctls)
        let machine = MachineProfile.default
        try machine.validateProtocol()
        #expect(machine.hasSecureBoot && !machine.secureBoot && machine.hasTpm && !machine.tpm)
        let policy = SandboxIdlePolicy.defaults
        try policy.validateProtocol()
        #expect(policy.hasEnabled && !policy.enabled)
        #expect(policy.idleSeconds == 300 && policy.minimumResidencySeconds == 60)
        #expect(policy.maximumEvidenceAgeSeconds == 30 && policy.restoreTimeoutSeconds == 120)
        #expect(policy.hasExcludedSandboxIDs)
    }

    @Test("stored volume and guest observation JSON retain names UUIDs enums and Foundation dates")
    func legacyJSONGolden() throws {
        let volume = VolumeSpec(
            volumeId: Fixtures.uuidA, deviceName: .disk(0),
            attachment: .file(path: "/data/disk.qcow2", format: .qcow2))
        let dictionary = try #require(
            JSONSerialization.jsonObject(with: WireProtocol.makeEncoder().encode(volume)) as? NSDictionary)
        let expected: NSDictionary = [
            "volumeId": Fixtures.uuidA.uuidString,
            "deviceName": "disk0", "readonly": false, "blockMode": "conservative",
            "attachment": ["file": ["path": "/data/disk.qcow2", "format": "qcow2"]],
        ]
        #expect(dictionary == expected)
        let observation = GuestAgentObservation(reachable: true, checkedAt: Fixtures.timestamp)
        let observationJSON = try #require(
            JSONSerialization.jsonObject(with: WireProtocol.makeEncoder().encode(observation)) as? NSDictionary)
        #expect(
            observationJSON == ["reachable": true, "checkedAt": Fixtures.timestamp.timeIntervalSinceReferenceDate]
                as NSDictionary)
        let configJSON = try #require(
            JSONSerialization.jsonObject(with: WireProtocol.makeEncoder().encode(GuestConfig.empty)) as? NSDictionary)
        #expect(configJSON == ["packages": [], "files": [], "services": [], "sysctls": []] as NSDictionary)
    }

    @Test("binary stream payloads carry raw bytes while legacy JSON remains base64")
    func streamBytes() throws {
        let bytes = Data([0, 1, 127, 128, 255])
        let message = ConsoleDataMessage(
            requestId: "request", timestamp: Fixtures.timestamp,
            vmId: "vm", sessionId: "session", rawData: bytes)
        let decoded = try WireProtocol.decodeEnvelope(WireProtocol.encodeEnvelope(message))
            .decode(as: ConsoleDataMessage.self)
        #expect(decoded.data == bytes && decoded.rawData == bytes)
        let dictionary = try #require(
            JSONSerialization.jsonObject(with: WireProtocol.makeEncoder().encode(message)) as? [String: Any])
        #expect(dictionary["data"] as? String == bytes.base64EncodedString())
    }
}
