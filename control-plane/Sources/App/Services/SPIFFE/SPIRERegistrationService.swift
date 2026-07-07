import Foundation
import SPIREServerAPI
import Vapor

// MARK: - SPIRE Registration Service

/// Provisions hypervisor nodes in SPIRE as part of the agent registration
/// flow. Creating an agent registration token also creates, via the SPIRE
/// Server registration API:
///
/// - a one-time **join token** the node's spire-agent uses for node
///   attestation, bound to the stable node ID `spiffe://<td>/node/<name>`
///   (so re-provisioning the same node keeps the same identity), and
/// - a **workload registration entry** entitling the node's strato-agent to
///   `spiffe://<td>/agent/<name>` — the identity `SPIREService` expects on
///   the mTLS WebSocket path.
///
/// Deleting an unused registration token or deregistering an agent removes
/// the entry again, which stops SVID issuance for that node.
public struct SPIRERegistrationService: Sendable {
    private let api: any SPIREServerAPI
    private let config: SPIRERegistrationConfig
    private let logger: Logger

    public init(api: any SPIREServerAPI, config: SPIRERegistrationConfig, logger: Logger) {
        self.api = api
        self.config = config
        self.logger = logger
    }

    /// The workload SVID identity for an agent, matching what
    /// `SPIREService.validateAgentIdentity` accepts.
    public func agentSPIFFEID(agentName: String) -> String {
        "spiffe://\(config.trustDomain)/agent/\(agentName)"
    }

    /// The stable node identity assigned at join-token attestation.
    public func nodeSPIFFEID(agentName: String) -> String {
        "spiffe://\(config.trustDomain)/node/\(agentName)"
    }

    /// Provision a node in SPIRE: mint a join token and create the workload
    /// entry. An entry identical to an existing one is reused (idempotent
    /// re-issue after a token expired unredeemed).
    public func provisionAgent(named agentName: String, joinTokenTTLSeconds: Int32) async throws
        -> SPIREAgentProvisioning
    {
        guard Self.isValidAgentName(agentName) else {
            throw SPIRERegistrationError.invalidAgentName(agentName)
        }

        let nodeID = nodeSPIFFEID(agentName: agentName)
        let spiffeID = agentSPIFFEID(agentName: agentName)

        let joinToken = try await api.createJoinToken(ttlSeconds: joinTokenTTLSeconds, agentID: nodeID)

        let entryResult: SPIREEntryCreationResult
        do {
            entryResult = try await api.createEntry(
                spiffeID: spiffeID,
                parentID: nodeID,
                selectors: config.agentSelectors,
                x509SVIDTTLSeconds: Int32(config.svidTTLSeconds)
            )
        } catch {
            // The minted join token cannot be revoked through the API; it is
            // single-use and expires on its own, so the failed provisioning
            // leaves nothing an attacker can redeem for a workload identity.
            logger.error(
                "SPIRE workload entry creation failed after join token was minted",
                metadata: [
                    "agentName": .string(agentName),
                    "error": .string("\(error)"),
                ])
            throw error
        }

        let entryReused: Bool
        if case .alreadyExists = entryResult { entryReused = true } else { entryReused = false }

        logger.info(
            "Provisioned agent in SPIRE",
            metadata: [
                "agentName": .string(agentName),
                "spiffeID": .string(spiffeID),
                "entryID": .string(entryResult.entryID),
                "entryReused": .string(entryReused ? "yes" : "no"),
            ])

        return SPIREAgentProvisioning(
            joinToken: joinToken.value,
            joinTokenExpiresAt: joinToken.expiresAt,
            spiffeID: spiffeID,
            nodeID: nodeID,
            trustDomain: config.trustDomain,
            serverAddress: config.serverPublicAddress
        )
    }

    /// Best-effort rollback of `provisionAgent` (used when the registration
    /// token could not be persisted after SPIRE was provisioned). Failures are
    /// logged, not thrown — the caller is already propagating the original
    /// error, and an orphaned entry is recreated/reused on retry.
    public func rollbackProvisioning(agentName: String) async {
        do {
            _ = try await api.deleteEntries(spiffeID: agentSPIFFEID(agentName: agentName))
        } catch {
            logger.warning(
                "Failed to roll back SPIRE provisioning; the entry will be reused on retry",
                metadata: [
                    "agentName": .string(agentName),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// Remove the agent's workload entry, stopping further SVID issuance for
    /// the node. Throws when SPIRE cannot be reached — callers must fail
    /// closed rather than report a revocation that did not happen.
    public func deprovisionAgent(named agentName: String) async throws {
        let spiffeID = agentSPIFFEID(agentName: agentName)
        let deleted = try await api.deleteEntries(spiffeID: spiffeID)

        logger.info(
            "Deprovisioned agent in SPIRE",
            metadata: [
                "agentName": .string(agentName),
                "spiffeID": .string(spiffeID),
                "entriesDeleted": .string("\(deleted)"),
            ])
    }

    /// Agent names become SPIFFE ID path segments; restrict them to the
    /// characters the SPIFFE spec allows there so a name can never alter the
    /// meaning of the ID (path separators, dot segments, …).
    static func isValidAgentName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_"
                    || character == ".")
        }
    }
}

// MARK: - Provisioning result

/// Everything a new hypervisor node needs to attest to SPIRE, returned once
/// alongside the WebSocket registration token and never persisted.
public struct SPIREAgentProvisioning: Sendable {
    public let joinToken: String
    public let joinTokenExpiresAt: Date
    public let spiffeID: String
    public let nodeID: String
    public let trustDomain: String
    /// The SPIRE server address (host:port) nodes dial for attestation.
    public let serverAddress: String
}

// MARK: - Configuration

public struct SPIRERegistrationConfig: Sendable {
    /// Trust domain for SPIFFE IDs.
    public let trustDomain: String

    /// Where the control plane reaches the SPIRE server registration API
    /// (`unix:///path/to/api.sock`, or `host:port` for a loopback dev bridge).
    public let serverAPIAddress: SPIREServerAPIAddress

    /// The SPIRE server address handed to nodes for attestation (host:port).
    public let serverPublicAddress: String

    /// Workload attestation selectors for strato-agent entries.
    public let agentSelectors: [SPIRESelector]

    /// TTL for issued X.509 SVIDs (seconds).
    public let svidTTLSeconds: Int

    public init(
        trustDomain: String,
        serverAPIAddress: SPIREServerAPIAddress,
        serverPublicAddress: String,
        agentSelectors: [SPIRESelector],
        svidTTLSeconds: Int
    ) {
        self.trustDomain = trustDomain
        self.serverAPIAddress = serverAPIAddress
        self.serverPublicAddress = serverPublicAddress
        self.agentSelectors = agentSelectors
        self.svidTTLSeconds = svidTTLSeconds
    }

    /// Build from the environment, or nil when SPIRE registration is not
    /// configured (`SPIRE_ENABLED` unset/false, or no
    /// `SPIRE_SERVER_API_ADDRESS`). Throws when configured but invalid —
    /// starting up with silently-broken provisioning would surface as
    /// confusing 502s later.
    public static func fromEnvironment() throws -> SPIRERegistrationConfig? {
        guard Environment.get("SPIRE_ENABLED")?.lowercased() == "true" else { return nil }
        guard let apiAddressString = Environment.get("SPIRE_SERVER_API_ADDRESS"), !apiAddressString.isEmpty
        else { return nil }

        let apiAddress = try SPIREServerAPIAddress(parsing: apiAddressString)
        let trustDomain = Environment.get("SPIRE_TRUST_DOMAIN") ?? "strato.local"

        // The address nodes dial for attestation. Falls back to the
        // externally visible control-plane host with SPIRE's conventional
        // node-API port, which matches the single-host compose deployment.
        let publicAddress: String
        if let configured = Environment.get("SPIRE_SERVER_PUBLIC_ADDRESS"), !configured.isEmpty {
            publicAddress = configured
        } else if let external = Environment.get("EXTERNAL_HOSTNAME") {
            publicAddress = "\(AgentController.sanitizedHost(external).split(separator: ":").first ?? "localhost"):8085"
        } else {
            publicAddress = "localhost:8085"
        }

        let selectorsString = Environment.get("SPIRE_AGENT_SELECTORS") ?? "unix:uid:0"
        var selectors: [SPIRESelector] = []
        for part in selectorsString.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let selector = SPIRESelector(string: trimmed) else {
                throw SPIRERegistrationError.invalidConfiguration(
                    "SPIRE_AGENT_SELECTORS entry is not type:value: \(trimmed)")
            }
            selectors.append(selector)
        }
        guard !selectors.isEmpty else {
            throw SPIRERegistrationError.invalidConfiguration("SPIRE_AGENT_SELECTORS must not be empty")
        }

        return SPIRERegistrationConfig(
            trustDomain: trustDomain,
            serverAPIAddress: apiAddress,
            serverPublicAddress: publicAddress,
            agentSelectors: selectors,
            svidTTLSeconds: Int(Environment.get("SPIRE_SVID_TTL") ?? "3600") ?? 3600
        )
    }
}

// MARK: - Errors

public enum SPIRERegistrationError: Error, LocalizedError {
    case invalidAgentName(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAgentName(let name):
            return
                "Agent name '\(name)' cannot be used as a SPIFFE ID path segment (allowed: ASCII letters, digits, '-', '_', '.')"
        case .invalidConfiguration(let details):
            return "Invalid SPIRE registration configuration: \(details)"
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

    /// Configure SPIRE join-token provisioning for the agent registration
    /// flow. No-op unless `SPIRE_ENABLED=true` and `SPIRE_SERVER_API_ADDRESS`
    /// is set, so token-auth deployments and mTLS deployments that provision
    /// SPIRE out of band keep working unchanged.
    public func configureSPIRERegistration() throws {
        guard let config = try SPIRERegistrationConfig.fromEnvironment() else {
            if Environment.get("SPIRE_ENABLED")?.lowercased() == "true" {
                logger.notice(
                    "SPIRE is enabled but SPIRE_SERVER_API_ADDRESS is not set; registration tokens will not include SPIRE join tokens"
                )
            }
            return
        }

        let client = SPIREServerAPIClient(address: config.serverAPIAddress, logger: logger)
        spireRegistrationService = SPIRERegistrationService(api: client, config: config, logger: logger)

        logger.info(
            "SPIRE registration provisioning configured",
            metadata: [
                "trustDomain": .string(config.trustDomain),
                "serverPublicAddress": .string(config.serverPublicAddress),
            ])
    }
}
