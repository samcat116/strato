import Fluent
import Foundation
import StratoShared
import Vapor

struct AgentSandboxIdleFenceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("agent", "sandboxes", ":sandboxID", "idle-admission", use: validate)
    }
    func validate(req: Request) async throws -> HTTPStatus {
        guard AgentMTLSAuthenticator.hasClientCertificate(req) else { throw Abort(.unauthorized) }
        let identity = try await AgentMTLSAuthenticator.authenticateAgent(req: req)
        guard
            let agent = try await Agent.query(on: req.db)
                .filter(\.$trustDomain == identity.identity.trustDomain)
                .filter(\.$name == identity.identity.name).first(),
            let owner = agent.id?.uuidString,
            let id = req.parameters.get("sandboxID").flatMap(UUID.init(uuidString:)),
            let bytes = req.body.data, bytes.readableBytes <= 4096
        else { throw Abort(.forbidden) }
        let fence = try WireProtocol.makeDecoder().decode(
            SandboxAutomaticSuspensionFence.self, from: Data(bytes.readableBytesView))
        try await SandboxIdleFenceService.validate(id: id, owner: owner, fence: fence, on: req.db)
        return .noContent
    }
}
