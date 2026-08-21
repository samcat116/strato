import ControlPlanePostgres
import Foundation
import SwiftSSF
import Vapor

/// Handles verified Security Event Tokens for one SSF stream (issue #38):
/// maps the SET's subject to a user in the stream's organization and applies
/// the response appropriate to each signal.
///
/// Signal → action mapping:
/// - CAEP `session-revoked`, RISC `sessions-revoked` (deprecated),
///   RISC `account-credential-change-required` → revoke all sessions
///   (bump `User.sessionEpoch`).
/// - RISC `credential-compromise` → revoke all sessions and deactivate the
///   user's API keys.
/// - RISC `account-disabled`, `account-purged` → disable the account and
///   revoke sessions. Purge never deletes data automatically — deletion is
///   destructive and stays a human decision.
/// - RISC `account-enabled` → re-enable the account.
/// - SSF `verification` → mark the stream verified.
/// - Everything else is audited and otherwise ignored.
///
/// Every received event and every applied action is recorded through the
/// audit service. Failures on one event type don't block the others in the
/// same SET.
struct SSFSignalProcessor: SSFEventHandler {
    let app: Application
    let apiKeys: APIKeysPersistence
    let streams: SSFStreamsPersistence
    let userSecurity: UserSecurityPersistence
    let streamID: UUID
    let organizationID: UUID

    func handleEvent(_ token: SecurityEventToken) async throws {
        let types = token.payload.eventTypes
        await audit(
            "ssf.event_received",
            metadata: [
                "jti": token.payload.jti,
                "iss": token.payload.iss.absoluteString,
                "eventTypes": types.joined(separator: ","),
            ])
        await touchStream()

        for type in types {
            switch type {
            case SSFEventTypes.verification:
                await markStreamVerified()
            case SSFEventTypes.streamUpdated:
                // Level-triggered stream state changes (paused/disabled) are
                // informational for us: polling reacts to errors, push simply
                // stops arriving. Audit and move on.
                await audit("ssf.stream_updated", metadata: ["jti": token.payload.jti])
            default:
                await handleSecuritySignal(type, token: token)
            }
        }
    }

    func handleError(_ error: SSFError, token: SecurityEventToken?) async {
        app.logger.warning(
            "SSF event processing failed",
            metadata: [
                "streamID": .string(streamID.uuidString),
                "error": .string("\(error)"),
            ])
        await audit("ssf.event_error", metadata: ["error": "\(error)"])
    }

    // MARK: - Signal dispatch

    private func handleSecuritySignal(_ type: String, token: SecurityEventToken) async {
        do {
            guard let user = try await resolveSubject(for: type, in: token) else {
                await audit(
                    "ssf.subject_unmatched",
                    metadata: ["jti": token.payload.jti, "eventType": type])
                return
            }

            switch type {
            case CAEPEventTypes.sessionRevoked,
                RISCEventTypes.sessionsRevoked,
                RISCEventTypes.accountCredentialChangeRequired:
                try await revokeSessions(of: user, eventType: type)

            case RISCEventTypes.credentialCompromise:
                try await revokeSessions(of: user, eventType: type)
                try await deactivateAPIKeys(of: user, eventType: type)

            case RISCEventTypes.accountDisabled, RISCEventTypes.accountPurged:
                try await disable(user, eventType: type)

            case RISCEventTypes.accountEnabled:
                try await enable(user, eventType: type)

            default:
                await audit(
                    "ssf.event_ignored",
                    metadata: [
                        "jti": token.payload.jti,
                        "eventType": type,
                        "targetUserID": user.id.uuidString,
                    ])
            }
        } catch {
            app.logger.error(
                "SSF signal handler failed",
                metadata: [
                    "streamID": .string(streamID.uuidString),
                    "eventType": .string(type),
                    "error": .string("\(error)"),
                ])
            await audit("ssf.event_error", metadata: ["eventType": type, "error": "\(error)"])
        }
    }

    // MARK: - Actions

    private func revokeSessions(of user: UserSecuritySnapshot, eventType: String) async throws {
        guard let updated = try await userSecurity.revokeSessions(userID: user.id) else { return }
        await audit("ssf.sessions_revoked", user: updated, eventType: eventType)
    }

    private func deactivateAPIKeys(of user: UserSecuritySnapshot, eventType: String) async throws {
        let count = try await apiKeys.deactivateAll(userID: user.id)
        guard count > 0 else { return }
        await audit(
            "ssf.api_keys_deactivated", user: user, eventType: eventType,
            extra: ["deactivatedKeys": "\(count)"])
    }

    private func disable(_ user: UserSecuritySnapshot, eventType: String) async throws {
        guard
            let updated = try await userSecurity.disable(
                userID: user.id,
                disabledAt: Date()
            )
        else { return }
        await audit("ssf.user_disabled", user: updated, eventType: eventType)
    }

    private func enable(_ user: UserSecuritySnapshot, eventType: String) async throws {
        guard let updated = try await userSecurity.enable(userID: user.id) else { return }
        await audit("ssf.user_enabled", user: updated, eventType: eventType)
    }

    // MARK: - Subject resolution

    /// Resolve the SET's subject to a user, requiring membership in the
    /// stream's organization: a transmitter configured for one org must never
    /// act on another org's users.
    private func resolveSubject(
        for eventType: String,
        in token: SecurityEventToken
    ) async throws -> UserSecuritySnapshot? {
        var subject = token.payload.sub_id
        if subject == nil, let claims = token.payload.events[eventType] {
            // RISC-style SETs may carry the subject inside the event payload
            // rather than as a top-level sub_id claim.
            subject = decodeSubject(claims["subject"]) ?? decodeSubject(claims["sub_id"])
        }
        guard let subject else { return nil }
        return try await findUser(matching: subject)
    }

    private func findUser(matching subject: SubjectIdentifier) async throws -> UserSecuritySnapshot? {
        switch subject.format {
        case "email":
            guard let email = subject.string("email") else { return nil }
            return try await userSecurity.organizationMember(
                email: email,
                organizationID: organizationID
            )

        case "opaque":
            // Opaque ids are only meaningful when the transmitter echoes our
            // own user ids back (e.g. subjects we added to the stream).
            guard let raw = subject.string("id"), let id = UUID(uuidString: raw) else { return nil }
            return try await userSecurity.organizationMember(
                id: id,
                organizationID: organizationID
            )

        case "iss_sub":
            // OIDC subs are only unique per issuer, so the lookup must be
            // scoped: the user's OIDC provider has to belong to the stream's
            // organization and be for the subject's issuer. Ambiguity fails
            // safe (no action).
            guard let sub = subject.string("sub"), let iss = subject.string("iss") else { return nil }
            let candidates = try await userSecurity.oidcOrganizationMembers(
                subject: sub,
                organizationID: organizationID
            )
            let matches = candidates.filter { candidate in
                Self.providerMatchesIssuer(candidate, issuer: iss)
            }
            return matches.count == 1 ? matches.first?.user : nil

        case "complex":
            guard let userSubject = subject.subject("user") else { return nil }
            return try await findUser(matching: userSubject)

        case "aliases":
            guard let members = try? decodeAliases(subject) else { return nil }
            for alias in members {
                if let user = try await findUser(matching: alias) {
                    return user
                }
            }
            return nil

        default:
            return nil
        }
    }

    /// Whether an OIDC provider is for the given issuer. Providers don't
    /// store the issuer directly, but every configured endpoint lives under
    /// it: the discovery URL is `<issuer>/.well-known/openid-configuration`,
    /// and the authorization/token/JWKS endpoints are issuer-rooted.
    static func providerMatchesIssuer(
        _ provider: OIDCUserSecurityCandidate,
        issuer: String
    ) -> Bool {
        let normalizedIssuer = issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
        let endpoints = [
            provider.discoveryURL, provider.authorizationEndpoint,
            provider.tokenEndpoint, provider.jwksURI,
        ]
        return endpoints.contains { endpoint in
            guard let endpoint else { return false }
            return endpoint == normalizedIssuer
                || endpoint.hasPrefix(normalizedIssuer + "/")
        }
    }

    private func decodeAliases(_ subject: SubjectIdentifier) throws -> [SubjectIdentifier] {
        guard let raw = subject.members["identifiers"] else { return [] }
        let data = try JSONEncoder().encode(raw)
        return try JSONDecoder().decode([SubjectIdentifier].self, from: data)
    }

    // swift-ssf#16 replaced the untyped `AnyCodable` event claims with
    // `JSONValue`, which carries its own JSON round-trip.
    private func decodeSubject(_ value: JSONValue?) -> SubjectIdentifier? {
        guard let value else { return nil }
        return try? value.decode(as: SubjectIdentifier.self)
    }

    // MARK: - Stream row updates

    private func touchStream() async {
        _ = try? await streams.recordEvent(id: streamID, at: Date())
    }

    private func markStreamVerified() async {
        guard (try? await streams.markVerified(id: streamID, at: Date())) == true else { return }
        await audit("ssf.stream_verified", metadata: [:])
    }

    // MARK: - Audit

    private func audit(_ type: String, metadata: [String: String]) async {
        var metadata = metadata
        metadata["ssfStreamID"] = streamID.uuidString
        await app.audit.record(
            AuditRecord(
                eventType: type,
                organizationID: organizationID,
                resourceType: "ssf_stream",
                resourceID: streamID.uuidString,
                metadata: metadata
            ))
    }

    private func audit(
        _ type: String,
        user: UserSecuritySnapshot,
        eventType: String,
        extra: [String: String] = [:]
    ) async {
        var metadata = extra
        metadata["eventType"] = eventType
        metadata["targetUserID"] = user.id.uuidString
        metadata["targetUsername"] = user.username
        await audit(type, metadata: metadata)
    }
}
