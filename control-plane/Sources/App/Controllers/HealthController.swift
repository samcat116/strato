import Fluent
import SQLKit
import Vapor

struct HealthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let health = routes.grouped("health")

        // Overall health, including build identity. Dependency-free: use
        // /health/ready to gate traffic.
        health.get(use: self.health)

        // Readiness check - dependency connectivity plus this process's own
        // migration/drain gates. The only endpoint a load balancer should poll.
        health.get("ready", use: readiness)

        // Liveness check - basic application health
        health.get("live", use: liveness)
    }

    func health(req: Request) async throws -> HealthResponse {
        // Deliberately identical to liveness: an unauthenticated endpoint that
        // touches no dependency cannot be used to probe them.
        try await liveness(req: req)
    }

    func liveness(req: Request) async throws -> HealthResponse {
        // Basic liveness check - if we can respond, we're alive.
        // Includes per-boot identity so callers can tell *which* control plane
        // answered (the missing signal when a stale duplicate hijacked the port).
        return HealthResponse(
            status: HealthResponse.healthy,
            timestamp: Date(),
            checks: [
                HealthCheck(name: "application", status: "up")
            ],
            identity: ServiceIdentity(req.instanceIdentity)
        )
    }

    /// Readiness: "should this replica receive traffic right now?"
    ///
    /// Answers with the HTTP status, not just the body — a load balancer or
    /// `readinessProbe` reads the code, so a failed dependency has to surface as
    /// 503 or a broken replica silently stays in rotation through a blue/green
    /// cutover.
    ///
    /// Checks are graded, because not every dependency is equally fatal:
    ///
    /// - **database** (fatal) — nothing works without Postgres.
    /// - **migrations** (fatal) — schema application must have finished.
    /// - **spicedb** (fatal) — every authorized request goes through it, so a
    ///   replica that cannot reach it would 500 on effectively all traffic.
    /// - **valkey** (degraded) — coordination is documented as fail-open
    ///   (`docs/architecture/multi-replica.md`); agents still converge via the
    ///   periodic sync. Reported, but never a reason to pull a replica out of
    ///   rotation.
    /// - **drain** (fatal) — set once SIGTERM arrives.
    func readiness(req: Request) async throws -> Response {
        var checks: [HealthCheck] = []
        var failed = false
        var degraded = false

        // Draining is checked first and short-circuits: a replica on its way out
        // should not spend probe latency on dependencies it is about to drop.
        if req.readiness.isDraining {
            let response = HealthResponse(
                status: HealthResponse.draining,
                timestamp: Date(),
                checks: [HealthCheck(name: "drain", status: "draining")],
                identity: ServiceIdentity(req.instanceIdentity)
            )
            return try await response.encodeResponse(status: .serviceUnavailable, for: req)
        }

        // Database. `SELECT 1` rather than a model count: this runs on every
        // probe interval on every replica, and counting a table that grows with
        // the fleet turns the probe into a recurring sequential scan.
        do {
            guard let sql = req.db as? SQLDatabase else {
                throw Abort(.internalServerError, reason: "database does not support raw SQL")
            }
            try await sql.raw("SELECT 1").run()
            checks.append(HealthCheck(name: "database", status: "up"))
        } catch {
            checks.append(HealthCheck(name: "database", status: "down", error: String(reflecting: error)))
            failed = true
        }

        // Migrations. A reachable database says nothing about whether this
        // process finished applying schema to it.
        if req.readiness.migrationsComplete {
            checks.append(HealthCheck(name: "migrations", status: "up"))
        } else {
            checks.append(HealthCheck(name: "migrations", status: "down", error: "migrations have not completed"))
            failed = true
        }

        // SpiceDB. `readSchema` is the cheapest read on the API and exercises
        // the same client, endpoint, and preshared key that authorization uses.
        do {
            _ = try await req.spicedb.readSchema()
            checks.append(HealthCheck(name: "spicedb", status: "up"))
        } catch {
            checks.append(HealthCheck(name: "spicedb", status: "down", error: String(reflecting: error)))
            failed = true
        }

        // Valkey. Degraded-only by design: coordination fails open.
        do {
            _ = try await req.application.coordination.probe()
            checks.append(HealthCheck(name: "valkey", status: "up"))
        } catch {
            checks.append(HealthCheck(name: "valkey", status: "degraded", error: String(reflecting: error)))
            degraded = true
        }

        let status: String
        if failed {
            status = HealthResponse.unhealthy
        } else if degraded {
            status = HealthResponse.degraded
        } else {
            status = HealthResponse.healthy
        }

        let response = HealthResponse(
            status: status,
            timestamp: Date(),
            checks: checks,
            identity: ServiceIdentity(req.instanceIdentity)
        )
        // Degraded still serves traffic: pulling every replica out of rotation
        // because Valkey blipped would be a worse outage than the blip.
        return try await response.encodeResponse(status: failed ? .serviceUnavailable : .ok, for: req)
    }
}

struct HealthResponse: Content {
    /// Every dependency is reachable.
    static let healthy = "healthy"
    /// A fail-open dependency is unreachable; the replica still serves traffic.
    static let degraded = "degraded"
    /// A required dependency is unreachable or a gate has not opened.
    static let unhealthy = "unhealthy"
    /// Shutdown requested; the replica is finishing in-flight work.
    static let draining = "draining"

    let status: String
    let timestamp: Date
    let checks: [HealthCheck]
    let identity: ServiceIdentity?

    init(status: String, timestamp: Date, checks: [HealthCheck], identity: ServiceIdentity? = nil) {
        self.status = status
        self.timestamp = timestamp
        self.checks = checks
        self.identity = identity
    }
}

/// Identity of the control-plane process answering this request. Surfaced on the
/// health endpoints so two instances (e.g. a stale duplicate on the same port)
/// are immediately distinguishable by their per-boot `instanceId`.
struct ServiceIdentity: Content {
    let instanceId: String
    let startedAt: Date
    let version: String
    let gitSHA: String
    let environment: String

    init(_ identity: InstanceIdentity) {
        self.instanceId = identity.instanceId.uuidString
        self.startedAt = identity.startedAt
        self.version = BuildInfo.version
        self.gitSHA = BuildInfo.gitSHA
        self.environment = identity.environment
    }
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
