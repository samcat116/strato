import Fluent
import Foundation
import SPIREServerAPI
import StratoShared
import Vapor

/// Stable refusal labels shared by audit and telemetry. Keeping the set closed
/// bounds metric cardinality and prevents the two observability surfaces from
/// disagreeing about why a mint was refused.
enum GuestIdentityRefusal: String, Sendable {
    case noClientCertificate = "no_client_certificate"
    case unauthenticated
    case rateLimited = "rate_limited"
    case unknownAgent = "unknown_agent"
    case invalidRequest = "invalid_request"
    case ttlInvalid = "ttl_invalid"
    case vmNotFound = "vm_not_found"
    case notPlacedHere = "not_placed_here"
    case identityRevoked = "identity_revoked"
    case audienceNotAllowed = "audience_not_allowed"
    case spireUnconfigured = "spire_unconfigured"
    case spireUnavailable = "spire_unavailable"
    case spiffeIDMismatch = "spiffe_id_mismatch"
}

/// `POST /agent/vms/:vmID/jwt-svid` — mint a guest JWT-SVID only after
/// proving that the authenticated agent currently hosts the named VM.
struct AgentGuestIdentityController: RouteCollection {
    private static let unavailableReason = "No guest identity is available for this VM"

    func boot(routes: any RoutesBuilder) throws {
        routes.post("agent", "vms", ":vmID", "jwt-svid", use: mint)
    }

    func mint(req: Request) async throws -> Response {
        guard AgentMTLSAuthenticator.hasClientCertificate(req) else {
            Telemetry.recordGuestIdentityMint(
                outcome: GuestIdentityRefusal.noClientCertificate.rawValue)
            req.logger.warning("Guest identity mint requires an agent client certificate")
            throw Abort(
                .unauthorized,
                reason: "Guest identity minting requires an agent client certificate")
        }

        let authenticatedAgent: AuthenticatedAgent
        do {
            authenticatedAgent = try await AgentMTLSAuthenticator.authenticateAgent(req: req)
        } catch {
            Telemetry.recordGuestIdentityMint(outcome: GuestIdentityRefusal.unauthenticated.rawValue)
            throw error
        }

        let rawVMID = req.parameters.get("vmID") ?? ""
        let rateLimit = await req.application.agentGuestIdentityRateLimiter?.hit(
            authenticatedAgent: authenticatedAgent,
            request: req)
        if let rateLimit, rateLimit.exceeded {
            _ = await refusalRecord(
                .rateLimited,
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: nil,
                resourceID: rawVMID,
                organizationID: authenticatedAgent.organizationID,
                audiences: [],
                spiffeID: nil,
                ttlSeconds: nil,
                expiresAt: nil,
                status: Int(HTTPResponseStatus.tooManyRequests.code))
            return rateLimit.limitedResponse()
        }

        guard
            let agentRow = try await Agent.query(on: req.db)
                .filter(\.$trustDomain == authenticatedAgent.identity.trustDomain)
                .filter(\.$name == authenticatedAgent.identity.name)
                .first(),
            let agentID = agentRow.id
        else {
            throw await refusal(
                .unknownAgent,
                status: .forbidden,
                reason: "No agent is registered for this identity",
                req: req,
                authenticatedAgent: authenticatedAgent,
                resourceID: rawVMID,
                organizationID: authenticatedAgent.organizationID)
        }
        let agentOrganizationID =
            (try? await agentRow.rootOrganizationID(on: req.db))
            ?? authenticatedAgent.organizationID

        guard let vmID = UUID(uuidString: rawVMID) else {
            throw await refusal(
                .invalidRequest,
                status: .badRequest,
                reason: "vmID must be a UUID",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: rawVMID,
                organizationID: agentOrganizationID)
        }

        let mintRequest: GuestJWTSVIDRequest
        do {
            guard let buffer = req.body.data else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Request body is required"))
            }
            mintRequest = try WireProtocol.makeDecoder().decode(
                GuestJWTSVIDRequest.self, from: Data(buffer.readableBytesView))
        } catch {
            throw await refusal(
                .invalidRequest,
                status: .badRequest,
                reason: "Request body must contain audiences and an optional ttlSeconds",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: agentOrganizationID)
        }

        let audiences = mintRequest.audiences.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard
            !audiences.isEmpty,
            audiences.count <= GuestIdentityLimits.maximumAudiencesPerRequest,
            audiences.allSatisfy(GuestIdentityLimits.isValidAudience)
        else {
            throw await refusal(
                .invalidRequest,
                status: .badRequest,
                reason: "audiences must contain 1 to \(GuestIdentityLimits.maximumAudiencesPerRequest) "
                    + "non-empty values with no control characters, at most "
                    + "\(GuestIdentityLimits.maximumAudienceCharacters) characters, and an encoded "
                    + "metadata target no larger than "
                    + "\(GuestIdentityLimits.maximumMetadataRequestTargetBytes) bytes",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: agentOrganizationID,
                audiences: audiences)
        }

        if let ttlSeconds = mintRequest.ttlSeconds, ttlSeconds <= 0 {
            throw await refusal(
                .ttlInvalid,
                status: .badRequest,
                reason: "ttlSeconds must be greater than zero",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: agentOrganizationID,
                audiences: audiences,
                ttlSeconds: ttlSeconds)
        }

        guard let vm = try await VM.find(vmID, on: req.db) else {
            throw await refusal(
                .vmNotFound,
                status: .notFound,
                reason: Self.unavailableReason,
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: agentOrganizationID,
                audiences: audiences,
                ttlSeconds: mintRequest.ttlSeconds)
        }

        let vmOrganizationID =
            await organizationID(for: vm, on: req.db)
            ?? agentOrganizationID

        guard vm.hypervisorId == agentID.uuidString else {
            throw await refusal(
                .notPlacedHere,
                status: .notFound,
                reason: Self.unavailableReason,
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: vmOrganizationID,
                audiences: audiences,
                ttlSeconds: mintRequest.ttlSeconds)
        }

        guard let registeredSPIFFEID = try await GuestIdentity.spiffeID(forVM: vmID, on: req.db)
        else {
            throw await refusal(
                .identityRevoked,
                status: .notFound,
                reason: Self.unavailableReason,
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: vmOrganizationID,
                audiences: audiences,
                ttlSeconds: mintRequest.ttlSeconds)
        }

        let config = req.application.guestIdentityIssuanceConfig
        guard config.permits(audiences: audiences) else {
            throw await refusal(
                .audienceNotAllowed,
                status: .forbidden,
                reason:
                    "One or more audiences are not allowed; configure GUEST_IDENTITY_AUDIENCES to enable guest JWT-SVID issuance",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: vmOrganizationID,
                audiences: audiences,
                spiffeID: registeredSPIFFEID,
                ttlSeconds: mintRequest.ttlSeconds)
        }

        let ttlSeconds = config.resolvedTTL(requested: mintRequest.ttlSeconds)
        guard
            let identity = SPIFFEIdentity(uri: registeredSPIFFEID),
            let registry = OrgSPIREClientRegistry.fromApplication(req.application)
        else {
            throw await refusal(
                .spireUnconfigured,
                status: .serviceUnavailable,
                reason: "No SPIRE service is configured for this guest identity",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: vmOrganizationID,
                audiences: audiences,
                spiffeID: registeredSPIFFEID,
                ttlSeconds: Int(ttlSeconds),
                expiresAt: nil)
        }

        let spire: SPIRERegistrationService
        do {
            guard
                let resolved = try await registry.service(
                    forTrustDomain: identity.trustDomain, on: req.db)
            else {
                throw Abort(
                    .serviceUnavailable,
                    reason: "No SPIRE service is configured for trust domain \(identity.trustDomain)")
            }
            spire = resolved
        } catch {
            _ = await refusalRecord(
                .spireUnconfigured,
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: vmOrganizationID,
                audiences: audiences,
                spiffeID: registeredSPIFFEID,
                ttlSeconds: Int(ttlSeconds),
                expiresAt: nil,
                status: Int(HTTPResponseStatus.serviceUnavailable.code))
            throw error
        }

        let svid: SPIREJWTSVID
        do {
            svid = try await spire.mintJWTSVID(
                spiffeID: registeredSPIFFEID,
                audience: audiences,
                ttlSeconds: ttlSeconds)
        } catch {
            req.logger.error(
                "SPIRE failed to mint a guest JWT-SVID",
                metadata: [
                    "strato.agent.id": .string(agentID.uuidString),
                    "spiffeId": .string(registeredSPIFFEID),
                    "audiences": .string(audiences.joined(separator: ",")),
                    "error": .string("\(error)"),
                ])
            throw await refusal(
                .spireUnavailable,
                status: .badGateway,
                reason: "SPIRE could not mint a guest identity",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: vmOrganizationID,
                audiences: audiences,
                spiffeID: registeredSPIFFEID,
                ttlSeconds: Int(ttlSeconds))
        }

        guard svid.spiffeID == registeredSPIFFEID else {
            throw await refusal(
                .spiffeIDMismatch,
                status: .badGateway,
                reason: "SPIRE returned a JWT-SVID for a different identity",
                req: req,
                authenticatedAgent: authenticatedAgent,
                agentID: agentID,
                resourceID: vmID.uuidString,
                organizationID: vmOrganizationID,
                audiences: audiences,
                spiffeID: registeredSPIFFEID,
                ttlSeconds: Int(ttlSeconds),
                expiresAt: svid.expiresAt)
        }

        Telemetry.recordGuestIdentityMint(outcome: "minted")
        req.logger.info(
            "Minted guest JWT-SVID",
            metadata: [
                "strato.agent.id": .string(agentID.uuidString),
                "spiffeId": .string(svid.spiffeID),
                "audiences": .string(audiences.joined(separator: ",")),
                "expiresAt": .string(svid.expiresAt.ISO8601Format()),
            ])
        await recordAudit(
            eventType: .guestIdentityMinted,
            reason: "minted",
            req: req,
            authenticatedAgent: authenticatedAgent,
            agentID: agentID,
            resourceID: vmID.uuidString,
            organizationID: vmOrganizationID,
            audiences: audiences,
            spiffeID: svid.spiffeID,
            ttlSeconds: Int(ttlSeconds),
            expiresAt: svid.expiresAt,
            status: Int(HTTPResponseStatus.ok.code))

        let body = try WireProtocol.makeEncoder().encode(
            GuestJWTSVIDResponse(
                token: svid.token,
                spiffeId: svid.spiffeID,
                audiences: audiences,
                expiresAt: svid.expiresAt,
                issuedAt: svid.issuedAt))
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = HTTPMediaType.json
        response.headers.cacheControl = HTTPHeaders.CacheControl(noStore: true)
        rateLimit?.applyHeaders(to: response)
        return response
    }

    private func organizationID(for vm: VM, on db: any Database) async -> UUID? {
        guard let project = try? await Project.find(vm.$project.id, on: db) else { return nil }
        return try? await project.getRootOrganizationId(on: db)
    }

    private func refusal(
        _ refusal: GuestIdentityRefusal,
        status: HTTPResponseStatus,
        reason: String,
        req: Request,
        authenticatedAgent: AuthenticatedAgent,
        agentID: UUID? = nil,
        resourceID: String,
        organizationID: UUID?,
        audiences: [String] = [],
        spiffeID: String? = nil,
        ttlSeconds: Int? = nil,
        expiresAt: Date? = nil
    ) async -> Abort {
        _ = await refusalRecord(
            refusal,
            req: req,
            authenticatedAgent: authenticatedAgent,
            agentID: agentID,
            resourceID: resourceID,
            organizationID: organizationID,
            audiences: audiences,
            spiffeID: spiffeID,
            ttlSeconds: ttlSeconds,
            expiresAt: expiresAt,
            status: Int(status.code))
        return Abort(status, reason: reason)
    }

    @discardableResult
    private func refusalRecord(
        _ refusal: GuestIdentityRefusal,
        req: Request,
        authenticatedAgent: AuthenticatedAgent,
        agentID: UUID?,
        resourceID: String,
        organizationID: UUID?,
        audiences: [String],
        spiffeID: String?,
        ttlSeconds: Int?,
        expiresAt: Date?,
        status: Int
    ) async -> GuestIdentityRefusal {
        Telemetry.recordGuestIdentityMint(outcome: refusal.rawValue)
        var logMetadata: Logger.Metadata = [
            "strato.vm.id": .string(resourceID),
            "reason": .string(refusal.rawValue),
            "audiences": .string(audiences.joined(separator: ",")),
        ]
        if let agentID {
            logMetadata["strato.agent.id"] = .string(agentID.uuidString)
        } else {
            logMetadata["strato.agent.identity"] = .string(authenticatedAgent.identity.key)
        }
        if let spiffeID { logMetadata["spiffeId"] = .string(spiffeID) }
        if let ttlSeconds { logMetadata["ttlSeconds"] = .stringConvertible(ttlSeconds) }
        if let expiresAt { logMetadata["expiresAt"] = .string(expiresAt.ISO8601Format()) }
        req.logger.warning(
            "Guest JWT-SVID mint refused",
            metadata: logMetadata)
        await recordAudit(
            eventType: .guestIdentityRefused,
            reason: refusal.rawValue,
            req: req,
            authenticatedAgent: authenticatedAgent,
            agentID: agentID,
            resourceID: resourceID,
            organizationID: organizationID,
            audiences: audiences,
            spiffeID: spiffeID,
            ttlSeconds: ttlSeconds,
            expiresAt: expiresAt,
            status: status)
        return refusal
    }

    private func recordAudit(
        eventType: AuditEventType,
        reason: String,
        req: Request,
        authenticatedAgent: AuthenticatedAgent,
        agentID: UUID?,
        resourceID: String,
        organizationID: UUID?,
        audiences: [String],
        spiffeID: String?,
        ttlSeconds: Int?,
        expiresAt: Date?,
        status: Int
    ) async {
        var metadata: [String: String] = [
            "agentId": agentID?.uuidString ?? authenticatedAgent.identity.key,
            "audiences": audiences.joined(separator: ","),
            "reason": reason,
        ]
        if let spiffeID { metadata["spiffeId"] = spiffeID }
        if let ttlSeconds { metadata["ttlSeconds"] = String(ttlSeconds) }
        if let expiresAt { metadata["expiresAt"] = expiresAt.ISO8601Format() }

        await req.audit.record(
            AuditRecord(
                eventType: eventType.rawValue,
                username: authenticatedAgent.identity.key,
                organizationID: organizationID,
                method: req.method.rawValue,
                path: req.url.path,
                status: status,
                resourceType: "virtual_machine",
                resourceID: resourceID,
                action: "mint_jwt_svid",
                sourceIP: req.auditClientIP,
                metadata: metadata))
    }
}
