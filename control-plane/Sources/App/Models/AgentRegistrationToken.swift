import Fluent
import Vapor

final class AgentRegistrationToken: Model, Content, @unchecked Sendable {
    static let schema = "agent_registration_tokens"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "token")
    var token: String
    
    @Field(key: "agent_name")
    var agentName: String
    
    @Field(key: "is_used")
    var isUsed: Bool
    
    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "used_at", on: .none)
    var usedAt: Date?
    
    init() { }
    
    init(
        id: UUID? = nil,
        token: String = UUID().uuidString,
        agentName: String,
        expirationHours: Int = 1
    ) {
        self.id = id
        self.token = token
        self.agentName = agentName
        self.isUsed = false
        self.expiresAt = Date().addingTimeInterval(TimeInterval(expirationHours * 3600))
    }
    
    /// Check if the token is valid (not used and not expired)
    var isValid: Bool {
        guard let expires = expiresAt else { return false }
        return !isUsed && expires > Date()
    }
    
    /// Mark the token as used
    func markAsUsed() {
        self.isUsed = true
        self.usedAt = Date()
    }
}

// MARK: - DTO for API responses

struct AgentRegistrationTokenResponse: Content {
    let id: UUID
    let token: String
    let agentName: String
    let registrationURL: String
    let expiresAt: Date
    let isValid: Bool
    
    init(from tokenModel: AgentRegistrationToken, baseURL: String) throws {
        guard let id = tokenModel.id else {
            throw Abort(.internalServerError, reason: "Registration token missing ID")
        }
        
        self.id = id
        self.token = tokenModel.token
        self.agentName = tokenModel.agentName
        guard let encodedName = tokenModel.agentName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw Abort(.internalServerError, reason: "Invalid agent name for URL encoding")
        }
        self.registrationURL = "\(baseURL)/agent/ws?token=\(tokenModel.token)&name=\(encodedName)"
        self.expiresAt = tokenModel.expiresAt ?? Date()
        self.isValid = tokenModel.isValid
    }
}

struct CreateAgentRegistrationTokenRequest: Content {
    let agentName: String
    let expirationHours: Int?
    
    func validate() throws {
        guard !agentName.isEmpty else {
            throw Abort(.badRequest, reason: "Agent name is required")
        }
        
        guard agentName.count <= 100 else {
            throw Abort(.badRequest, reason: "Agent name must be 100 characters or less")
        }
        
        if let hours = expirationHours {
            guard hours > 0 && hours <= 168 else { // Max 1 week
                throw Abort(.badRequest, reason: "Expiration hours must be between 1 and 168 (1 week)")
            }
        }
    }
}