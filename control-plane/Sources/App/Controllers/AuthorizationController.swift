import Fluent
import Vapor

/// Exposes the current user's effective permissions so the frontend can gate UI
/// (show/hide management controls) without hardcoding role assumptions. Read-only:
/// it answers "can I?" for the authenticated caller and never mutates anything.
struct AuthorizationController: RouteCollection {
    /// Cap on checks per request — keeps a single call bounded (see `checkBulk`).
    private static let maxChecks = 50

    func boot(routes: RoutesBuilder) throws {
        let authorization = routes.grouped("api", "authorization")
        authorization.post("check", use: check)
    }

    struct PermissionCheckItem: Content {
        /// Opaque client-chosen id echoed back in the response, so the caller can
        /// correlate answers to the UI element they gate.
        let key: String
        let resourceType: String
        let resourceId: String
        let permission: String
    }

    struct CheckRequest: Content {
        let checks: [PermissionCheckItem]
    }

    struct CheckResponse: Content {
        let results: [String: Bool]
    }

    /// POST /api/authorization/check
    ///
    /// Body: `{ "checks": [ { "key", "resourceType", "resourceId", "permission" } ] }`
    /// Returns: `{ "results": { "<key>": true/false, ... } }`
    func check(req: Request) async throws -> CheckResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let payload = try req.content.decode(CheckRequest.self)

        guard !payload.checks.isEmpty else {
            return CheckResponse(results: [:])
        }
        guard payload.checks.count <= Self.maxChecks else {
            throw Abort(.badRequest, reason: "Too many checks (max \(Self.maxChecks))")
        }

        // System admins can do everything — answer without hitting SpiceDB.
        if user.isSystemAdmin {
            var results: [String: Bool] = [:]
            for item in payload.checks {
                results[item.key] = true
            }
            return CheckResponse(results: results)
        }

        let queries = payload.checks.map {
            PermissionQuery(
                key: $0.key,
                permission: $0.permission,
                resourceType: $0.resourceType,
                resourceId: $0.resourceId
            )
        }

        let results = try await req.spicedb.checkBulk(subject: user.id?.uuidString ?? "", queries)
        return CheckResponse(results: results)
    }
}
