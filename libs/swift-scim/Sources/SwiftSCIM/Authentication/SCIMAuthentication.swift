import Foundation

/// Protocol for SCIM authentication providers
public protocol SCIMAuthenticationProvider: Sendable {
    /// Apply authentication to a URL request
    func authenticate(request: inout URLRequest) async throws
    
    /// Check if authentication is valid
    var isValid: Bool { get async }
    
    /// Refresh authentication if possible
    func refresh() async throws
}

/// Bearer token authentication provider
public actor BearerTokenAuthenticationProvider: SCIMAuthenticationProvider {
    private var token: String
    private let refreshToken: String?
    private let refreshHandler: ((String?) async throws -> String)?
    
    public init(
        token: String,
        refreshToken: String? = nil,
        refreshHandler: ((String?) async throws -> String)? = nil
    ) {
        self.token = token
        self.refreshToken = refreshToken
        self.refreshHandler = refreshHandler
    }
    
    public func authenticate(request: inout URLRequest) async throws {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    
    public var isValid: Bool {
        return !token.isEmpty
    }
    
    public func refresh() async throws {
        guard let refreshHandler = refreshHandler else {
            throw SCIMClientError.authenticationFailed
        }
        
        token = try await refreshHandler(refreshToken)
    }
    
    public func updateToken(_ newToken: String) {
        token = newToken
    }
}

/// OAuth 2.0 authentication provider
public actor OAuth2AuthenticationProvider: SCIMAuthenticationProvider {
    private var accessToken: String
    private let refreshToken: String?
    private let clientId: String
    private let clientSecret: String?
    private let tokenEndpoint: URL
    private let httpClient: URLSession
    
    public init(
        accessToken: String,
        refreshToken: String? = nil,
        clientId: String,
        clientSecret: String? = nil,
        tokenEndpoint: URL,
        httpClient: URLSession = .shared
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.tokenEndpoint = tokenEndpoint
        self.httpClient = httpClient
    }
    
    public func authenticate(request: inout URLRequest) async throws {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    
    public var isValid: Bool {
        return !accessToken.isEmpty
    }
    
    public func refresh() async throws {
        guard let refreshToken = refreshToken else {
            throw SCIMClientError.authenticationFailed
        }
        
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var bodyComponents = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(clientId)"
        ]
        
        if let clientSecret = clientSecret {
            bodyComponents.append("client_secret=\(clientSecret)")
        }
        
        request.httpBody = bodyComponents.joined(separator: "&").data(using: .utf8)
        
        do {
            let (data, response) = try await httpClient.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw SCIMClientError.authenticationFailed
            }
            
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = tokenResponse.accessToken
            
        } catch {
            throw SCIMClientError.authenticationFailed
        }
    }
}

/// Custom authentication provider for other authentication schemes
public struct CustomAuthenticationProvider: SCIMAuthenticationProvider {
    private let authenticateHandler: @Sendable (inout URLRequest) async throws -> Void
    private let isValidHandler: @Sendable () async -> Bool
    private let refreshHandler: @Sendable () async throws -> Void
    
    public init(
        authenticate: @escaping @Sendable (inout URLRequest) async throws -> Void,
        isValid: @escaping @Sendable () async -> Bool = { true },
        refresh: @escaping @Sendable () async throws -> Void = { }
    ) {
        self.authenticateHandler = authenticate
        self.isValidHandler = isValid
        self.refreshHandler = refresh
    }
    
    public func authenticate(request: inout URLRequest) async throws {
        try await authenticateHandler(&request)
    }
    
    public var isValid: Bool {
        get async {
            await isValidHandler()
        }
    }
    
    public func refresh() async throws {
        try await refreshHandler()
    }
}

/// OAuth 2.0 token response
private struct TokenResponse: Codable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}