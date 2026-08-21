import ControlPlanePostgres
import Crypto
import Foundation
import Vapor
import WebAuthn

struct WebAuthnService {
    private let webAuthnManager: WebAuthnManager
    private let passkeys: PasskeysPersistence
    private let users: UserDirectoryPersistence

    init(
        relyingPartyID: String,
        relyingPartyName: String,
        relyingPartyOrigin: String,
        passkeys: PasskeysPersistence,
        users: UserDirectoryPersistence
    ) {
        let config = WebAuthnManager.Configuration(
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: relyingPartyOrigin
        )
        self.webAuthnManager = WebAuthnManager(configuration: config)
        self.passkeys = passkeys
        self.users = users
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
        expectedUserID: UUID? = nil,
        maximumCredentialsPerUser: Int? = nil,
        name: String? = nil,
        rejectPendingAccountClaim: Bool = false
    ) async throws -> PasskeySnapshot {
        // Decode base64url challenge back to bytes
        let challengeBytes = try challenge.base64URLDecodedBytes()

        let credential = try await webAuthnManager.finishRegistration(
            challenge: challengeBytes,
            credentialCreationData: credentialCreationData,
            confirmCredentialIDNotRegisteredYet: { credentialID in
                // During registration, credentialID comes as a string, so convert to binary same way we will during auth
                let credentialIDData = URLEncodedBase64(credentialID).urlDecoded.decoded ?? Data()
                return try await !passkeys.credentialExists(credentialID: credentialIDData)
            }
        )

        // Create user credential - store the actual binary credential ID, not the string
        let credentialIDData = URLEncodedBase64(credential.id).urlDecoded.decoded ?? Data()

        // Transports come from `getTransports()` on the client. They are only
        // hints — we echo them back in `allowCredentials`/`excludeCredentials` so
        // the browser can steer the user to the right authenticator — but they
        // arrive in a request body, so only spec-registered values are kept.
        let passkey = PasskeyWrite(
            credentialID: credentialIDData,
            publicKey: Data(credential.publicKey),
            signCount: Int32(credential.signCount),
            transports: Self.sanitizedTransports(transports),
            backupEligible: credential.backupEligible,
            backupState: credential.isBackedUp,
            deviceType: Self.deviceType(backupEligible: credential.backupEligible),
            name: name
        )
        do {
            return try await passkeys.registerCredential(
                challenge: challenge,
                operation: operation,
                expectedUserID: expectedUserID,
                credential: passkey,
                maximumCredentialsPerUser: maximumCredentialsPerUser,
                rejectPendingAccountClaim: rejectPendingAccountClaim
            )
        } catch {
            throw Self.mapPersistenceError(error)
        }
    }

    func finishClaimRegistration(
        claimID: UUID,
        expectedUserID: UUID,
        challenge: String,
        credentialCreationData: RegistrationCredential,
        transports: [String]? = nil,
        operation: String
    ) async throws -> PasskeySnapshot {
        let challengeBytes = try challenge.base64URLDecodedBytes()
        let credential = try await webAuthnManager.finishRegistration(
            challenge: challengeBytes,
            credentialCreationData: credentialCreationData,
            confirmCredentialIDNotRegisteredYet: { credentialID in
                let data = URLEncodedBase64(credentialID).urlDecoded.decoded ?? Data()
                return try await !passkeys.credentialExists(credentialID: data)
            }
        )
        let write = PasskeyWrite(
            credentialID: URLEncodedBase64(credential.id).urlDecoded.decoded ?? Data(),
            publicKey: Data(credential.publicKey),
            signCount: Int32(credential.signCount),
            transports: Self.sanitizedTransports(transports),
            backupEligible: credential.backupEligible,
            backupState: credential.isBackedUp,
            deviceType: Self.deviceType(backupEligible: credential.backupEligible)
        )
        do {
            return try await passkeys.claimAccountAndRegisterCredential(
                claimID: claimID,
                expectedUserID: expectedUserID,
                challenge: challenge,
                operation: operation,
                credential: write
            )
        } catch {
            throw Self.mapPersistenceError(error)
        }
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
        decoyKey: String
    ) async throws -> PublicKeyCredentialRequestOptions {
        var allowCredentials: [PublicKeyCredentialDescriptor] = []

        if let username = username {
            // Run the same query sequence (user lookup, then an indexed
            // credential lookup — against a fabricated user ID when the user
            // doesn't exist) and compute the decoy HMAC unconditionally, so a
            // nonexistent username is not distinguishable from a registered one
            // by response timing (best-effort; the DB round-trips dominate).
            let user = try await users.user(username: username)
            let userID = user?.id ?? UUID()
            let credentials = try await passkeys.credentials(userID: userID)

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
        authenticationCredential: AuthenticationCredential
    ) async throws -> User {
        // Atomically consume the stored challenge *before* accepting the assertion.
        // This is what provides replay protection: the challenge row must exist, be
        // an unexpired "authentication" challenge issued by us, and be claimed
        // exactly once. A replayed assertion re-using an already-spent challenge
        // finds no row and is rejected here. We cannot rely on the authenticator's
        // signature counter for this because platform passkeys commonly report
        // signCount == 0 on every assertion.
        try await consumeAuthenticationChallenge(challenge)

        let credentialID = authenticationCredential.id.urlDecoded.decoded ?? Data()

        guard let credential = try await passkeys.credential(credentialID: credentialID) else {
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
        // The backed-up flag is the one part of a credential record that
        // legitimately changes after registration: a passkey created on a device
        // can later be synced to a cloud keychain (or stop being synced), and the
        // authenticator reports the current state on every assertion. Refresh it,
        // along with the device type it implies, so the passkey management UI
        // doesn't show a permanently stale "synced" state. Backup *eligibility*
        // is immutable and deliberately left alone.
        guard
            try await passkeys.updateAfterAuthentication(
                id: credential.id,
                update: PasskeyAuthenticationUpdate(
                    signCount: Int32(verification.newSignCount),
                    backupState: verification.credentialBackedUp,
                    deviceType: verification.credentialDeviceType.rawValue,
                    usedAt: Date()
                )
            ) != nil,
            let user = try await users.user(id: credential.userID).map(User.init(snapshot:))
        else {
            throw WebAuthnError.credentialNotFound
        }
        return user
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
        _ challenge: String
    ) async throws {
        do {
            try await passkeys.consumeAuthenticationChallenge(challenge)
        } catch {
            throw Self.mapPersistenceError(error)
        }
    }

    // MARK: - Challenge Management

    func storeChallenge(
        _ challenge: String,
        for userID: UUID? = nil,
        operation: String
    ) async throws {
        _ = try await passkeys.storeChallenge(
            challenge,
            userID: userID,
            operation: operation
        )
    }

    private static func mapPersistenceError(_ error: any Error) -> any Error {
        guard let error = error as? PasskeyPersistenceError else { return error }
        switch error {
        case .challengeNotFound:
            return WebAuthnError.challengeNotFound
        case .challengeOwnerMismatch:
            return WebAuthnError.challengeOwnerMismatch
        case .claimUnavailable:
            return WebAuthnError.claimUnavailable
        case .credentialAlreadyRegistered:
            return WebAuthnError.credentialAlreadyRegistered
        case .credentialLimitReached(let maximum):
            return WebAuthnError.credentialLimitReached(maximum: maximum)
        case .credentialNotFound:
            return WebAuthnError.credentialNotFound
        case .pendingAccountClaim:
            return WebAuthnError.enrollmentRequiresInvitation
        case .userNotFound, .lastCredential, .unexpectedRowCount:
            return error
        }
    }

}

// MARK: - Errors

enum WebAuthnError: Error, AbortError, Sendable {
    case registrationFailed
    case authenticationFailed
    case challengeNotFound
    case challengeOwnerMismatch
    case claimUnavailable
    case credentialAlreadyRegistered
    case credentialLimitReached(maximum: Int)
    case enrollmentRequiresInvitation
    case credentialNotFound
    case userNotFound
    case invalidConfiguration

    var status: HTTPResponseStatus {
        switch self {
        case .credentialNotFound, .userNotFound:
            return .notFound
        case .challengeNotFound, .challengeOwnerMismatch:
            return .badRequest
        case .claimUnavailable:
            return .gone
        case .enrollmentRequiresInvitation:
            return .forbidden
        case .credentialAlreadyRegistered, .credentialLimitReached:
            return .conflict
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
        case .challengeOwnerMismatch:
            return "This passkey request does not belong to your account"
        case .claimUnavailable:
            return "This invitation link has expired or was already used"
        case .credentialAlreadyRegistered:
            return "This passkey is already registered"
        case .credentialLimitReached(let maximum):
            return "You already have the maximum of \(maximum) passkeys"
        case .enrollmentRequiresInvitation:
            return "This account must be activated using its invitation link"
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
        relyingPartyOrigin: String,
        passkeys: PasskeysPersistence,
        users: UserDirectoryPersistence
    ) {
        self.setStorageValue(
            WebAuthnServiceKey.self,
            to: WebAuthnService(
                relyingPartyID: relyingPartyID,
                relyingPartyName: relyingPartyName,
                relyingPartyOrigin: relyingPartyOrigin,
                passkeys: passkeys,
                users: users
            ))
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
