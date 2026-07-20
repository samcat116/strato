import Fluent
import Foundation
import SQLKit
import Vapor

/// OAuth 2.0 Device Authorization Grant (RFC 8628) provider endpoints for the
/// `strato` CLI, plus the session-authenticated approval and session
/// management API used by the web frontend.
///
/// The `/oauth/*` routes are public (the polling client has no credentials
/// yet) and speak the standard OAuth wire format: form-encoded requests,
/// snake_case JSON responses, errors as HTTP 400 `{error, error_description}`.
/// The `/api/oauth/*` routes require a browser session like every other API
/// route.
struct OAuthController: RouteCollection {
    /// Device authorization requests expire after 15 minutes.
    static let deviceCodeLifetime: TimeInterval = 15 * 60
    /// Minimum seconds between polls of `/oauth/token` for one device code.
    static let pollInterval = 5

    func boot(routes: RoutesBuilder) throws {
        // The public handlers convert thrown OAuthErrors to the RFC error
        // shape here; Vapor's ErrorMiddleware would otherwise render them as
        // `{reason}` and drop the machine-readable `error` code the polling
        // CLI dispatches on.
        let oauth = routes.grouped("oauth")
        oauth.post("device_authorization") { req in
            try await Self.encodingOAuthErrors(req) { try await self.deviceAuthorization(req: $0) }
        }
        oauth.post("token") { req in
            try await Self.encodingOAuthErrors(req) { try await self.token(req: $0) }
        }
        oauth.post("revoke", use: revoke)

        let api = routes.grouped("api", "oauth")
        api.group("device", ":userCode") { device in
            device.get(use: pendingDevice)
            device.post("approve", use: approveDevice)
            device.post("deny", use: denyDevice)
        }
        api.get("sessions", use: listSessions)
        api.delete("sessions", ":sessionID", use: revokeSession)
    }

    // MARK: - Public OAuth endpoints

    private static func encodingOAuthErrors<T: AsyncResponseEncodable>(
        _ req: Request,
        _ handler: (Request) async throws -> T
    ) async throws -> Response {
        do {
            return try await handler(req).encodeResponse(for: req)
        } catch let error as OAuthError {
            return try await error.encodeResponse(for: req)
        }
    }

    struct DeviceAuthorizationRequest: Content {
        let clientName: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case clientName = "client_name"
            case scope
        }
    }

    func deviceAuthorization(req: Request) async throws -> DeviceAuthorizationResponse {
        let request =
            (try? req.content.decode(DeviceAuthorizationRequest.self))
            ?? DeviceAuthorizationRequest(clientName: nil, scope: nil)

        let scopes = (request.scope ?? "read write").split(separator: " ").map(String.init)
        for scope in scopes {
            guard APIKeyScope.validValues.contains(scope) else {
                throw OAuthError.invalidScope("Invalid scope: \(scope)")
            }
        }

        // Opportunistic cleanup instead of a background sweep: pending rows
        // are only useful for 15 minutes, and this endpoint is rate-limited.
        try await DeviceAuthorization.query(on: req.db)
            .filter(\.$expiresAt < Date())
            .delete()

        let deviceCode = DeviceAuthorization.generateDeviceCode()
        var userCode = DeviceAuthorization.generateUserCode()
        // The user-code space is small (20^8); retry on the unlikely collision
        // with a live code.
        for _ in 0..<3 {
            let taken =
                try await DeviceAuthorization.query(on: req.db)
                .filter(\.$userCode == userCode)
                .count() > 0
            if !taken { break }
            userCode = DeviceAuthorization.generateUserCode()
        }

        let authorization = DeviceAuthorization(
            deviceCodeHash: DeviceAuthorization.hashCode(deviceCode),
            userCode: userCode,
            clientName: request.clientName ?? "Strato CLI",
            scopes: scopes,
            requestIP: req.trustedClientIP,
            expiresAt: Date().addingTimeInterval(Self.deviceCodeLifetime),
            interval: Self.pollInterval
        )
        try await authorization.save(on: req.db)

        let origin = Self.publicOrigin()
        return DeviceAuthorizationResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: "\(origin)/activate",
            verificationUriComplete: "\(origin)/activate?code=\(userCode)",
            expiresIn: Int(Self.deviceCodeLifetime),
            interval: Self.pollInterval
        )
    }

    /// The browser-facing origin for the verification URL. The frontend is a
    /// separate service, so this comes from configuration, not the request.
    static func publicOrigin() -> String {
        let origin =
            Environment.get("STRATO_PUBLIC_URL")
            ?? Environment.get("WEBAUTHN_RELYING_PARTY_ORIGIN")
            ?? "http://localhost:3000"
        return origin.hasSuffix("/") ? String(origin.dropLast()) : origin
    }

    struct TokenRequest: Content {
        let grantType: String
        let deviceCode: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case deviceCode = "device_code"
            case refreshToken = "refresh_token"
        }
    }

    static let deviceCodeGrantType = "urn:ietf:params:oauth:grant-type:device_code"

    func token(req: Request) async throws -> TokenResponse {
        guard let request = try? req.content.decode(TokenRequest.self) else {
            throw OAuthError.invalidRequest("Malformed token request")
        }

        switch request.grantType {
        case Self.deviceCodeGrantType:
            guard let deviceCode = request.deviceCode else {
                throw OAuthError.invalidRequest("device_code is required")
            }
            return try await redeemDeviceCode(deviceCode, req: req)
        case "refresh_token":
            guard let refreshToken = request.refreshToken else {
                throw OAuthError.invalidRequest("refresh_token is required")
            }
            return try await refreshSession(refreshToken, req: req)
        default:
            throw OAuthError.unsupportedGrantType
        }
    }

    private func redeemDeviceCode(_ deviceCode: String, req: Request) async throws -> TokenResponse {
        guard let authorization = try await DeviceAuthorization.findByDeviceCode(deviceCode, on: req.db) else {
            throw OAuthError.invalidGrant("Unknown device code")
        }

        if authorization.isExpired {
            throw OAuthError.expiredToken
        }

        // RFC 8628 §3.5: clients polling faster than `interval` get slow_down.
        let now = Date()
        if let lastPolled = authorization.lastPolledAt,
            now.timeIntervalSince(lastPolled) < Double(authorization.interval)
        {
            authorization.lastPolledAt = now
            try await authorization.save(on: req.db)
            throw OAuthError.slowDown
        }
        authorization.lastPolledAt = now

        switch DeviceAuthorization.Status(rawValue: authorization.status) {
        case .pending:
            try await authorization.save(on: req.db)
            throw OAuthError.authorizationPending
        case .denied:
            try await authorization.save(on: req.db)
            throw OAuthError.accessDenied
        case .redeemed, .none:
            try await authorization.save(on: req.db)
            throw OAuthError.invalidGrant("Device code already used")
        case .approved:
            break
        }

        guard let userID = authorization.$user.id else {
            throw OAuthError.invalidGrant("Approval is missing a user")
        }
        let authorizationID = try authorization.requireID()

        let accessToken = CLISession.generateAccessToken()
        let refreshToken = CLISession.generateRefreshToken()
        let session = CLISession(
            userID: userID,
            clientName: authorization.clientName,
            scopes: authorization.scopes,
            accessTokenHash: CLISession.hashToken(accessToken),
            accessTokenPrefix: String(accessToken.prefix(12)) + "...",
            accessTokenExpiresAt: Date().addingTimeInterval(CLISession.accessTokenLifetime),
            refreshTokenHash: CLISession.hashToken(refreshToken),
            refreshTokenExpiresAt: Date().addingTimeInterval(CLISession.refreshTokenLifetime)
        )

        // Single redemption: consume the approval and create the session in
        // one transaction, guarded against a concurrent poll racing us — the
        // status check above was unguarded, so re-verify with a conditional
        // UPDATE (same consume pattern as the account-claim flow). 0 rows
        // means the other poll won and this one must not mint a session.
        try await req.db.transaction { db in
            guard let sql = db as? SQLDatabase else {
                throw Abort(.internalServerError, reason: "Unsupported database")
            }
            let consumed = try await sql.raw(
                """
                UPDATE oauth_device_authorizations
                SET status = \(bind: DeviceAuthorization.Status.redeemed.rawValue)
                WHERE id = \(bind: authorizationID) AND status = \(bind: DeviceAuthorization.Status.approved.rawValue)
                RETURNING id
                """
            ).all()
            guard !consumed.isEmpty else {
                throw OAuthError.invalidGrant("Device code already used")
            }
            try await session.save(on: db)
        }

        return TokenResponse(
            accessToken: accessToken,
            tokenType: "Bearer",
            expiresIn: Int(CLISession.accessTokenLifetime),
            refreshToken: refreshToken,
            scope: session.scopes.joined(separator: " ")
        )
    }

    private func refreshSession(_ refreshToken: String, req: Request) async throws -> TokenResponse {
        let hash = CLISession.hashToken(refreshToken)

        if let session = try await CLISession.query(on: req.db)
            .filter(\.$refreshTokenHash == hash)
            .first()
        {
            guard !session.isRevoked, !session.isRefreshTokenExpired else {
                throw OAuthError.invalidGrant("Session revoked or expired")
            }

            let (newAccessToken, newRefreshToken) = session.rotate()
            try await session.save(on: req.db)

            return TokenResponse(
                accessToken: newAccessToken,
                tokenType: "Bearer",
                expiresIn: Int(CLISession.accessTokenLifetime),
                refreshToken: newRefreshToken,
                scope: session.scopes.joined(separator: " ")
            )
        }

        // Replay of an already-rotated refresh token means the credential
        // leaked (or the client lost the rotation response); either way the
        // session can no longer be trusted.
        if let replayed = try await CLISession.query(on: req.db)
            .filter(\.$previousRefreshTokenHash == hash)
            .first(), !replayed.isRevoked
        {
            req.logger.warning(
                "Refresh token replay detected; revoking CLI session",
                metadata: ["session_id": .string(replayed.id?.uuidString ?? "unknown")]
            )
            replayed.revokedAt = Date()
            try await replayed.save(on: req.db)
        }

        throw OAuthError.invalidGrant("Invalid refresh token")
    }

    struct RevokeRequest: Content {
        let token: String
    }

    /// RFC 7009: revoke by access or refresh token. Always 200, even for
    /// unknown tokens, so callers can't probe which tokens exist.
    func revoke(req: Request) async throws -> HTTPStatus {
        guard let request = try? req.content.decode(RevokeRequest.self) else {
            return .ok
        }

        let hash = CLISession.hashToken(request.token)
        let session = try await CLISession.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$accessTokenHash == hash)
                group.filter(\.$refreshTokenHash == hash)
            }
            .first()

        if let session, !session.isRevoked {
            session.revokedAt = Date()
            try await session.save(on: req.db)
        }

        return .ok
    }

    // MARK: - Session-authenticated approval endpoints

    private func pendingAuthorization(req: Request) async throws -> DeviceAuthorization {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }
        guard let rawCode = req.parameters.get("userCode") else {
            throw Abort(.badRequest, reason: "Missing user code")
        }

        let userCode = DeviceAuthorization.normalizeUserCode(rawCode)
        guard
            let authorization = try await DeviceAuthorization.query(on: req.db)
                .filter(\.$userCode == userCode)
                .filter(\.$status == DeviceAuthorization.Status.pending.rawValue)
                .first(),
            !authorization.isExpired
        else {
            throw Abort(.notFound, reason: "Unknown or expired code")
        }

        return authorization
    }

    func pendingDevice(req: Request) async throws -> PendingDeviceAuthorizationResponse {
        let authorization = try await pendingAuthorization(req: req)
        return PendingDeviceAuthorizationResponse(
            userCode: authorization.userCode,
            clientName: authorization.clientName,
            scopes: authorization.scopes,
            requestIP: authorization.requestIP,
            createdAt: authorization.createdAt,
            expiresAt: authorization.expiresAt
        )
    }

    func approveDevice(req: Request) async throws -> HTTPStatus {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        let authorization = try await pendingAuthorization(req: req)
        authorization.status = DeviceAuthorization.Status.approved.rawValue
        authorization.$user.id = try user.requireID()
        try await authorization.save(on: req.db)
        return .ok
    }

    func denyDevice(req: Request) async throws -> HTTPStatus {
        let authorization = try await pendingAuthorization(req: req)
        authorization.status = DeviceAuthorization.Status.denied.rawValue
        try await authorization.save(on: req.db)
        return .ok
    }

    // MARK: - Session management (Settings)

    func listSessions(req: Request) async throws -> [CLISessionResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let sessions = try await CLISession.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .filter(\.$revokedAt == nil)
            .filter(\.$refreshTokenExpiresAt > Date())
            .sort(\.$createdAt, .descending)
            .all()

        return sessions.map { CLISessionResponse(from: $0) }
    }

    func revokeSession(req: Request) async throws -> HTTPStatus {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard let sessionID = req.parameters.get("sessionID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid session ID")
        }

        guard
            let session = try await CLISession.query(on: req.db)
                .filter(\.$id == sessionID)
                .filter(\.$user.$id == user.requireID())
                .first()
        else {
            throw Abort(.notFound)
        }

        session.revokedAt = Date()
        try await session.save(on: req.db)
        return .noContent
    }
}

// MARK: - OAuth error responses

/// RFC 6749 §5.2 / RFC 8628 §3.5 error codes, rendered as HTTP 400 with a
/// `{error, error_description}` JSON body (not Vapor's `{reason}` shape).
enum OAuthError: Error, AsyncResponseEncodable {
    case invalidRequest(String)
    case invalidGrant(String)
    case invalidScope(String)
    case unsupportedGrantType
    case authorizationPending
    case slowDown
    case accessDenied
    case expiredToken

    var status: HTTPResponseStatus { .badRequest }

    var code: String {
        switch self {
        case .invalidRequest: return "invalid_request"
        case .invalidGrant: return "invalid_grant"
        case .invalidScope: return "invalid_scope"
        case .unsupportedGrantType: return "unsupported_grant_type"
        case .authorizationPending: return "authorization_pending"
        case .slowDown: return "slow_down"
        case .accessDenied: return "access_denied"
        case .expiredToken: return "expired_token"
        }
    }

    var reason: String {
        switch self {
        case .invalidRequest(let detail), .invalidGrant(let detail), .invalidScope(let detail):
            return detail
        case .unsupportedGrantType:
            return "Unsupported grant type"
        case .authorizationPending:
            return "Authorization request is still pending"
        case .slowDown:
            return "Polling too frequently"
        case .accessDenied:
            return "The user denied the request"
        case .expiredToken:
            return "The device code has expired"
        }
    }

    func encodeResponse(for request: Request) async throws -> Response {
        let body = OAuthErrorResponse(error: code, errorDescription: reason)
        let response = Response(status: status)
        try response.content.encode(body, as: .json)
        return response
    }
}
