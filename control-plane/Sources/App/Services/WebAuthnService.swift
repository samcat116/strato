import Foundation
import Vapor
import WebAuthn
import Fluent

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

    func beginRegistration(
        for user: User,
        excludeCredentials: [PublicKeyCredentialDescriptor] = []
    ) async throws -> PublicKeyCredentialCreationOptions {
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

        // Find the user by challenge
        guard let authChallenge = try await AuthenticationChallenge.query(on: database)
            .filter(\.$challenge == challenge)
            .filter(\.$operation == "registration")
            .first(),
              let userID = authChallenge.userID else {
            throw WebAuthnError.challengeNotFound
        }

        // Create user credential - store the actual binary credential ID, not the string
        let credentialIDData = URLEncodedBase64(credential.id).urlDecoded.decoded ?? Data()

        let userCredential = UserCredential(
            userID: userID,
            credentialID: credentialIDData,
            publicKey: Data(credential.publicKey),
            signCount: Int32(credential.signCount),
            transports: [],
            backupEligible: credential.backupEligible,
            backupState: credential.isBackedUp,
            deviceType: "platform"
        )

        try await userCredential.save(on: database)

        // Clean up challenge
        try await authChallenge.delete(on: database)

        return userCredential
    }

    // MARK: - Authentication

    func beginAuthentication(
        for username: String? = nil,
        on database: Database
    ) async throws -> PublicKeyCredentialRequestOptions {
        var allowCredentials: [PublicKeyCredentialDescriptor] = []

        if let username = username {
            // Get user's credentials
            guard let user = try await User.query(on: database)
                .filter(\.$username == username)
                .first() else {
                throw WebAuthnError.userNotFound
            }

            try await user.$credentials.load(on: database)
            allowCredentials = user.credentials.map { credential in
                PublicKeyCredentialDescriptor(
                    type: .publicKey,
                    id: Array(credential.credentialID),
                    transports: credential.transports.compactMap { transport in
                        PublicKeyCredentialDescriptor.AuthenticatorTransport(rawValue: transport)
                    }
                )
            }
        }

        let options = webAuthnManager.beginAuthentication(
            allowCredentials: allowCredentials
        )

        return options
    }

    func finishAuthentication(
        challenge: String,
        authenticationCredential: AuthenticationCredential,
        on database: Database
    ) async throws -> User {
        let credentialID = authenticationCredential.id.urlDecoded.decoded ?? Data()

        guard let credential = try await UserCredential.query(on: database)
            .filter(\.$credentialID == credentialID)
            .with(\.$user)
            .first() else {
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

        // Update sign count
        credential.signCount = Int32(verification.newSignCount)
        credential.lastUsedAt = Date()
        try await credential.save(on: database)

        // Clean up challenge
        if let authChallenge = try await AuthenticationChallenge.query(on: database)
            .filter(\.$challenge == challenge)
            .filter(\.$operation == "authentication")
            .first() {
            try await authChallenge.delete(on: database)
        }

        return credential.user
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

    func cleanupExpiredChallenges(on database: Database) async throws {
        try await AuthenticationChallenge.query(on: database)
            .filter(\.$expiresAt < Date())
            .delete()
    }
}

// MARK: - Errors

enum WebAuthnError: Error, AbortError {
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

    var webAuthn: WebAuthnService {
        get {
            guard let service = self.storage[WebAuthnServiceKey.self] else {
                fatalError("WebAuthnService not configured. Call app.webAuthn.initialize() in configure.swift")
            }
            return service
        }
        set {
            self.storage[WebAuthnServiceKey.self] = newValue
        }
    }

    func configureWebAuthn(
        relyingPartyID: String,
        relyingPartyName: String,
        relyingPartyOrigin: String
    ) {
        self.webAuthn = WebAuthnService(
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: relyingPartyOrigin
        )
    }
}

extension Request {
    var webAuthn: WebAuthnService {
        return self.application.webAuthn
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
