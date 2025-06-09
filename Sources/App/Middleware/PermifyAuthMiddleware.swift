import Vapor
import Fluent

struct PermifyAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Skip auth for health checks, public routes, and auth endpoints
        if request.url.path.hasPrefix("/health") || 
           request.url.path == "/" ||
           request.url.path == "/hello" ||
           request.url.path == "/login" ||
           request.url.path == "/register" ||
           request.url.path.hasPrefix("/auth") ||
           request.url.path.hasPrefix("/users/register") ||
           request.url.path.hasPrefix("/js/") ||
           request.url.path.hasPrefix("/styles/") ||
           request.url.path == "/favicon.ico" {
            return try await next.respond(to: request)
        }
        
        // Extract user from session
        guard let user = request.auth.get(User.self) else {
            throw Abort(.unauthorized, reason: "User not authenticated")
        }
        
        // For VM routes, check permissions
        if request.url.path.hasPrefix("/vms") {
            try await checkVMPermissions(request: request, user: user)
        }
        
        return try await next.respond(to: request)
    }
    
    private func checkVMPermissions(request: Request, user: User) async throws {
        let method = request.method
        let pathComponents = request.url.path.split(separator: "/")
        
        // Determine required permission based on HTTP method and path
        let permission: String
        switch method {
        case .GET:
            permission = "read"
        case .POST:
            // Special handling for VM actions
            if pathComponents.count >= 4 {
                let action = String(pathComponents[3])
                switch action {
                case "start", "stop", "restart":
                    permission = action
                default:
                    permission = "update"
                }
            } else {
                permission = "create"
            }
        case .PUT, .PATCH:
            permission = "update"
        case .DELETE:
            permission = "delete"
        default:
            throw Abort(.methodNotAllowed)
        }
        
        // For specific VM operations, extract VM ID
        var resourceId = "*" // Default for collection operations
        if pathComponents.count >= 3 {
            resourceId = String(pathComponents[2])
        }
        
        // Check permission with Permify
        let hasPermission = try await request.permify.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: permission,
            resource: "vm",
            resourceId: resourceId
        )
        
        if !hasPermission {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }
}

