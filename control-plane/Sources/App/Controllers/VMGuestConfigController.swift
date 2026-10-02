import StratoShared
import Vapor

struct VMGuestConfigurationResponse: Content {
    let vmId: String
    let desiredGeneration: Int64
    let guestConfig: GuestConfig?
}

/// Explicit null withdraws management. A missing key or extra envelope keys
/// are invalid; silently accepting an omission would turn a typo into a clear.
struct ReplaceVMGuestConfigurationRequest: Decodable {
    let guestConfig: GuestConfig?
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1, let key = Key(stringValue: "guestConfig"), c.contains(key) else {
            throw Abort(.badRequest, reason: "Exactly one guestConfig key is required; use null to withdraw management")
        }
        guestConfig = try c.decodeIfPresent(GuestConfig.self, forKey: key)
    }
}

extension VMController {
    func guestConfiguration(req: Request) async throws -> VMGuestConfigurationResponse {
        let id = try req.requireUUIDParameter("vmID", reason: "Invalid VM ID")
        let vm = try await req.authorizedVM(id, action: "vm:configureGuest")
        return VMGuestConfigurationResponse(
            vmId: id.uuidString, desiredGeneration: vm.generation, guestConfig: vm.guestConfig)
    }

    func replaceGuestConfiguration(req: Request) async throws -> Response {
        let principal = try req.requireActingPrincipal()
        let id = try req.requireUUIDParameter("vmID", reason: "Invalid VM ID")
        let vm = try await req.authorizedVM(id, action: "vm:configureGuest")
        try await req.authorize("vm:read", on: IAMNode(type: .virtualMachine, id: id))
        let request: ReplaceVMGuestConfigurationRequest
        do {
            request = try req.content.decode(ReplaceVMGuestConfigurationRequest.self)
        } catch let error as GuestConfigValidationError {
            throw Abort(.unprocessableEntity, reason: error.description)
        } catch {
            // Decode diagnostics can include arbitrary caller data. Keep the
            // response rule-based, never echo raw JSON or file content.
            throw Abort(
                .badRequest,
                reason: "Invalid guestConfig document; packages, files, services and sysctls arrays are required")
        }
        let accepted = try await VMGuestConfigMutation(dispatch: req.application.agentService, logger: req.logger)
            .replace(
                request.guestConfig, on: vm, actor: MutationActor(principal: principal),
                context: req.idempotencyContext, db: req.db, app: req.application)
        if let accepted { return try await Self.acceptedResponse(for: vm, accepted, on: req) }
        return try await Self.detailResponse(for: vm, on: req)
    }
}
