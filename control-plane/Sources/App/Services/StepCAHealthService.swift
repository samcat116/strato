import Vapor
import Fluent
import Foundation

/// Service for monitoring step-ca health and managing integration
struct StepCAHealthService {
    let client: Client
    let logger: Logger
    let database: Database

    private var healthCheckTask: Task<Void, Error>?

    init(client: Client, logger: Logger, database: Database) {
        self.client = client
        self.logger = logger
        self.database = database
    }

    /// Start periodic health checks for step-ca
    mutating func startHealthChecks() {
        healthCheckTask = Task { [client, logger, database] in
            while !Task.isCancelled {
                do {
                    try await Self.performHealthCheck(client: client, logger: logger, database: database)
                    // Check every 5 minutes
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    logger.error("Step-CA health check failed: \(error)")
                    // Retry after 1 minute on error
                    try await Task.sleep(for: .seconds(60))
                }
            }
        }

        logger.info("Started step-ca health monitoring service")
    }

    /// Stop health checks
    mutating func stopHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        logger.info("Stopped step-ca health monitoring service")
    }

    /// Perform health check on step-ca
    private static func performHealthCheck(client: Client, logger: Logger, database: Database) async throws {
        let stepCAClient = try StepCAClient(
            client: client,
            logger: logger,
            database: database
        )

        let isHealthy = try await stepCAClient.healthCheck()

        if isHealthy {
            logger.debug("Step-CA health check passed")
        } else {
            logger.warning("Step-CA health check failed - service may be unavailable")
        }

        // Additional maintenance tasks
        try await performMaintenanceTasks(stepCAClient: stepCAClient, database: database, logger: logger)
    }

    /// Perform routine maintenance tasks
    private static func performMaintenanceTasks(
        stepCAClient: StepCAClient,
        database: Database,
        logger: Logger
    ) async throws {
        // Clean up expired certificates from database
        let expiredCertificates = try await AgentCertificate.query(on: database)
            .filter(\.$status == .active)
            .filter(\.$expiresAt < Date())
            .all()

        if !expiredCertificates.isEmpty {
            for certificate in expiredCertificates {
                certificate.status = .expired
                try await certificate.save(on: database)
            }

            logger.info("Marked expired certificates as expired", metadata: [
                "count": .stringConvertible(expiredCertificates.count)
            ])
        }

        // Check for certificates needing renewal (within 24 hours of expiry)
        let renewalThreshold = Date().addingTimeInterval(24 * 60 * 60) // 24 hours
        let certificatesNeedingRenewal = try await AgentCertificate.query(on: database)
            .filter(\.$status == .active)
            .filter(\.$expiresAt < renewalThreshold)
            .filter(\.$expiresAt > Date()) // Not expired yet
            .all()

        if !certificatesNeedingRenewal.isEmpty {
            logger.info("Certificates needing renewal soon", metadata: [
                "count": .stringConvertible(certificatesNeedingRenewal.count),
                "agentIds": .array(certificatesNeedingRenewal.map { .string($0.agentId) })
            ])
        }

        // Log certificate statistics
        let totalActive = try await AgentCertificate.query(on: database)
            .filter(\.$status == .active)
            .count()

        let totalRevoked = try await AgentCertificate.query(on: database)
            .filter(\.$status == .revoked)
            .count()

        logger.debug("Certificate statistics", metadata: [
            "activeCertificates": .stringConvertible(totalActive),
            "revokedCertificates": .stringConvertible(totalRevoked),
            "expiredCertificates": .stringConvertible(expiredCertificates.count),
            "certificatesNeedingRenewal": .stringConvertible(certificatesNeedingRenewal.count)
        ])
    }
}