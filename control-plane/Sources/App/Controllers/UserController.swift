import Foundation
import Vapor
import Fluent
import SQLKit
import WebAuthn

struct UserController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let users = routes.grouped("api", "users")
        users.post("register", use: register)
        users.post(use: create)
        users.get(use: index)
        users.group(":userID") { user in
            user.get(use: show)
            user.put(use: update)
            user.delete(use: delete)
        }

        // Authentication routes
        let auth = routes.grouped("auth")
        auth.post("register", "begin", use: beginRegistration)
        auth.post("register", "finish", use: finishRegistration)
        auth.post("login", "begin", use: beginAuthentication)
        auth.post("login", "finish", use: finishAuthentication)
        auth.post("logout", use: logout)
        auth.get("session", use: getSession)

        // Passkey-claim flow for admin-created (invited) accounts. Public: gated
        // by a one-time claim token rather than a session.
        auth.get("claim", ":token", use: claimInfo)
        auth.post("claim", "begin", use: claimBegin)
        auth.post("claim", "finish", use: claimFinish)
    }

    // MARK: - User CRUD

    func index(req: Request) async throws -> [User.Public] {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Only system admins may enumerate all users
        guard currentUser.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
        }

        let users = try await User.query(on: req.db).all()
        return users.map { $0.asPublic() }
    }

    func show(req: Request) async throws -> User.Public {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        // Users may only view themselves unless they are a system admin
        guard currentUser.isSystemAdmin || currentUser.id == userID else {
            throw Abort(.forbidden, reason: "You may only access your own account")
        }

        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound)
        }

        return user.asPublic()
    }

    func register(req: Request) async throws -> User.Public {
        let createUser = try req.content.decode(CreateUserRequest.self)

        // Check if username or email already exists
        let existingUser = try await User.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$username == createUser.username)
                group.filter(\.$email == createUser.email)
            }
            .first()

        if existingUser != nil {
            throw Abort(.conflict, reason: "Username or email already exists")
        }

        // Check if this is the first user (should be system admin)
        let isFirstUser = try await User.isFirstUser(on: req.db)

        let user = User(
            username: createUser.username,
            email: createUser.email,
            displayName: createUser.displayName,
            isSystemAdmin: isFirstUser
        )

        try await user.save(on: req.db)
        return user.asPublic()
    }

    /// Admin-only: create a `.local` user with no credential and mint a one-time
    /// passkey-claim token. Passkeys are device-bound, so the invitee finishes
    /// enrollment themselves via the returned claim link (`/auth/claim/*`).
    func create(req: Request) async throws -> AdminCreateUserResponse {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard currentUser.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
        }

        let body = try req.content.decode(AdminCreateUserRequest.self)
        let username = body.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = body.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !email.isEmpty, !displayName.isEmpty else {
            throw Abort(.badRequest, reason: "username, email and displayName are required")
        }

        let isSystemAdmin = body.isSystemAdmin ?? false
        let createdByID = currentUser.id
        let rawToken = AccountClaimToken.generateToken()

        // Optional org assignment: provisioning the invitee into an org up front
        // keeps them admin-managed (they don't land on self-onboarding with no
        // memberships). Only "admin"/"member" match the SpiceDB org relations.
        let assignedOrgID = body.organizationId
        let requestedRole = body.role?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignedRole = (requestedRole?.isEmpty == false ? requestedRole! : "member")
        if assignedOrgID != nil {
            guard assignedRole == "admin" || assignedRole == "member" else {
                throw Abort(.badRequest, reason: "role must be 'admin' or 'member'")
            }
        }

        // Fetched here (throwing getter) so the org-membership tuple can be
        // written inside the transaction below; only needed when assigning.
        let spicedb: SpiceDBServiceProtocol? = assignedOrgID != nil ? try req.spicedb : nil

        // Create the user, its claim token, and any org membership in one
        // transaction so the token row is visible the instant the user row is.
        // Otherwise a concurrent /auth/register/begin — which blocks invited
        // accounts by counting claim tokens — could slip through the gap
        // between commits and let someone attach their own passkey.
        let (user, claim) = try await req.db.transaction { db -> (User, AccountClaimToken) in
            let existingUser = try await User.query(on: db)
                .group(.or) { group in
                    group.filter(\.$username == username)
                    group.filter(\.$email == email)
                }
                .first()
            if existingUser != nil {
                throw Abort(.conflict, reason: "Username or email already exists")
            }

            if let orgID = assignedOrgID {
                guard try await Organization.find(orgID, on: db) != nil else {
                    throw Abort(.badRequest, reason: "Assigned organization not found")
                }
            }

            let user = User(
                username: username,
                email: email,
                displayName: displayName,
                isSystemAdmin: isSystemAdmin,
                source: .local
            )
            // Seed the current org so the invitee lands in it on claim rather
            // than on the self-onboarding path.
            user.currentOrganizationId = assignedOrgID
            try await user.save(on: db)

            let claim = AccountClaimToken(
                userID: try user.requireID(),
                tokenHash: AccountClaimToken.hashToken(rawToken),
                tokenPrefix: AccountClaimToken.extractPrefix(rawToken),
                expiresAt: Date().addingTimeInterval(Self.claimTokenTTL),
                createdByID: createdByID
            )
            try await claim.save(on: db)

            if let orgID = assignedOrgID {
                let membership = UserOrganization(
                    userID: try user.requireID(),
                    organizationID: orgID,
                    role: assignedRole
                )
                try await membership.save(on: db)

                // Authorization reads org access from SpiceDB (e.g. VM
                // collection checks need view_organization), and missing tuples
                // are only reconciled by a boot-time backfill. Write the tuple
                // inside the transaction so a failure rolls the whole create
                // back — better to fail and let the admin retry than to hand
                // out a claim link for a member who can't use the org.
                if let spicedb {
                    try await spicedb.setOrganizationRole(
                        userID: try user.requireID().uuidString,
                        organizationID: orgID.uuidString,
                        oldRole: nil,
                        newRole: assignedRole
                    )
                }
            }
            return (user, claim)
        }

        return AdminCreateUserResponse(
            user: user.asPublic(),
            claimToken: rawToken,
            claimUrl: Self.claimURL(for: rawToken),
            claimExpiresAt: claim.expiresAt
        )
    }

    func update(req: Request) async throws -> User.Public {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        // Users may only update themselves unless they are a system admin
        guard currentUser.isSystemAdmin || currentUser.id == userID else {
            throw Abort(.forbidden, reason: "You may only modify your own account")
        }

        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound)
        }

        let updateUser = try req.content.decode(UpdateUserRequest.self)
        user.displayName = updateUser.displayName ?? user.displayName
        user.email = updateUser.email ?? user.email

        try await user.save(on: req.db)
        return user.asPublic()
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        // Users may only delete themselves unless they are a system admin
        guard currentUser.isSystemAdmin || currentUser.id == userID else {
            throw Abort(.forbidden, reason: "You may only delete your own account")
        }

        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound)
        }

        try await user.delete(on: req.db)
        return .noContent
    }

    // MARK: - WebAuthn Registration

    func beginRegistration(req: Request) async throws -> RegistrationBeginResponse {
        let beginRequest = try req.content.decode(RegistrationBeginRequest.self)

        // Check if user exists
        guard
            let user = try await User.query(on: req.db)
                .filter(\.$username == beginRequest.username)
                .first()
        else {
            throw Abort(.notFound, reason: "User not found")
        }

        // Admin-created accounts must enroll their passkey through the claim
        // invite flow (/auth/claim/*), which is gated by a one-time token.
        // Refuse to attach a credential to such an account through the open
        // self-registration endpoint — otherwise anyone knowing the username
        // could hijack a not-yet-activated invited account.
        let hasClaimToken =
            try await AccountClaimToken.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .count() > 0
        if hasClaimToken {
            throw Abort(.forbidden, reason: "This account must be activated using its invitation link")
        }

        // Get existing credentials to exclude
        try await user.$credentials.load(on: req.db)
        let excludeCredentials = user.credentials.map { credential in
            PublicKeyCredentialDescriptor(
                type: .publicKey,
                id: Array(credential.credentialID),
                transports: credential.transports.compactMap { transport in
                    PublicKeyCredentialDescriptor.AuthenticatorTransport(rawValue: transport)
                }
            )
        }

        let options = try await req.webAuthn.beginRegistration(
            for: user,
            excludeCredentials: excludeCredentials
        )

        // Store challenge
        try await req.webAuthn.storeChallenge(
            options.challenge.base64URLEncodedString().asString(),
            for: user.id,
            operation: "registration",
            on: req.db
        )

        return RegistrationBeginResponse(options: options)
    }

    func finishRegistration(req: Request) async throws -> RegistrationFinishResponse {
        let finishRequest = try req.content.decode(RegistrationFinishRequest.self)

        // Reject disabled accounts before finishRegistration persists the new
        // credential (and consumes the challenge) — a user disabled by an SSF
        // signal must not be able to add passkeys.
        if let challengeRecord = try await AuthenticationChallenge.query(on: req.db)
            .filter(\.$challenge == finishRequest.challenge)
            .first(),
            let challengeUserID = challengeRecord.userID,
            let challengeUser = try await User.find(challengeUserID, on: req.db)
        {
            try rejectDisabledAccount(challengeUser)
        }

        let credential = try await req.webAuthn.finishRegistration(
            challenge: finishRequest.challenge,
            credentialCreationData: finishRequest.response,
            on: req.db
        )

        // Load the user for this credential
        try await credential.$user.load(on: req.db)
        let user = credential.user

        // Accounts disabled by an SSF signal must not get a session; the
        // middleware only sees authenticated requests, so check here too.
        try rejectDisabledAccount(user)

        // Create session - log the user in automatically
        req.auth.login(user)
        req.stampSessionEpoch(for: user)
        await req.recordAuthEvent(.register, user: user)

        // If this is a system admin (first user), skip default organization setup
        // They'll create their organization through the onboarding flow
        if !user.isSystemAdmin {
            // Ensure user belongs to default organization
            do {
                try await ensureUserInDefaultOrganization(user: user, req: req)
            } catch {
                req.logger.warning("Failed to create organization membership for user \(user.username): \(error)")
                // Don't fail the registration if SpiceDB relationship creation fails
            }
        }

        return RegistrationFinishResponse(
            credentialID: credential.credentialID.base64EncodedString(),
            success: true,
            user: user.asPublic()
        )
    }

    // MARK: - Passkey Claim (admin-created accounts)

    /// Public: describe a claim token so the claim page can greet the invitee.
    /// Returns 404 for an unknown token; a known-but-unusable token is reported
    /// via the `valid`/`expired`/`alreadyClaimed` flags rather than an error.
    func claimInfo(req: Request) async throws -> ClaimInfoResponse {
        guard let token = req.parameters.get("token") else {
            throw Abort(.badRequest, reason: "Missing token")
        }
        guard let claim = try await AccountClaimToken.findByToken(token, on: req.db) else {
            throw Abort(.notFound, reason: "Invalid claim token")
        }

        return ClaimInfoResponse(
            username: claim.user.username,
            displayName: claim.user.displayName,
            valid: claim.isValid,
            alreadyClaimed: claim.claimedAt != nil,
            expired: claim.isExpired
        )
    }

    /// Public: begin the passkey ceremony for an invited account, authorized by
    /// the claim token instead of a session.
    func claimBegin(req: Request) async throws -> RegistrationBeginResponse {
        let beginRequest = try req.content.decode(ClaimBeginRequest.self)

        guard let claim = try await AccountClaimToken.findByToken(beginRequest.token, on: req.db) else {
            throw Abort(.notFound, reason: "Invalid claim token")
        }
        guard claim.isValid else {
            throw Abort(.gone, reason: "This invitation link has expired or was already used")
        }

        let user = claim.user
        try rejectDisabledAccount(user)

        try await user.$credentials.load(on: req.db)
        let excludeCredentials = user.credentials.map { credential in
            PublicKeyCredentialDescriptor(
                type: .publicKey,
                id: Array(credential.credentialID),
                transports: credential.transports.compactMap { transport in
                    PublicKeyCredentialDescriptor.AuthenticatorTransport(rawValue: transport)
                }
            )
        }

        let options = try await req.webAuthn.beginRegistration(
            for: user,
            excludeCredentials: excludeCredentials
        )

        // Store under a distinct operation so this invite-authorized challenge
        // can only be redeemed via /auth/claim/finish — never replayed through
        // the open /auth/register/finish path, which would skip the token check.
        try await req.webAuthn.storeChallenge(
            options.challenge.base64URLEncodedString().asString(),
            for: user.id,
            operation: Self.claimChallengeOperation,
            on: req.db
        )

        return RegistrationBeginResponse(options: options)
    }

    /// Public: finish the passkey ceremony for an invited account, consume the
    /// claim token, and log the user in.
    func claimFinish(req: Request) async throws -> RegistrationFinishResponse {
        let finishRequest = try req.content.decode(ClaimFinishRequest.self)

        guard let claim = try await AccountClaimToken.findByToken(finishRequest.token, on: req.db) else {
            throw Abort(.notFound, reason: "Invalid claim token")
        }
        guard claim.isValid else {
            throw Abort(.gone, reason: "This invitation link has expired or was already used")
        }

        // Block accounts disabled by an SSF signal before the challenge is
        // consumed and a credential persisted.
        try rejectDisabledAccount(claim.user)

        let tokenUserID = claim.$user.id
        let claimID = try claim.requireID()

        // The WebAuthn challenge carries its own target user, independent of the
        // token. Confirm they match BEFORE finishRegistration persists a
        // credential — otherwise a valid token for one account could attach a
        // passkey to a different account whose challenge was captured earlier.
        guard
            let challengeRecord = try await AuthenticationChallenge.query(on: req.db)
                .filter(\.$challenge == finishRequest.challenge)
                .filter(\.$operation == Self.claimChallengeOperation)
                .first(),
            challengeRecord.userID == tokenUserID
        else {
            throw Abort(.badRequest, reason: "Claim token does not match this registration")
        }

        // Enforce the WebAuthn challenge TTL before consuming the invite, so an
        // expired ceremony surfaces a clear error and leaves the (still-valid)
        // claim token usable. finishRegistration re-checks expiry as the
        // authoritative gate.
        if let expiresAt = challengeRecord.expiresAt, expiresAt <= Date() {
            throw Abort(.gone, reason: "This passkey request has expired — please restart setup")
        }

        // Consume the one-time token and enroll the credential in a single
        // transaction. The conditional update matches only while `claimed_at`
        // is still null, so two holders of the same invite finishing
        // concurrently can't both enroll — exactly one wins; the loser gets
        // 410. Wrapping both in a transaction means a failed enrollment (bad
        // response, challenge expired in the race window, credential
        // insert/delete error) rolls the consume back, leaving the invite
        // usable for a retry instead of stranding the account.
        let webAuthn = try req.webAuthn
        let challenge = finishRequest.challenge
        let response = finishRequest.response
        let operation = Self.claimChallengeOperation
        let credential = try await req.db.transaction { db -> UserCredential in
            guard let sql = db as? SQLDatabase else {
                throw Abort(.internalServerError, reason: "Unsupported database")
            }
            let consumed = try await sql.raw(
                """
                UPDATE account_claim_tokens SET claimed_at = \(bind: Date())
                WHERE id = \(bind: claimID) AND claimed_at IS NULL
                RETURNING id
                """
            ).all()
            guard !consumed.isEmpty else {
                throw Abort(.gone, reason: "This invitation link has expired or was already used")
            }

            let credential = try await webAuthn.finishRegistration(
                challenge: challenge,
                credentialCreationData: response,
                operation: operation,
                on: db
            )

            // Defense in depth: finishRegistration derives the user from the
            // challenge; a mismatch rolls the whole transaction back (no
            // credential, token un-consumed).
            guard credential.$user.id == tokenUserID else {
                throw Abort(.badRequest, reason: "Claim token does not match this registration")
            }
            return credential
        }

        try await credential.$user.load(on: req.db)
        let user = credential.user
        try rejectDisabledAccount(user)

        req.auth.login(user)
        req.stampSessionEpoch(for: user)
        await req.recordAuthEvent(.register, user: user)

        // Admin-created accounts are org-managed by the admin (via the member
        // UI), so — unlike self-registration — do NOT auto-join the default
        // org. If the admin already placed them in an org, make one current so
        // they land somewhere usable; never grant new membership here.
        if user.currentOrganizationId == nil,
            let membership = try await UserOrganization.query(on: req.db)
                .filter(\.$user.$id == user.requireID())
                .first()
        {
            user.currentOrganizationId = membership.$organization.id
            try await user.save(on: req.db)
        }

        return RegistrationFinishResponse(
            credentialID: credential.credentialID.base64EncodedString(),
            success: true,
            user: user.asPublic()
        )
    }

    // MARK: - WebAuthn Authentication

    func beginAuthentication(req: Request) async throws -> AuthenticationBeginResponse {
        let beginRequest = try req.content.decode(AuthenticationBeginRequest.self)

        let options = try await req.webAuthn.beginAuthentication(
            for: beginRequest.username,
            on: req.db
        )

        // Store challenge
        try await req.webAuthn.storeChallenge(
            options.challenge.base64URLEncodedString().asString(),
            operation: "authentication",
            on: req.db
        )

        return AuthenticationBeginResponse(options: options)
    }

    func finishAuthentication(req: Request) async throws -> AuthenticationFinishResponse {
        let finishRequest = try req.content.decode(AuthenticationFinishRequest.self)

        let user: User
        do {
            user = try await req.webAuthn.finishAuthentication(
                challenge: finishRequest.challenge,
                authenticationCredential: finishRequest.response,
                on: req.db
            )
        } catch {
            await req.recordAuthEvent(.loginFailed, metadata: ["error": "\(error)"])
            throw error
        }

        // Accounts disabled by an SSF signal must not get a session; the
        // middleware only sees authenticated requests, so check here too.
        if user.disabledAt != nil {
            await req.recordAuthEvent(
                .loginFailed, metadata: ["error": "account disabled", "username": user.username])
        }
        try rejectDisabledAccount(user)

        // Create session
        req.auth.login(user)
        req.stampSessionEpoch(for: user)
        await req.recordAuthEvent(.login, user: user)

        // Store in SpiceDB relationships if needed
        // Ensure user belongs to default organization (skip for system admins)
        if !user.isSystemAdmin {
            do {
                try await ensureUserInDefaultOrganization(user: user, req: req)
            } catch {
                req.logger.warning("Failed to create organization membership for user \(user.username): \(error)")
                // Don't fail the login if SpiceDB relationship creation fails
            }
        }

        return AuthenticationFinishResponse(
            user: user.asPublic(),
            success: true
        )
    }

    // MARK: - Session Management

    func logout(req: Request) async throws -> LogoutResponse {
        let user = req.auth.get(User.self)

        // RP-initiated logout (OIDC): when this session was established via an
        // OIDC provider that advertises an end_session_endpoint, hand the
        // frontend the IdP's logout URL so it can end the IdP session too —
        // otherwise the next SSO login silently signs straight back in.
        // Computed before the session is destroyed, which drops the stored
        // provider reference and ID token.
        // Best-effort: a failed provider lookup (transient DB error) must not
        // abort logout — leaving the session and its stored ID token alive
        // would be worse than skipping the IdP redirect.
        var sloUrl: String?
        if let providerIDString = req.session.data["oidc_login_provider_id"],
            let providerID = UUID(uuidString: providerIDString),
            let provider = try? await OIDCProvider.find(providerID, on: req.db)
        {
            // post_logout_redirect_uri only works if registered at the IdP;
            // in production an unset BASE_URL means OIDC login never worked,
            // so the failed resolution (nil) can only occur for stale sessions.
            let postLogoutRedirectURI =
                (try? OIDCValidation.resolveBaseURL(
                    configured: Environment.get("BASE_URL"),
                    environment: req.application.environment
                )).map { "\($0)/login" }
            sloUrl = provider.getEndSessionURL(
                idTokenHint: req.session.data["oidc_login_id_token"],
                postLogoutRedirectURI: postLogoutRedirectURI
            )
        }

        req.auth.logout(User.self)
        // Destroy the whole session, not just the auth entry: it still holds
        // the OIDC ID token and provider reference, which must not outlive
        // the login they belong to.
        req.session.destroy()
        if let user {
            await req.recordAuthEvent(.logout, user: user)
        }
        return LogoutResponse(sloUrl: sloUrl)
    }

    func getSession(req: Request) async throws -> SessionResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        return SessionResponse(user: user.asPublic())
    }
}

// MARK: - DTOs

/// Logout result. `sloUrl` is the IdP's RP-initiated logout URL when the
/// session was OIDC-established and the provider supports it; the frontend
/// should navigate there to end the IdP session as well.
struct LogoutResponse: Content {
    let sloUrl: String?
}

struct CreateUserRequest: Content {
    let username: String
    let email: String
    let displayName: String
}

struct UpdateUserRequest: Content {
    let displayName: String?
    let email: String?
}

struct AdminCreateUserRequest: Content {
    let username: String
    let email: String
    let displayName: String
    let isSystemAdmin: Bool?
    /// Optional org to provision the invitee into up front. Without it the
    /// account is created unassigned and the admin manages membership later.
    let organizationId: UUID?
    /// Org role for `organizationId` — "admin" or "member" (defaults to member).
    let role: String?

    init(
        username: String,
        email: String,
        displayName: String,
        isSystemAdmin: Bool?,
        organizationId: UUID? = nil,
        role: String? = nil
    ) {
        self.username = username
        self.email = email
        self.displayName = displayName
        self.isSystemAdmin = isSystemAdmin
        self.organizationId = organizationId
        self.role = role
    }
}

/// Returned once when an admin creates a user. `claimToken` / `claimUrl` are
/// shown a single time so the admin can hand the invite to the new user.
struct AdminCreateUserResponse: Content {
    let user: User.Public
    let claimToken: String
    let claimUrl: String
    let claimExpiresAt: Date?
}

struct ClaimInfoResponse: Content {
    let username: String
    let displayName: String
    let valid: Bool
    let alreadyClaimed: Bool
    let expired: Bool
}

struct ClaimBeginRequest: Content {
    let token: String
}

struct ClaimFinishRequest: Content {
    let token: String
    let challenge: String
    let response: RegistrationCredential

    func encode(to encoder: Encoder) throws {
        // Decode-only, mirroring RegistrationFinishRequest: RegistrationCredential
        // is Decodable but not Encodable.
        throw EncodingError.invalidValue(
            response,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "ClaimFinishRequest should only be decoded, not encoded"))
    }

    private enum CodingKeys: String, CodingKey {
        case token, challenge, response
    }
}

struct RegistrationBeginRequest: Content {
    let username: String
}

struct RegistrationBeginResponse: Content {
    let options: PublicKeyCredentialCreationOptions

    init(options: PublicKeyCredentialCreationOptions) {
        self.options = options
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [], debugDescription: "RegistrationBeginResponse should only be encoded, not decoded"))
    }
}

struct RegistrationFinishRequest: Content {
    let challenge: String
    let response: RegistrationCredential

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(challenge, forKey: .challenge)
        // RegistrationCredential is already Decodable but not Encodable
        // For our purposes, we only need to decode it from the client
        throw EncodingError.invalidValue(
            response,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "RegistrationFinishRequest should only be decoded, not encoded"))
    }

    private enum CodingKeys: String, CodingKey {
        case challenge, response
    }
}

struct RegistrationFinishResponse: Content {
    let credentialID: String
    let success: Bool
    let user: User.Public?
}

struct AuthenticationBeginRequest: Content {
    let username: String?
}

struct AuthenticationBeginResponse: Content {
    let options: PublicKeyCredentialRequestOptions

    init(options: PublicKeyCredentialRequestOptions) {
        self.options = options
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [], debugDescription: "AuthenticationBeginResponse should only be encoded, not decoded"))
    }
}

struct AuthenticationFinishRequest: Content {
    let challenge: String
    let response: AuthenticationCredential

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(challenge, forKey: .challenge)
        // AuthenticationCredential is already Decodable but not Encodable
        // For our purposes, we only need to decode it from the client
        throw EncodingError.invalidValue(
            response,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "AuthenticationFinishRequest should only be decoded, not encoded"))
    }

    private enum CodingKeys: String, CodingKey {
        case challenge, response
    }
}

struct AuthenticationFinishResponse: Content {
    let user: User.Public
    let success: Bool
}

struct SessionResponse: Content {
    let user: User.Public
}

// MARK: - User Extensions

// MARK: - Helper Functions

extension UserController {
    /// How long a passkey-claim invite stays valid (7 days).
    static let claimTokenTTL: TimeInterval = 7 * 24 * 60 * 60

    /// Challenge namespace for the passkey-claim ceremony. Kept distinct from
    /// "registration" so a claim challenge can't be redeemed via the open
    /// self-registration finish endpoint, bypassing the one-time claim token.
    static let claimChallengeOperation = "claim"

    /// Build the user-facing claim URL from the canonical browser origin. This
    /// mirrors the WebAuthn relying-party origin (which must match the browser
    /// URL), so the `/claim` page and the passkey ceremony share an origin. The
    /// frontend may still rebuild the link from `window.location.origin`.
    static func claimURL(for token: String) -> String {
        let base = (Environment.get("WEBAUTHN_RELYING_PARTY_ORIGIN") ?? "http://localhost:8080")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/claim?token=\(token)"
    }

    private func ensureUserInDefaultOrganization(user: User, req: Request) async throws {
        // Find or create default organization
        let defaultOrg = try await findOrCreateDefaultOrganization(req: req)

        // Check if user is already in the organization
        let existingMembership = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == defaultOrg.id!)
            .first()

        if existingMembership == nil {
            // Add user to default organization as member
            let membership = UserOrganization(
                userID: user.id!,
                organizationID: defaultOrg.id!,
                role: "member"
            )
            try await membership.save(on: req.db)

            // Create SpiceDB relationship
            try await req.spicedb.writeRelationship(
                entity: "organization",
                entityId: defaultOrg.id?.uuidString ?? "",
                relation: "member",
                subject: "user",
                subjectId: user.id?.uuidString ?? ""
            )
        }

        // Set as current organization if user doesn't have one
        if user.currentOrganizationId == nil {
            user.currentOrganizationId = defaultOrg.id
            try await user.save(on: req.db)
        }
    }

    private func findOrCreateDefaultOrganization(req: Request) async throws -> Organization {
        // Try to find existing default organization
        if let existingOrg = try await Organization.query(on: req.db)
            .filter(\.$name == "Default Organization")
            .first()
        {
            return existingOrg
        }

        // Create default organization if it doesn't exist
        let defaultOrg = Organization(
            name: "Default Organization",
            description: "Default organization for all users"
        )
        try await defaultOrg.save(on: req.db)

        return defaultOrg
    }
}

extension User {
    struct Public: Content {
        let id: UUID?
        let username: String
        let email: String
        let displayName: String
        let createdAt: Date?
        let currentOrganizationId: UUID?
        let isSystemAdmin: Bool
        let source: UserSource
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            username: self.username,
            email: self.email,
            displayName: self.displayName,
            createdAt: self.createdAt,
            currentOrganizationId: self.currentOrganizationId,
            isSystemAdmin: self.isSystemAdmin,
            source: self.source
        )
    }
}
