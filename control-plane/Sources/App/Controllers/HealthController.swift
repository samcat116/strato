import ControlPlanePostgres
import Vapor

struct HealthController: RouteCollection {
    let database: ControlPlanePostgres.PostgresDatabase

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
            identity: ServiceIdentity(
                req.instanceIdentity, configuration: req.controlPlaneConfiguration)
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
    /// - **database** (fatal) — nothing works without Postgres; authorization
    ///   itself evaluates in-process against it, so no separate authz probe.
    /// - **migrations** (fatal) — schema application must have finished.
    /// - **coordination** (degraded) — the coordination store is documented as
    ///   fail-open (`docs/architecture/multi-replica.md`); agents still converge
    ///   via their unconditional refetch. Reported, but never a reason to pull
    ///   a replica out of rotation.
    /// - **session-store** (fatal when it is its own endpoint, else degraded) —
    ///   Valkey-backed like coordination, but it can be a *different* Valkey
    ///   (issue #855), and the grade follows that. Readiness only helps when a
    ///   failure is replica-local: a separate session endpoint can fail on its
    ///   own, so leaving the rotation sends browser auth somewhere healthy;
    ///   a shared endpoint fails for every replica at once, so 503 shifts
    ///   traffic nowhere and merely drops the traffic sessions don't back
    ///   (agent mTLS, API keys, the reconciler). Absent under `.testing`, which
    ///   uses Fluent sessions.
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
                identity: ServiceIdentity(
                    req.instanceIdentity, configuration: req.controlPlaneConfiguration)
            )
            return try await response.encodeResponse(status: .serviceUnavailable, for: req)
        }

        // PostgresStoreContext. `SELECT 1` rather than a model count: this runs on every
        // probe interval on every replica, and counting a table that grows with
        // the fleet turns the probe into a recurring sequential scan.
        do {
            try await database.healthCheck()
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

        // Coordination store. Degraded-only by design: coordination fails open.
        do {
            _ = try await req.application.coordination.probe()
            checks.append(HealthCheck(name: "coordination", status: "up"))
        } catch {
            checks.append(HealthCheck(name: "coordination", status: "degraded", error: String(reflecting: error)))
            degraded = true
        }

        // Session store. Graded on whether it can fail *independently*, because
        // that is the only case where pulling this replica helps.
        //
        // A separate session endpoint can go down while this replica's
        // coordination store and Postgres stay healthy, and a replica that
        // cannot read sessions cannot authenticate a browser — so leaving the
        // rotation lets a load balancer send that traffic somewhere useful.
        //
        // When the two share one endpoint (the default: compose, and Helm with
        // `sessionValkey.host` unset), failing readiness shifts traffic
        // nowhere — every replica shares that instance, so they all fail
        // together and kube-proxy simply drops the whole service. That costs
        // the traffic sessions do *not* back: agents authenticate by SPIFFE
        // mTLS and API-key/CLI clients by key, neither reads `vrs-*`, and the
        // reconciler needs only Postgres to converge. So the shared case is
        // graded `degraded`, which is what the fail-open coordination contract
        // has always meant here.
        //
        // Unknown configuration (no `valkeyConfiguration`, i.e. only in tests
        // that install a store by hand) grades fatal — the conservative side.
        if let sessionStore = req.application.sessionStore {
            let sharesCoordinationEndpoint = req.application.valkeyConfiguration?.sharesOneInstance ?? false
            do {
                try await withStoreTimeout(CoordinationService.storeDeadline) {
                    try await sessionStore.probeReachability()
                }
                checks.append(HealthCheck(name: "session-store", status: "up"))
            } catch {
                if sharesCoordinationEndpoint {
                    checks.append(
                        HealthCheck(name: "session-store", status: "degraded", error: String(reflecting: error)))
                    degraded = true
                } else {
                    checks.append(
                        HealthCheck(name: "session-store", status: "down", error: String(reflecting: error)))
                    failed = true
                }
            }
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
            identity: ServiceIdentity(
                req.instanceIdentity, configuration: req.controlPlaneConfiguration)
        )
        // Degraded still serves traffic: pulling every replica out of rotation
        // because the coordination store blipped would be a worse outage than
        // the blip. A failed session store is a different matter and lands in
        // `failed` above.
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

    init(_ identity: InstanceIdentity, configuration: ControlPlaneConfiguration) {
        self.instanceId = identity.instanceId.uuidString
        self.startedAt = identity.startedAt
        self.version = BuildInfo.version(configuration: configuration)
        self.gitSHA = BuildInfo.gitSHA(configuration: configuration)
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
