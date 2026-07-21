import Vapor
import Fluent
import StratoShared

struct LogsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let logs = routes.grouped("api", "vms", ":vmID", "logs")

        logs.get(use: getVMLogs)

        // Sandbox workload stdout/stderr, shipped by agents as `sandbox_log`
        // messages and stored in Loki (issue #423).
        let sandboxLogs = routes.grouped("api", "sandboxes", ":sandboxID", "logs")

        sandboxLogs.get(use: getSandboxLogs)
    }

    /// GET /api/vms/:vmID/logs
    /// Query logs for a specific VM from Loki
    @Sendable
    func getVMLogs(req: Request) async throws -> [LogEntry] {
        _ = try req.auth.require(User.self)

        guard let vmIdString = req.parameters.get("vmID"),
            let vmId = UUID(uuidString: vmIdString)
        else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        // Verify the VM exists and enforce the per-VM read permission through
        // the evaluator (defense in depth alongside AuthorizationMiddleware).
        _ = try await req.authorizedVM(vmId, permission: "read")

        // Check if Loki is enabled
        guard req.application.lokiEnabled else {
            req.logger.warning("Loki not configured, returning empty logs")
            return []
        }

        // Parse query parameters
        let limit = min(req.query[Int.self, at: "limit"] ?? 100, 1000)  // Cap at 1000
        let directionStr = req.query[String.self, at: "direction"] ?? "backward"
        let direction = QueryDirection(rawValue: directionStr) ?? .backward

        // Time range parameters (Unix timestamps)
        let startTimestamp = req.query[Double.self, at: "start"]
        let endTimestamp = req.query[Double.self, at: "end"]

        let start = startTimestamp.map { Date(timeIntervalSince1970: $0) }
        let end = endTimestamp.map { Date(timeIntervalSince1970: $0) }

        do {
            return try await req.lokiService.queryVMLogs(
                vmId: vmIdString,
                start: start,
                end: end,
                limit: limit,
                direction: direction
            )
        } catch {
            req.logger.error("Failed to query Loki: \(error)")
            throw Abort(.serviceUnavailable, reason: "Failed to query logs: \(error.localizedDescription)")
        }
    }

    /// GET /api/sandboxes/:sandboxID/logs
    /// Query a sandbox's workload stdout/stderr from Loki (issue #423),
    /// mirroring the VM logs endpoint.
    @Sendable
    func getSandboxLogs(req: Request) async throws -> [LogEntry] {
        _ = try req.auth.require(User.self)

        guard let sandboxIdString = req.parameters.get("sandboxID"),
            let sandboxId = UUID(uuidString: sandboxIdString)
        else {
            throw Abort(.badRequest, reason: "Invalid sandbox ID")
        }

        // Verify the sandbox exists and enforce the per-sandbox read
        // permission through the evaluator (defense in depth alongside
        // AuthorizationMiddleware).
        _ = try await req.authorizedSandbox(sandboxId, permission: "read")

        // Check if Loki is enabled
        guard req.application.lokiEnabled else {
            req.logger.warning("Loki not configured, returning empty logs")
            return []
        }

        // Parse query parameters
        let limit = min(req.query[Int.self, at: "limit"] ?? 100, 1000)  // Cap at 1000
        let directionStr = req.query[String.self, at: "direction"] ?? "backward"
        let direction = QueryDirection(rawValue: directionStr) ?? .backward

        // Time range parameters (Unix timestamps)
        let startTimestamp = req.query[Double.self, at: "start"]
        let endTimestamp = req.query[Double.self, at: "end"]

        let start = startTimestamp.map { Date(timeIntervalSince1970: $0) }
        let end = endTimestamp.map { Date(timeIntervalSince1970: $0) }

        do {
            return try await req.lokiService.querySandboxLogs(
                sandboxId: sandboxIdString,
                start: start,
                end: end,
                limit: limit,
                direction: direction
            )
        } catch {
            req.logger.error("Failed to query Loki: \(error)")
            throw Abort(.serviceUnavailable, reason: "Failed to query logs: \(error.localizedDescription)")
        }
    }
}
