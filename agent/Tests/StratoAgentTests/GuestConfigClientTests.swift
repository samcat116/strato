import Foundation
import Logging
import Testing
import StratoShared
@testable import StratoAgentCore

@Suite("Guest configuration realization")
struct GuestConfigClientTests {
    private actor Connection: GuestLineConnection {
        var lines: [String]
        var writes: [Data] = []
        var closed = false
        init(_ response: String) {
            lines = [#"{"type":"pong","sandbox_id":"machine","nonce":"boot","control_protocol_version":4}"#, response]
        }
        func write(_ data: Data) { writes.append(data) }
        func nextLine(timeout: TimeInterval?) -> String? { lines.isEmpty ? nil : lines.removeFirst() }
        func close() { closed = true }
    }
    private let placement = VMGuestExecPlacement(vmId: "vm", vsockCID: 42)
    private func response(
        nonce: String = "boot", generation: Int = 7, status: String = "converged", error: String = "null"
    ) -> String {
        """
        {"type":"guest_config_state","nonce":"\(nonce)","observation":{"generation":\(generation),"status":"\(status)","error":\(error),"packages":[],"files":[],"services":[],"sysctls":[]}}
        """
    }
    private func client(_ connection: Connection) -> GuestConfigClient {
        GuestConfigClient(logger: Logger(label: "test.guest-config")) { cid, port, timeout, _ in
            #expect(cid == 42 && port == 1024 && timeout == 60)
            return connection
        }
    }
    @Test func boundedExchangeReturnsFactsAndClosesConnection() async throws {
        let connection = Connection(response())
        let observed = try await client(connection).converge(
            placement: placement, config: GuestConfig(), generation: 7, placementIsCurrent: { true })
        #expect(observed.status == .converged)
        #expect(await connection.closed)
        let writes = await connection.writes
        #expect(writes.count == 2)
        let request = try #require(JSONSerialization.jsonObject(with: writes[1]) as? [String: Any])
        #expect(request["type"] as? String == "converge_guest_config")
        #expect(request["generation"] as? Int == 7)
        #expect(request["guest_config"] is [String: Any])
    }

    @Test func maximumEscapedContentFitsConvergenceFrame() async throws {
        let files = (0..<4).map { index in
            GuestFile(
                path: "/escaped-\(index)",
                content: String(repeating: "\u{1}", count: GuestConfig.maxFileBytes),
                mode: "0600")
        }
        let config = GuestConfig(files: files)
        try config.validate()
        let connection = Connection(response(status: "failed", error: #""observation failed""#))
        _ = try await client(connection).converge(
            placement: placement, config: config, generation: 7, placementIsCurrent: { true })
        let writes = await connection.writes
        let request = try #require(writes.last)
        #expect(request.count > GuestControlProtocol.Limits.maxLineBytes)
        #expect(request.count <= GuestConfigClient.maxFrameBytes)
    }

    @Test func convergenceFrameLimitDoesNotChangeGenericGuestFrames() throws {
        let generic = HostVsockLineFrameDecoder()
        try generic.validate(length: GuestControlProtocol.Limits.maxLineBytes)
        #expect(throws: HostVsockConnectionError.self) {
            try generic.validate(length: GuestControlProtocol.Limits.maxLineBytes + 1)
        }
        let convergence = HostVsockLineFrameDecoder(maximumLineLength: GuestConfigClient.maxFrameBytes)
        try convergence.validate(length: GuestConfigClient.maxFrameBytes)
        #expect(throws: HostVsockConnectionError.self) {
            try convergence.validate(length: GuestConfigClient.maxFrameBytes + 1)
        }
    }
    @Test func rejectsStaleIdentityAndGenerationAndCloses() async {
        for invalid in [response(nonce: "old-boot"), response(generation: 6), "malformed"] {
            let connection = Connection(invalid)
            await #expect(throws: (any Error).self) {
                try await client(connection).converge(
                    placement: placement, config: GuestConfig(), generation: 7, placementIsCurrent: { true })
            }
            #expect(await connection.closed)
        }
    }
    @Test func failureIsAnObservationAndPlacementGuardPreventsWrites() async throws {
        let connection = Connection(response(status: "failed", error: #""package operation budget exhausted""#))
        let observed = try await client(connection).converge(
            placement: placement, config: GuestConfig(), generation: 7, placementIsCurrent: { true })
        #expect(observed.status == .failed)
        #expect(observed.error == "package operation budget exhausted")
        let refused = Connection(response())
        await #expect(throws: VMExecBridgeError.self) {
            try await client(refused).converge(
                placement: placement, config: GuestConfig(), generation: 7, placementIsCurrent: { false })
        }
        #expect(await refused.writes.isEmpty)
    }
    @Test func busyGuestDoesNotBurnFailureAttemptsAndEmptyIntentWithdrawsManagement() async {
        let connection = Connection(
            #"{"type":"error","nonce":"boot","message":"guest configuration convergence busy or unavailable"}"#)
        let error = await #expect(throws: GuestConfigurationFailure.self) {
            try await client(connection).converge(
                placement: placement, config: GuestConfig(), generation: 7, placementIsCurrent: { true })
        }
        #expect(error?.failureClassification == .waitingOnDependency)
        #expect(await connection.closed)
        let id = UUID()
        let spec = VMSpec(cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil))
        for config in [nil, GuestConfig()] as [GuestConfig?] {
            let entry = DesiredVMState(
                vmId: id, hypervisorType: .qemu, spec: spec, desiredStatus: .running, generation: 8, guestConfig: config
            )
            let plan = Reconciler.plan(
                desired: [entry], present: [id.uuidString: .managed(.running)], lastApplied: [id.uuidString: 7])
            #expect(!plan.items.contains { $0.steps.contains(.convergeGuestConfig) })
        }
    }
    @Test func plannerReobservesSameGenerationAndNeverOlderOrStoppedIntent() {
        let id = UUID()
        let spec = VMSpec(cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil), guestAgentEnabled: true)
        func desired(_ generation: Int64, _ status: DesiredVMStatus = .running) -> DesiredVMState {
            DesiredVMState(
                vmId: id, hypervisorType: .qemu, spec: spec, desiredStatus: status, generation: generation,
                guestConfig: GuestConfig(packages: [GuestPackage(name: "curl", state: .present)]))
        }
        let plan = Reconciler.plan(
            desired: [desired(7)], present: [id.uuidString: .managed(.running)], lastApplied: [id.uuidString: 7],
            appliedEdges: [id.uuidString: AppliedEdgeNonces()])
        #expect(plan.items.first?.steps == [.convergeGuestConfig])
        #expect(
            Reconciler.plan(
                desired: [desired(6)], present: [id.uuidString: .managed(.running)], lastApplied: [id.uuidString: 7]
            ).items.isEmpty)
        #expect(
            !Reconciler.plan(
                desired: [desired(8, .shutdown)], present: [id.uuidString: .managed(.running)],
                lastApplied: [id.uuidString: 7]
            ).items.contains { $0.steps.contains(.convergeGuestConfig) })
    }
}
