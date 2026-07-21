import Fluent
import Foundation
import Vapor
import WebAuthn

/// Self-service passkey management for the signed-in user (`/api/users/me/passkeys`).
///
/// Enrolling an additional passkey is an account-takeover-grade operation, so
/// every route here is deliberately narrow:
///
/// - The acting user is always `req.auth`'s user; there is no `:userID` to
///   target someone else's credentials, and admins have no route in here.
/// - Mutations require a *session* (a passkey/OIDC login in a browser). An API
///   key or CLI token authenticates as the user but must not be able to attach
///   a new authenticator or drop an existing one — that would turn a leaked
///   read/write key into permanent account access.
/// - The add ceremony uses its own challenge namespace (`add_passkey`), so a
///   challenge issued here cannot be redeemed through the public
///   `/auth/register/finish` (which logs in whoever the challenge belongs to)
///   and vice versa.
struct PasskeyController: RouteCollection {
    /// Challenge namespace for the authenticated add-a-passkey ceremony.
    static let addChallengeOperation = "add_passkey"

    /// Upper bound on passkeys per account. Keeps `excludeCredentials` (sent to
    /// the authenticator on every enrollment) and the allow-list at login from
    /// growing without limit.
    static let maxPasskeysPerUser = 20

    func boot(routes: RoutesBuilder) throws {
        let passkeys = routes.grouped("api", "users", "me", "passkeys")
        passkeys.get(use: index)
        passkeys.post("begin", use: addBegin)
        passkeys.post("finish", use: addFinish)
        passkeys.group(":credentialID") { credential in
            credential.patch(use: rename)
            credential.delete(use: delete)
        }
    }

    // MARK: - List

    func index(req: Request) async throws -> [PasskeyResponse] {
        let user = try currentUser(req)
        let credentials = try await UserCredential.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .sort(\.$createdAt, .ascending)
            .all()
        return credentials.map(PasskeyResponse.init(from:))
    }

    // MARK: - Add

    func addBegin(req: Request) async throws -> RegistrationBeginResponse {
        let user = try currentUser(req)
        try requireSessionAuth(req)
        try rejectDisabledAccount(user)

        try await user.$credentials.load(on: req.db)
        guard user.credentials.count < Self.maxPasskeysPerUser else {
            throw Abort(
                .conflict,
                reason: "You already have the maximum of \(Self.maxPasskeysPerUser) passkeys"
            )
        }

        // Registered credentials are excluded so an authenticator that already
        // holds a passkey for this account reports it instead of silently
        // enrolling a duplicate.
        let excludeCredentials = user.credentials.map { credential in
            PublicKeyCredentialDescriptor(
                type: .publicKey,
                id: Array(credential.credentialID),
                transports: credential.transports.compactMap {
                    PublicKeyCredentialDescriptor.AuthenticatorTransport(rawValue: $0)
                }
            )
        }

        let options = try await req.webAuthn.beginRegistration(
            for: user,
            excludeCredentials: excludeCredentials
        )
        try await req.webAuthn.storeChallenge(
            options.challenge.base64URLEncodedString().asString(),
            for: user.id,
            operation: Self.addChallengeOperation,
            on: req.db
        )
        return RegistrationBeginResponse(options: options)
    }

    func addFinish(req: Request) async throws -> PasskeyResponse {
        let user = try currentUser(req)
        try requireSessionAuth(req)
        try rejectDisabledAccount(user)

        let body = try req.content.decode(AddPasskeyFinishRequest.self)
        let userID = try user.requireID()

        // The challenge carries the account it was issued for. Confirm it is
        // this session's account *before* the credential is persisted, so a
        // challenge captured from another user's ceremony can't be redeemed
        // here (and so this route can never enroll onto a different account).
        guard
            let challengeRecord = try await AuthenticationChallenge.query(on: req.db)
                .filter(\.$challenge == body.challenge)
                .filter(\.$operation == Self.addChallengeOperation)
                .first(),
            challengeRecord.userID == userID
        else {
            throw Abort(.badRequest, reason: "This passkey request does not belong to your account")
        }

        let credential = try await req.webAuthn.finishRegistration(
            challenge: body.challenge,
            credentialCreationData: body.response,
            operation: Self.addChallengeOperation,
            on: req.db
        )

        // Defense in depth: finishRegistration derives the user from the
        // challenge row independently of the check above.
        guard credential.$user.id == userID else {
            try? await credential.delete(on: req.db)
            throw Abort(.badRequest, reason: "This passkey request does not belong to your account")
        }

        if let name = try Self.validatedName(body.name) {
            credential.name = name
            try await credential.save(on: req.db)
        }

        await req.recordAuthEvent(
            .passkeyAdded, user: user,
            metadata: ["credentialId": try credential.requireID().uuidString])

        return PasskeyResponse(from: credential)
    }

    // MARK: - Rename

    func rename(req: Request) async throws -> PasskeyResponse {
        let user = try currentUser(req)
        try requireSessionAuth(req)

        let credential = try await findOwnedCredential(req, user: user)
        let body = try req.content.decode(RenamePasskeyRequest.self)
        credential.name = try Self.validatedName(body.name)
        try await credential.save(on: req.db)

        return PasskeyResponse(from: credential)
    }

    // MARK: - Delete

    func delete(req: Request) async throws -> HTTPStatus {
        let user = try currentUser(req)
        try requireSessionAuth(req)

        let credential = try await findOwnedCredential(req, user: user)

        // Never let a user lock themselves out. Passkeys are the only local
        // sign-in method, so the last one may only be removed by an account
        // that can still authenticate another way (a linked OIDC provider).
        let remaining =
            try await UserCredential.query(on: req.db)
            .filter(\.$user.$id == user.requireID())
            .count() - 1
        if remaining <= 0 && !user.isOIDCAuthenticated {
            throw Abort(
                .conflict,
                reason: "This is your only passkey — add another before removing it"
            )
        }

        let credentialID = try credential.requireID()
        try await credential.delete(on: req.db)
        await req.recordAuthEvent(
            .passkeyRemoved, user: user, metadata: ["credentialId": credentialID.uuidString])

        return .noContent
    }

    // MARK: - Helpers

    private func currentUser(_ req: Request) throws -> User {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        return user
    }

    /// Rejects non-session credentials for state-changing passkey operations.
    private func requireSessionAuth(_ req: Request) throws {
        guard !req.isAPIKeyAuthenticated, req.cliSession == nil else {
            throw Abort(
                .forbidden,
                reason: "Passkeys can only be managed from a signed-in browser session"
            )
        }
    }

    private func findOwnedCredential(_ req: Request, user: User) async throws -> UserCredential {
        guard let credentialID = req.parameters.get("credentialID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid passkey ID")
        }
        // Scoped by owner, so another user's passkey is indistinguishable from
        // one that doesn't exist.
        guard
            let credential = try await UserCredential.query(on: req.db)
                .filter(\.$id == credentialID)
                .filter(\.$user.$id == user.requireID())
                .first()
        else {
            throw Abort(.notFound, reason: "Passkey not found")
        }
        return credential
    }

    /// Trims a user-supplied label; an empty/whitespace name clears it back to
    /// the client-rendered default rather than storing a blank string.
    static func validatedName(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.count <= 64 else {
            throw Abort(.badRequest, reason: "Passkey name must be 64 characters or fewer")
        }
        return trimmed
    }
}

// MARK: - DTOs

struct PasskeyResponse: Content {
    let id: UUID?
    let name: String?
    let deviceType: String
    let transports: [String]
    /// True when the authenticator syncs the credential to a cloud keychain
    /// (a "multi-device" passkey), which the UI surfaces as "synced".
    let backedUp: Bool
    let createdAt: Date?
    let lastUsedAt: Date?

    init(from credential: UserCredential) {
        self.id = credential.id
        self.name = credential.name
        self.deviceType = credential.deviceType
        self.transports = credential.transports
        self.backedUp = credential.backupState
        self.createdAt = credential.createdAt
        self.lastUsedAt = credential.lastUsedAt
    }
}

struct RenamePasskeyRequest: Content {
    let name: String?
}

/// Finish payload for the authenticated add ceremony. Mirrors
/// `RegistrationFinishRequest` (decode-only — `RegistrationCredential` is not
/// `Encodable`) plus an optional label for the new passkey.
struct AddPasskeyFinishRequest: Content {
    let challenge: String
    let response: RegistrationCredential
    let name: String?

    func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(
            response,
            EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "AddPasskeyFinishRequest should only be decoded, not encoded"))
    }

    private enum CodingKeys: String, CodingKey {
        case challenge, response, name
    }
}
