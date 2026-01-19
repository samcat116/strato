import Foundation
import Vapor

// MARK: - SPIRE Registration Service

/// Service for managing SPIRE registration entries
/// This service communicates with the SPIRE Server API to create and manage
/// agent registration entries, replacing the token-based registration flow.
public actor SPIRERegistrationService {
    private let config: SPIRERegistrationConfig
    private let logger: Logger
    private let httpClient: Client

    public init(config: SPIRERegistrationConfig, logger: Logger, httpClient: Client) {
        self.config = config
        self.logger = logger
        self.httpClient = httpClient
    }

    // MARK: - Agent Registration

    /// Create a SPIRE registration entry for a new agent
    /// This replaces the token generation flow - instead of generating a token,
    /// we create a SPIRE entry and return a join token for initial attestation.
    ///
    /// - Parameters:
    ///   - agentName: The name/identifier for the agent
    ///   - selectors: Workload attestation selectors (e.g., unix:uid:0, unix:path:/usr/bin/strato-agent)
    /// - Returns: Join token for the agent to use for initial attestation
    public func registerAgent(
        agentName: String,
        selectors: [WorkloadSelector] = []
    ) async throws -> AgentRegistrationResult {
        guard config.enabled else {
            throw SPIRERegistrationError.notConfigured
        }

        logger.info("Creating SPIRE registration entry for agent", metadata: [
            "agentName": .string(agentName)
        ])

        // Create the SPIFFE ID for this agent
        let spiffeID = "spiffe://\(config.trustDomain)/agent/\(agentName)"

        // First, create a join token for the agent to use for node attestation
        let joinToken = try await createJoinToken(agentName: agentName)

        // Then create the workload registration entry
        let entryID = try await createRegistrationEntry(
            spiffeID: spiffeID,
            parentID: "spiffe://\(config.trustDomain)/spire/agent/join_token/\(joinToken.token)",
            selectors: selectors.isEmpty ? defaultSelectors(for: agentName) : selectors
        )

        logger.info("SPIRE registration entry created", metadata: [
            "agentName": .string(agentName),
            "spiffeID": .string(spiffeID),
            "entryID": .string(entryID)
        ])

        return AgentRegistrationResult(
            spiffeID: spiffeID,
            entryID: entryID,
            joinToken: joinToken.token,
            joinTokenExpiry: joinToken.expiresAt
        )
    }

    /// Revoke an agent's SPIRE registration
    /// This removes the registration entry, preventing the agent from obtaining new SVIDs.
    ///
    /// - Parameter agentName: The name of the agent to revoke
    public func revokeAgent(agentName: String) async throws {
        guard config.enabled else {
            throw SPIRERegistrationError.notConfigured
        }

        let spiffeID = "spiffe://\(config.trustDomain)/agent/\(agentName)"

        logger.info("Revoking SPIRE registration for agent", metadata: [
            "agentName": .string(agentName),
            "spiffeID": .string(spiffeID)
        ])

        // Find and delete the registration entry
        let entryID = try await findEntryBySpiffeID(spiffeID)

        if let entryID = entryID {
            try await deleteRegistrationEntry(entryID: entryID)
            logger.info("SPIRE registration revoked", metadata: [
                "agentName": .string(agentName),
                "entryID": .string(entryID)
            ])
        } else {
            logger.warning("No SPIRE registration entry found for agent", metadata: [
                "agentName": .string(agentName)
            ])
        }
    }

    /// List all agent registrations
    public func listAgentRegistrations() async throws -> [AgentRegistrationInfo] {
        guard config.enabled else {
            throw SPIRERegistrationError.notConfigured
        }

        let entries = try await listRegistrationEntries()

        return entries.compactMap { entry -> AgentRegistrationInfo? in
            // Only return agent entries
            guard entry.spiffeID.contains("/agent/") else { return nil }

            let agentName = entry.spiffeID
                .replacingOccurrences(of: "spiffe://\(config.trustDomain)/agent/", with: "")

            return AgentRegistrationInfo(
                agentName: agentName,
                spiffeID: entry.spiffeID,
                entryID: entry.id,
                selectors: entry.selectors,
                createdAt: entry.createdAt
            )
        }
    }

    // MARK: - SPIRE Server API Calls

    private func createJoinToken(agentName: String) async throws -> JoinToken {
        let url = URI(string: "\(config.serverURL)/v1/jointoken")

        let body = JoinTokenRequest(
            ttl: config.joinTokenTTL,
            token: nil // Let SPIRE generate the token
        )

        let response = try await httpClient.post(url) { req in
            try req.content.encode(body)
            req.headers.add(name: .contentType, value: "application/json")
        }

        guard response.status == .ok || response.status == .created else {
            throw SPIRERegistrationError.serverError("Failed to create join token: HTTP \(response.status.code)")
        }

        let result = try response.content.decode(JoinTokenResponse.self)

        return JoinToken(
            token: result.value,
            expiresAt: Date().addingTimeInterval(TimeInterval(config.joinTokenTTL))
        )
    }

    private func createRegistrationEntry(
        spiffeID: String,
        parentID: String,
        selectors: [WorkloadSelector]
    ) async throws -> String {
        let url = URI(string: "\(config.serverURL)/v1/entry")

        let body = CreateEntryRequest(
            spiffe_id: SpiffeIDPayload(trust_domain: config.trustDomain, path: extractPath(from: spiffeID)),
            parent_id: SpiffeIDPayload(trust_domain: config.trustDomain, path: extractPath(from: parentID)),
            selectors: selectors.map { SelectorPayload(type: $0.type, value: $0.value) },
            x509_svid_ttl: config.svidTTL,
            jwt_svid_ttl: config.svidTTL
        )

        let response = try await httpClient.post(url) { req in
            try req.content.encode(body)
            req.headers.add(name: .contentType, value: "application/json")
        }

        guard response.status == .ok || response.status == .created else {
            throw SPIRERegistrationError.serverError("Failed to create entry: HTTP \(response.status.code)")
        }

        let result = try response.content.decode(CreateEntryResponse.self)
        return result.id
    }

    private func deleteRegistrationEntry(entryID: String) async throws {
        let url = URI(string: "\(config.serverURL)/v1/entry/\(entryID)")

        let response = try await httpClient.delete(url)

        guard response.status == .ok || response.status == .noContent else {
            throw SPIRERegistrationError.serverError("Failed to delete entry: HTTP \(response.status.code)")
        }
    }

    private func findEntryBySpiffeID(_ spiffeID: String) async throws -> String? {
        let entries = try await listRegistrationEntries()
        return entries.first { $0.spiffeID == spiffeID }?.id
    }

    private func listRegistrationEntries() async throws -> [RegistrationEntry] {
        let url = URI(string: "\(config.serverURL)/v1/entry")

        let response = try await httpClient.get(url)

        guard response.status == .ok else {
            throw SPIRERegistrationError.serverError("Failed to list entries: HTTP \(response.status.code)")
        }

        let result = try response.content.decode(ListEntriesResponse.self)
        return result.entries.map { entry in
            RegistrationEntry(
                id: entry.id,
                spiffeID: "spiffe://\(entry.spiffe_id.trust_domain)\(entry.spiffe_id.path)",
                parentID: "spiffe://\(entry.parent_id.trust_domain)\(entry.parent_id.path)",
                selectors: entry.selectors.map { WorkloadSelector(type: $0.type, value: $0.value) },
                createdAt: Date() // API doesn't always return creation time
            )
        }
    }

    // MARK: - Helper Methods

    private func defaultSelectors(for agentName: String) -> [WorkloadSelector] {
        // Default selectors for Strato Agent
        [
            WorkloadSelector(type: "unix", value: "uid:0"),
            WorkloadSelector(type: "unix", value: "path:/usr/local/bin/strato-agent")
        ]
    }

    private func extractPath(from spiffeID: String) -> String {
        guard let range = spiffeID.range(of: "spiffe://[^/]+", options: .regularExpression) else {
            return spiffeID
        }
        return String(spiffeID[range.upperBound...])
    }
}

// MARK: - Configuration

public struct SPIRERegistrationConfig: Sendable {
    /// Whether SPIRE registration is enabled
    public let enabled: Bool

    /// SPIRE Server API URL (e.g., "http://spire-server:8081")
    public let serverURL: String

    /// Trust domain for SPIFFE IDs
    public let trustDomain: String

    /// TTL for join tokens (seconds)
    public let joinTokenTTL: Int

    /// TTL for SVIDs (seconds)
    public let svidTTL: Int

    public init(
        enabled: Bool = false,
        serverURL: String = "http://localhost:8081",
        trustDomain: String = "strato.local",
        joinTokenTTL: Int = 600, // 10 minutes
        svidTTL: Int = 3600 // 1 hour
    ) {
        self.enabled = enabled
        self.serverURL = serverURL
        self.trustDomain = trustDomain
        self.joinTokenTTL = joinTokenTTL
        self.svidTTL = svidTTL
    }

    public static func fromEnvironment() -> SPIRERegistrationConfig {
        SPIRERegistrationConfig(
            enabled: Environment.get("SPIRE_ENABLED")?.lowercased() == "true",
            serverURL: Environment.get("SPIRE_SERVER_URL") ?? "http://localhost:8081",
            trustDomain: Environment.get("SPIRE_TRUST_DOMAIN") ?? "strato.local",
            joinTokenTTL: Int(Environment.get("SPIRE_JOIN_TOKEN_TTL") ?? "600") ?? 600,
            svidTTL: Int(Environment.get("SPIRE_SVID_TTL") ?? "3600") ?? 3600
        )
    }
}

// MARK: - Data Types

public struct WorkloadSelector: Sendable, Codable {
    public let type: String
    public let value: String

    public init(type: String, value: String) {
        self.type = type
        self.value = value
    }
}

public struct AgentRegistrationResult: Sendable {
    public let spiffeID: String
    public let entryID: String
    public let joinToken: String
    public let joinTokenExpiry: Date
}

public struct AgentRegistrationInfo: Sendable {
    public let agentName: String
    public let spiffeID: String
    public let entryID: String
    public let selectors: [WorkloadSelector]
    public let createdAt: Date
}

public struct JoinToken: Sendable {
    public let token: String
    public let expiresAt: Date
}

public struct RegistrationEntry: Sendable {
    public let id: String
    public let spiffeID: String
    public let parentID: String
    public let selectors: [WorkloadSelector]
    public let createdAt: Date
}

// MARK: - API Request/Response Types

private struct JoinTokenRequest: Content {
    let ttl: Int
    let token: String?
}

private struct JoinTokenResponse: Content {
    let value: String
}

private struct SpiffeIDPayload: Content {
    let trust_domain: String
    let path: String
}

private struct SelectorPayload: Content {
    let type: String
    let value: String
}

private struct CreateEntryRequest: Content {
    let spiffe_id: SpiffeIDPayload
    let parent_id: SpiffeIDPayload
    let selectors: [SelectorPayload]
    let x509_svid_ttl: Int
    let jwt_svid_ttl: Int
}

private struct CreateEntryResponse: Content {
    let id: String
}

private struct ListEntriesResponse: Content {
    let entries: [EntryPayload]
}

private struct EntryPayload: Content {
    let id: String
    let spiffe_id: SpiffeIDPayload
    let parent_id: SpiffeIDPayload
    let selectors: [SelectorPayload]
}

// MARK: - Errors

public enum SPIRERegistrationError: Error, LocalizedError {
    case notConfigured
    case serverError(String)
    case entryNotFound(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "SPIRE registration service is not configured"
        case .serverError(let message):
            return "SPIRE Server error: \(message)"
        case .entryNotFound(let spiffeID):
            return "Registration entry not found: \(spiffeID)"
        case .invalidResponse(let details):
            return "Invalid response from SPIRE Server: \(details)"
        }
    }
}

// MARK: - Vapor Application Extension

extension Application {
    private struct SPIRERegistrationServiceKey: StorageKey {
        typealias Value = SPIRERegistrationService
    }

    public var spireRegistrationService: SPIRERegistrationService? {
        get { storage[SPIRERegistrationServiceKey.self] }
        set { storage[SPIRERegistrationServiceKey.self] = newValue }
    }

    /// Configure SPIRE registration service
    public func configureSPIRERegistration() {
        let config = SPIRERegistrationConfig.fromEnvironment()

        guard config.enabled else {
            logger.info("SPIRE registration service is disabled")
            return
        }

        let service = SPIRERegistrationService(
            config: config,
            logger: logger,
            httpClient: client
        )

        spireRegistrationService = service
        logger.info("SPIRE registration service configured", metadata: [
            "serverURL": .string(config.serverURL),
            "trustDomain": .string(config.trustDomain)
        ])
    }
}
