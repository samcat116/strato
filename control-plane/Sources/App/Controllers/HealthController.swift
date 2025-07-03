import Fluent
import Vapor

struct HealthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let health = routes.grouped("health")
        
        // Basic health check - just returns 200 OK
        health.get(use: self.health)
        
        // Readiness check - checks database and SpiceDB connectivity
        health.get("ready", use: readiness)
        
        // Liveness check - basic application health
        health.get("live", use: liveness)
    }
    
    func health(req: Request) async throws -> HTTPStatus {
        return .ok
    }
    
    func liveness(req: Request) async throws -> HealthResponse {
        // Basic liveness check - if we can respond, we're alive
        return HealthResponse(
            status: "healthy",
            timestamp: Date(),
            checks: [
                HealthCheck(name: "application", status: "up")
            ]
        )
    }
    
    func readiness(req: Request) async throws -> HealthResponse {
        var checks: [HealthCheck] = []
        var overallStatus = "healthy"
        
        // Check database connectivity
        do {
            // Simple database connectivity check using an existing model
            _ = try await VM.query(on: req.db).count()
            checks.append(HealthCheck(name: "database", status: "up"))
        } catch {
            checks.append(HealthCheck(name: "database", status: "down", error: error.localizedDescription))
            overallStatus = "unhealthy"
        }
        
        // TODO: Add SpiceDB connectivity check when service is properly configured
        
        return HealthResponse(
            status: overallStatus,
            timestamp: Date(),
            checks: checks
        )
    }
}

struct HealthResponse: Content {
    let status: String
    let timestamp: Date
    let checks: [HealthCheck]
}

struct HealthCheck: Content {
    let name: String
    let status: String
    let error: String?
    
    init(name: String, status: String, error: String? = nil) {
        self.name = name
        self.status = status
        self.error = error
    }
}