import Vapor
import Fluent

struct SpiceDBAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Skip auth for health checks, public routes, and auth endpoints
        if request.url.path.hasPrefix("/health") || 
           request.url.path == "/" ||
           request.url.path == "/hello" ||
           request.url.path == "/login" ||
           request.url.path == "/register" ||
           request.url.path.hasPrefix("/auth") ||
           request.url.path.hasPrefix("/users/register") ||
           request.url.path.hasPrefix("/onboarding") ||
           request.url.path.hasPrefix("/js/") ||
           request.url.path.hasPrefix("/styles/") ||
           request.url.path == "/favicon.ico" {
            return try await next.respond(to: request)
        }
        
        // Extract user from session
        guard let user = request.auth.get(User.self) else {
            throw Abort(.unauthorized, reason: "User not authenticated")
        }
        
        // System admins bypass all permission checks
        if user.isSystemAdmin {
            request.logger.info("System admin access - bypassing permission checks")
            return try await next.respond(to: request)
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
                case "start", "stop", "restart", "pause", "resume":
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
        
        // Handle collection-level operations that require organization permissions
        if (permission == "read" && resourceId == "*") || (permission == "create" && resourceId == "*") {
            // For VM collection read and VM creation, check organization membership
            guard let currentOrgId = user.currentOrganizationId else {
                throw Abort(.forbidden, reason: "No current organization set")
            }
            
            guard let userId = user.id?.uuidString, !userId.isEmpty else {
                throw Abort(.forbidden, reason: "Invalid user session")
            }
            
            request.logger.info("Checking permission for user: \(userId) on organization: \(currentOrgId.uuidString)")
            
            let hasPermission = try await request.spicedb.checkPermission(
                subject: userId,
                permission: "view_organization",
                resource: "organization",
                resourceId: currentOrgId.uuidString
            )
            
            if !hasPermission {
                throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
            }
        } else {
            // Check permission with SpiceDB for specific VM operations
            guard let userId = user.id?.uuidString, !userId.isEmpty else {
                throw Abort(.forbidden, reason: "Invalid user session")
            }
            
            let hasPermission = try await request.spicedb.checkPermission(
                subject: userId,
                permission: permission,
                resource: "vm",
                resourceId: resourceId
            )
            
            if !hasPermission {
                throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
            }
        }
    }
}