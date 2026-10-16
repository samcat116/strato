import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import StratoAPIClient

@Suite("Generated agent client contract")
struct AgentClientTests {
    private static let agentID = "00000000-0000-0000-0000-000000000001"

    // AgentResponse encodes HypervisorSupport directly: snapshot support is flat,
    // and an unavailable backend can omit its optional probe results entirely.
    private static let agentJSON = """
        {
          "id": "\(agentID)", "name": "node-1", "hostname": "hypervisor-1",
          "version": "main-test", "status": "online", "administrativelyOffline": false,
          "resources": {
            "totalCPU": 12, "availableCPU": 12,
            "totalMemory": 17179869184, "availableMemory": 16106127360,
            "totalDisk": 536870912000, "availableDisk": 515396075520,
            "physicalFreeDisk": 515396075520
          },
          "hypervisors": [
            {
              "type": "qemu", "available": true, "accelerated": true,
              "supportsSnapshots": true, "supportsVsock": true,
              "supportsGuestExec": true, "supportsVolumeIOLimits": true
            },
            {
              "type": "firecracker", "available": false, "accelerated": false,
              "supportsSnapshots": true, "unavailabilityReason": "Firecracker binary not found"
            }
          ],
          "networkCapability": "overlay", "sandboxCapable": false,
          "sandboxNetworkingCapable": false, "tpmCapable": true,
          "resolverCapable": true, "metadataServiceCapable": true,
          "dependencyObservations": [], "siteId": "00000000-0000-0000-0000-000000000002",
          "isOnline": true, "updateAvailable": false, "autoUpdate": false
        }
        """

    @Test("List and get decode the server's flat hypervisor reports", arguments: [false, true])
    func decodesAgents(list: Bool) async throws {
        let body =
            list
            ? "{\"items\":[\(Self.agentJSON)],\"total\":1,\"limit\":500,\"offset\":0}"
            : Self.agentJSON
        let transport = StratoAPIClientTests.RecordingTransport(
            response: HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
            responseBody: HTTPBody(body))
        let client = Client(serverURL: URL(string: "https://strato.example.com")!, transport: transport)
        let agent: Components.Schemas.AgentDetail
        if list {
            let page = try await client.listAgents().ok.body.json
            #expect(page.total == 1)
            #expect(page.items.count == 1)
            agent = try #require(page.items.first)
            #expect(transport.lastRequest?.path == "/api/agents")
        } else {
            agent = try await client.getAgent(path: .init(agentId: Self.agentID)).ok.body.json
            #expect(transport.lastRequest?.path == "/api/agents/\(Self.agentID)")
        }

        #expect(agent.id == Self.agentID)
        #expect(agent.hypervisors.count == 2)
        let qemu = agent.hypervisors[0]
        #expect(qemu._type == .qemu)
        #expect(qemu.available && qemu.accelerated && qemu.supportsSnapshots)
        #expect(qemu.supportsVsock == true)
        #expect(qemu.supportsGuestExec == true)
        #expect(qemu.supportsVolumeIOLimits == true)
        #expect(qemu.unavailabilityReason == nil)
        #expect(qemu.version == nil)
        let firecracker = agent.hypervisors[1]
        #expect(firecracker._type == .firecracker)
        #expect(!firecracker.available && !firecracker.accelerated)
        #expect(firecracker.supportsSnapshots)
        #expect(firecracker.unavailabilityReason == "Firecracker binary not found")
        #expect(firecracker.supportsVsock == nil)
        #expect(firecracker.supportsGuestExec == nil)
        #expect(firecracker.supportsVolumeIOLimits == nil)
        #expect(firecracker.version == nil)
    }

    @Test("Snapshot support is required and false is preserved")
    func snapshotSupportIsRequired() throws {
        let body = Data(
            """
            {"type":"qemu","available":true,"accelerated":true,"supportsSnapshots":false}
            """.utf8)
        let report = try JSONDecoder().decode(Components.Schemas.AgentHypervisorSupport.self, from: body)
        #expect(!report.supportsSnapshots)

        let missing = Data(#"{"type":"qemu","available":true,"accelerated":true}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Components.Schemas.AgentHypervisorSupport.self, from: missing)
        }
    }
}
