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
        try await queryLogs(
            req: req, parameter: "vmID", invalidReason: "Invalid VM ID",
            authorize: { _ = try await req.authorizedVM($0, action: "vm:read") },
            query: { id, start, end, limit, direction in
                try await req.lokiService.queryVMLogs(
                    vmId: id, start: start, end: end, limit: limit, direction: direction)
            })
    }

    /// GET /api/sandboxes/:sandboxID/logs
    /// Query a sandbox's workload stdout/stderr from Loki (issue #423),
    /// mirroring the VM logs endpoint.
    @Sendable
    func getSandboxLogs(req: Request) async throws -> [LogEntry] {
        try await queryLogs(
            req: req, parameter: "sandboxID", invalidReason: "Invalid sandbox ID",
            authorize: { _ = try await req.authorizedSandbox($0, action: "sandbox:read") },
            query: { id, start, end, limit, direction in
                try await req.lokiService.querySandboxLogs(
                    sandboxId: id, start: start, end: end, limit: limit, direction: direction)
            })
    }

    private func queryLogs(
        req: Request,
        parameter: String,
        invalidReason: String,
        authorize: @Sendable (UUID) async throws -> Void,
        query: @Sendable (String, Date?, Date?, Int, QueryDirection) async throws -> [LogEntry]
    ) async throws -> [LogEntry] {
        _ = try req.auth.require(User.self)

        guard let idString = req.parameters.get(parameter),
            let id = UUID(uuidString: idString)
        else {
            throw Abort(.badRequest, reason: invalidReason)
        }
        try await authorize(id)

        // Check if Loki is enabled
        guard req.application.lokiEnabled else {
            req.logger.warning("Loki not configured, returning empty logs")
            return []
        }

        let limit = try req.intQuery("limit", default: 100, in: 1...1000)
        let directionStr = req.query[String.self, at: "direction"] ?? "backward"
        let direction = QueryDirection(rawValue: directionStr) ?? .backward
        let start = req.query[Double.self, at: "start"].map(Date.init(timeIntervalSince1970:))
        let end = req.query[Double.self, at: "end"].map(Date.init(timeIntervalSince1970:))

        do {
            return try await query(idString, start, end, limit, direction)
        } catch {
            req.logger.error("Failed to query Loki: \(error)")
            throw Abort(.serviceUnavailable, reason: "Failed to query logs: \(error.localizedDescription)")
        }
    }
}
