import Fluent
import Foundation
import StratoShared
import Vapor

/// Authenticated, update-only bootstrap. Never assembles workload state or
/// creates an assignment: the operator must stage it before wire cutover.
struct AgentUpdateBridgeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("agent", "update", "v1", use: fetch)
    }

    func fetch(req: Request) async throws -> Response {
        guard AgentMTLSAuthenticator.hasClientCertificate(req) else {
            throw Abort(.unauthorized, reason: "Agent updates require an agent client certificate")
        }
        let authenticated = try await AgentMTLSAuthenticator.authenticateAgent(req: req)
        let agent = try await Agent.query(on: req.db)
            .filter(\.$trustDomain == authenticated.identity.trustDomain)
            .filter(\.$name == authenticated.identity.name)
            .first()
        let update = await req.application.desiredStateAssembler.desiredAgentUpdateForSync(agent: agent)
        if let advertised = req.headers.first(name: AgentUpdateBridgeResponse.wireVersionHeader),
            advertised != String(WireProtocol.currentVersion)
        {
            req.logger.notice(
                "Agent wire skew: serving update-only exchange; stage an assignment before cutover",
                metadata: [
                    "strato.agent.identity": .string(authenticated.identity.key),
                    "agentWireVersion": .string(advertised),
                    "controlPlaneWireVersion": .stringConvertible(WireProtocol.currentVersion),
                    "assignedUpdate": .stringConvertible(update != nil),
                ])
        }
        let data = try JSONEncoder().encode(
            AgentUpdateBridgeResponse(workloadWireVersion: WireProtocol.currentVersion, update: update))
        let response = Response(status: .ok, body: .init(data: data))
        response.headers.contentType = .json
        response.headers.cacheControl = HTTPHeaders.CacheControl(noStore: true)
        return response
    }
}
