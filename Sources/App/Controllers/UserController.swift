import Foundation
import Vapor
import Fluent
import WebAuthn

struct UserController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let users = routes.grouped("users")
        users.post("register", use: register)
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
    }
    
    // MARK: - User CRUD
    
    func index(req: Request) async throws -> [User.Public] {
        let users = try await User.query(on: req.db).all()
        return users.map { $0.asPublic() }
    }
    
    func show(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
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
        
        let user = User(
            username: createUser.username,
            email: createUser.email,
            displayName: createUser.displayName
        )
        
        try await user.save(on: req.db)
        return user.asPublic()
    }
    
    func update(req: Request) async throws -> User.Public {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
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
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
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
        guard let user = try await User.query(on: req.db)
            .filter(\.$username == beginRequest.username)
            .first() else {
            throw Abort(.notFound, reason: "User not found")
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
        
        let credential = try await req.webAuthn.finishRegistration(
            challenge: finishRequest.challenge,
            credentialCreationData: finishRequest.response,
            on: req.db
        )
        
        return RegistrationFinishResponse(
            credentialID: credential.credentialID.base64EncodedString(),
            success: true
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
        
        let user = try await req.webAuthn.finishAuthentication(
            challenge: finishRequest.challenge,
            authenticationCredential: finishRequest.response,
            on: req.db
        )
        
        // Create session
        req.auth.login(user)
        
        // Store in Permify relationships if needed
        // Ensure user belongs to default organization
        do {
            try await ensureUserInDefaultOrganization(user: user, req: req)
        } catch {
            req.logger.warning("Failed to create organization membership for user \(user.username): \(error)")
            // Don't fail the login if Permify relationship creation fails
        }
        
        return AuthenticationFinishResponse(
            user: user.asPublic(),
            success: true
        )
    }
    
    // MARK: - Session Management
    
    func logout(req: Request) async throws -> HTTPStatus {
        req.auth.logout(User.self)
        return .noContent
    }
    
    func getSession(req: Request) async throws -> SessionResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        return SessionResponse(user: user.asPublic())
    }
}

// MARK: - DTOs

struct CreateUserRequest: Content {
    let username: String
    let email: String
    let displayName: String
}

struct UpdateUserRequest: Content {
    let displayName: String?
    let email: String?
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
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "RegistrationBeginResponse should only be encoded, not decoded"))
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
        throw EncodingError.invalidValue(response, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "RegistrationFinishRequest should only be decoded, not encoded"))
    }
    
    private enum CodingKeys: String, CodingKey {
        case challenge, response
    }
}

struct RegistrationFinishResponse: Content {
    let credentialID: String
    let success: Bool
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
        throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "AuthenticationBeginResponse should only be encoded, not decoded"))
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
        throw EncodingError.invalidValue(response, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "AuthenticationFinishRequest should only be decoded, not encoded"))
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
            
            // Create Permify relationship
            try await req.permify.writeRelationship(
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
            .first() {
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
    }
    
    func asPublic() -> Public {
        return Public(
            id: self.id,
            username: self.username,
            email: self.email,
            displayName: self.displayName,
            createdAt: self.createdAt,
            currentOrganizationId: self.currentOrganizationId
        )
    }
}