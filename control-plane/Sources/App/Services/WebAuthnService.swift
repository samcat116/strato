import Crypto
import Foundation
import Vapor
import WebAuthn
import Fluent
import SQLKit

struct WebAuthnService {
    private let webAuthnManager: WebAuthnManager

    init(relyingPartyID: String, relyingPartyName: String, relyingPartyOrigin: String) {
        let config = WebAuthnManager.Configuration(
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: relyingPartyOrigin
        )
        self.webAuthnManager = WebAuthnManager(configuration: config)
    }

    // MARK: - Registration

    /// Builds the creation options for a registration ceremony.
    ///
    /// Note that `excludeCredentials` is *not* produced here: swift-webauthn's
    /// `PublicKeyCredentialCreationOptions` has no such field, so the list is
    /// attached by `RegistrationBeginResponse` when the options are serialized.
    func beginRegistration(for user: User) async throws -> PublicKeyCredentialCreationOptions {
        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User ID is required for WebAuthn registration")
        }
        let userIDBytes = Array(userID.uuidString.utf8)

        let options = webAuthnManager.beginRegistration(
            user: PublicKeyCredentialUserEntity(
                id: userIDBytes,
                name: user.username,
                displayName: user.displayName
            )
        )

        return options
    }

    func finishRegistration(
        challenge: String,
        credentialCreationData: RegistrationCredential,
        transports: [String]? = nil,
        operation: String = "registration",
        on database: Database
    ) async throws -> UserCredential {
        // Decode base64url challenge back to bytes
        let challengeBytes = try challenge.base64URLDecodedBytes()

        let credential = try await webAuthnManager.finishRegistration(
            challenge: challengeBytes,
            credentialCreationData: credentialCreationData,
            confirmCredentialIDNotRegisteredYet: { credentialID in
                // During registration, credentialID comes as a string, so convert to binary same way we will during auth
                let credentialIDData = URLEncodedBase64(credentialID).urlDecoded.decoded ?? Data()
                let existingCredential = try await UserCredential.query(on: database)
                    .filter(\.$credentialID == credentialIDData)
                    .first()
                return existingCredential == nil
            }
        )

        // Find the user by challenge. The operation filter namespaces challenges
        // so, e.g., an invite-authorized "claim" challenge cannot be redeemed
        // through the open "registration" finish path (and vice versa). The
        // expiry filter enforces the stored challenge TTL (mirrors the
        // authentication path) so a response can't be replayed after the
        // server-side challenge has expired.
        let challengeQuery = AuthenticationChallenge.query(on: database)
            .filter(\.$challenge == challenge)
            .filter(\.$operation == operation)
            .group(.or) { group in
                group.filter(\.$expiresAt > Date())
                    .filter(\.$expiresAt == nil)
            }
        guard
            let authChallenge = try await challengeQuery.first(),
            let userID = authChallenge.userID
        else {
            throw WebAuthnError.challengeNotFound
        }

        // Create user credential - store the actual binary credential ID, not the string
        let credentialIDData = URLEncodedBase64(credential.id).urlDecoded.decoded ?? Data()

        // Transports come from `getTransports()` on the client. They are only
        // hints — we echo them back in `allowCredentials`/`excludeCredentials` so
        // the browser can steer the user to the right authenticator — but they
        // arrive in a request body, so only spec-registered values are kept.
        let userCredential = UserCredential(
            userID: userID,
            credentialID: credentialIDData,
            publicKey: Data(credential.publicKey),
            signCount: Int32(credential.signCount),
            transports: Self.sanitizedTransports(transports),
            backupEligible: credential.backupEligible,
            backupState: credential.isBackedUp,
            deviceType: Self.deviceType(backupEligible: credential.backupEligible)
        )

        try await userCredential.save(on: database)

        // Clean up challenge
        try await authChallenge.delete(on: database)

        return userCredential
    }

    /// Transport values registered in the WebAuthn spec, plus `cable` (the
    /// pre-standard name for `hybrid` that older Chrome still reports).
    /// Anything else is dropped rather than stored: these strings are handed
    /// straight back to browsers in later ceremonies.
    static let knownTransports: Set<String> = [
        "usb", "nfc", "ble", "smart-card", "hybrid", "internal", "cable",
    ]

    /// Filters client-reported transports to known values, preserving the
    /// authenticator's ordering and dropping duplicates.
    static func sanitizedTransports(_ reported: [String]?) -> [String] {
        guard let reported else { return [] }
        var seen: Set<String> = []
        return reported.filter { knownTransports.contains($0) && seen.insert($0).inserted }
    }

    /// The credential's device type, which is exactly what the backup-eligible
    /// flag means: an eligible credential is a multi-device (syncable) passkey,
    /// an ineligible one is bound to the authenticator that created it. Matches
    /// the raw values swift-webauthn reports on assertions, so the registration
    /// and login paths agree.
    static func deviceType(backupEligible: Bool) -> String {
        backupEligible
            ? VerifiedAuthentication.CredentialDeviceType.multiDevice.rawValue
            : VerifiedAuthentication.CredentialDeviceType.singleDevice.rawValue
    }

    // MARK: - Authentication

    func beginAuthentication(
        for username: String? = nil,
        decoyKey: String,
        on database: Database
    ) async throws -> PublicKeyCredentialRequestOptions {
        var allowCredentials: [PublicKeyCredentialDescriptor] = []

        if let username = username {
            // Run the same query sequence (user lookup, then an indexed
            // credential lookup — against a fabricated user ID when the user
            // doesn't exist) and compute the decoy HMAC unconditionally, so a
            // nonexistent username is not distinguishable from a registered one
            // by response timing (best-effort; the DB round-trips dominate).
            let user = try await User.query(on: database)
                .filter(\.$username == username)
                .first()
            let userID = try user?.requireID() ?? UUID()
            let credentials = try await UserCredential.query(on: database)
                .filter(\.$user.$id == userID)
                .all()

            allowCredentials = credentials.map { credential in
                PublicKeyCredentialDescriptor(
                    type: .publicKey,
                    id: Array(credential.credentialID),
                    transports: credential.transports.compactMap { transport in
                        PublicKeyCredentialDescriptor.AuthenticatorTransport(rawValue: transport)
                    }
                )
            }

            // No real credentials to return — either the username doesn't
            // exist, or it belongs to a user with no passkeys (e.g. an
            // OIDC/SCIM-provisioned account). Both cases must answer
            // identically: a 404 for unknown usernames is a
            // username-enumeration oracle (the same leak that was closed on
            // the registration path), and an empty list for passkey-less users
            // while unknown usernames get a credential would identify real
            // accounts just as well. Return a single decoy credential so the
            // response is shaped like a real (single-passkey) user's. The
            // decoy id is HMAC(deployment key, username): stable per username
            // (a value that changed between requests would itself reveal the
            // account is fake) and unguessable without the key, so it cannot
            // be told apart from a real credential. A later assertion against
            // the decoy fails exactly like a wrong credential would.
            let decoy = Self.decoyCredential(for: username, key: decoyKey)
            if allowCredentials.isEmpty {
                allowCredentials = [decoy]
            }
        }

        let options = webAuthnManager.beginAuthentication(
            allowCredentials: allowCredentials
        )

        return options
    }

    /// A deterministic, unguessable placeholder credential returned for a
    /// username with no real credentials (nonexistent, or provisioned without
    /// a passkey), so `beginAuthentication` can't be used to tell whether an
    /// account exists. Keyed with a deployment-wide secret and
    /// domain-separated so it can't be derived from, or collide with, anything
    /// else. The 20-byte id is a typical credential-id length, so it looks
    /// ordinary in the response.
    private static func decoyCredential(for username: String, key: String)
        -> PublicKeyCredentialDescriptor
    {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("webauthn-login-decoy:\(username)".utf8),
            using: SymmetricKey(data: Data(key.utf8)))
        return PublicKeyCredentialDescriptor(type: .publicKey, id: Array(mac.prefix(20)), transports: [])
    }

    func finishAuthentication(
        challenge: String,
        authenticationCredential: AuthenticationCredential,
        on database: Database
    ) async throws -> User {
        // Atomically consume the stored challenge *before* accepting the assertion.
        // This is what provides replay protection: the challenge row must exist, be
        // an unexpired "authentication" challenge issued by us, and be claimed
        // exactly once. A replayed assertion re-using an already-spent challenge
        // finds no row and is rejected here. We cannot rely on the authenticator's
        // signature counter for this because platform passkeys commonly report
        // signCount == 0 on every assertion.
        try await consumeAuthenticationChallenge(challenge, on: database)

        let credentialID = authenticationCredential.id.urlDecoded.decoded ?? Data()

        guard
            let credential = try await UserCredential.query(on: database)
                .filter(\.$credentialID == credentialID)
                .with(\.$user)
                .first()
        else {
            throw WebAuthnError.credentialNotFound
        }

        // Decode base64url challenge back to bytes
        let challengeBytes = try challenge.base64URLDecodedBytes()

        let verification = try webAuthnManager.finishAuthentication(
            credential: authenticationCredential,
            expectedChallenge: challengeBytes,
            credentialPublicKey: Array(credential.publicKey),
            credentialCurrentSignCount: UInt32(credential.signCount)
        )

        // Update sign count.
        credential.signCount = Int32(verification.newSignCount)
        // The backed-up flag is the one part of a credential record that
        // legitimately changes after registration: a passkey created on a device
        // can later be synced to a cloud keychain (or stop being synced), and the
        // authenticator reports the current state on every assertion. Refresh it,
        // along with the device type it implies, so the passkey management UI
        // doesn't show a permanently stale "synced" state. Backup *eligibility*
        // is immutable and deliberately left alone.
        credential.backupState = verification.credentialBackedUp
        credential.deviceType = verification.credentialDeviceType.rawValue
        credential.lastUsedAt = Date()
        try await credential.save(on: database)

        return credential.user
    }

    /// Atomically claims a stored authentication challenge, enforcing that it
    /// exists, is for the authentication operation, and has not expired. Throws
    /// `WebAuthnError.challengeNotFound` if no matching, unexpired, unused
    /// challenge is present.
    ///
    /// The claim is performed as a single `DELETE ... RETURNING` so that two
    /// concurrent requests replaying the same challenge cannot both succeed:
    /// the database serializes the deletes and only the first observes a
    /// returned row.
    func consumeAuthenticationChallenge(
        _ challenge: String,
        on database: Database
    ) async throws {
        // Look up the candidate row using Fluent so that the expiry comparison
        // stays portable across database drivers.
        let query = AuthenticationChallenge.query(on: database)
            .filter(\.$challenge == challenge)
            .filter(\.$operation == "authentication")
            .group(.or) { group in
                group.filter(\.$expiresAt > Date())
                    .filter(\.$expiresAt == nil)
            }

        guard let stored = try await query.first(),
            let storedID = stored.id
        else {
            throw WebAuthnError.challengeNotFound
        }

        guard let sql = database as? SQLDatabase else {
            // Non-SQL backends can't perform the atomic RETURNING claim. Fail
            // closed rather than falling back to a racy read-then-delete.
            throw WebAuthnError.invalidConfiguration
        }

        // Atomically remove the row and confirm we were the ones who removed it.
        let claimed = try await sql.raw(
            """
            DELETE FROM authentication_challenges
            WHERE id = \(bind: storedID)
            RETURNING id
            """
        ).first()

        guard claimed != nil else {
            // Another request consumed the same challenge first.
            throw WebAuthnError.challengeNotFound
        }
    }

    // MARK: - Challenge Management

    func storeChallenge(
        _ challenge: String,
        for userID: UUID? = nil,
        operation: String,
        on database: Database
    ) async throws {
        let authChallenge = AuthenticationChallenge(
            challenge: challenge,
            userID: userID,
            operation: operation
        )
        try await authChallenge.save(on: database)
    }

}

// MARK: - Errors

enum WebAuthnError: Error, AbortError, Sendable {
    case registrationFailed
    case authenticationFailed
    case challengeNotFound
    case credentialNotFound
    case userNotFound
    case invalidConfiguration

    var status: HTTPResponseStatus {
        switch self {
        case .credentialNotFound, .userNotFound:
            return .notFound
        case .challengeNotFound:
            return .badRequest
        default:
            return .internalServerError
        }
    }

    var reason: String {
        switch self {
        case .registrationFailed:
            return "Registration failed"
        case .authenticationFailed:
            return "Authentication failed"
        case .challengeNotFound:
            return "Authentication challenge not found or expired"
        case .credentialNotFound:
            return "User/Passkey not found"
        case .userNotFound:
            return "User not found"
        case .invalidConfiguration:
            return "WebAuthn configuration error"
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct WebAuthnServiceKey: StorageKey {
        typealias Value = WebAuthnService
    }

    /// The configured WebAuthn service.
    ///
    /// Throws rather than calling `fatalError` if accessed before
    /// `configureWebAuthn` installed it: this getter is reachable from the
    /// registration and authentication request paths, so a missing service should
    /// surface as a request error rather than crash the process.
    var webAuthn: WebAuthnService {
        get throws {
            guard let service = self.storage[WebAuthnServiceKey.self] else {
                throw Abort(
                    .internalServerError,
                    reason: "WebAuthnService not configured. Call app.configureWebAuthn(...) in configure.swift"
                )
            }
            return service
        }
    }

    func configureWebAuthn(
        relyingPartyID: String,
        relyingPartyName: String,
        relyingPartyOrigin: String
    ) {
        self.storage[WebAuthnServiceKey.self] = WebAuthnService(
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: relyingPartyOrigin
        )
    }
}

extension Request {
    var webAuthn: WebAuthnService {
        get throws { try self.application.webAuthn }
    }
}

// MARK: - Base64URL Decoding Extension

extension String {
    func base64URLDecodedBytes() throws -> [UInt8] {
        // Convert base64url to base64
        var base64 = self.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw WebAuthnError.invalidConfiguration
        }

        return Array(data)
    }
}
