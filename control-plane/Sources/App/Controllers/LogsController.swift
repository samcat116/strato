import Vapor
import Fluent
import StratoShared

struct LogsController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let logs = routes.grouped("api", "vms", ":vmID", "logs")

        logs.get(use: getVMLogs)
    }

    /// GET /api/vms/:vmID/logs
    /// Query logs for a specific VM from Loki
    @Sendable
    func getVMLogs(req: Request) async throws -> [LogEntry] {
        guard let vmIdString = req.parameters.get("vmID"),
              let vmId = UUID(uuidString: vmIdString) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        // Verify VM exists
        guard let _ = try await VM.find(vmId, on: req.db) else {
            throw Abort(.notFound, reason: "VM not found")
        }

        // Check if Loki is enabled
        guard req.application.lokiEnabled else {
            req.logger.warning("Loki not configured, returning empty logs")
            return []
        }

        // Parse query parameters
        let limit = min(req.query[Int.self, at: "limit"] ?? 100, 1000) // Cap at 1000
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
}
