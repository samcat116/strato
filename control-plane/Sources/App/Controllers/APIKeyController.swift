import Foundation
import Vapor
import Fluent

struct APIKeyController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let apiKeys = routes.grouped("api-keys")
        apiKeys.get(use: index)
        apiKeys.post(use: create)
        
        apiKeys.group(":apiKeyID") { apiKey in
            apiKey.get(use: show)
            apiKey.patch(use: update)
            apiKey.delete(use: delete)
        }
    }
    
    // MARK: - API Key CRUD
    
    func index(req: Request) async throws -> [APIKeyResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        let apiKeys = try await APIKey.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .sort(\.$createdAt, .descending)
            .all()
        
        return apiKeys.map { APIKeyResponse(from: $0) }
    }
    
    func show(req: Request) async throws -> APIKeyResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        guard let apiKeyID = req.parameters.get("apiKeyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid API key ID")
        }
        
        guard let apiKey = try await APIKey.query(on: req.db)
            .filter(\.$id == apiKeyID)
            .filter(\.$user.$id == user.id!)
            .first() else {
            throw Abort(.notFound)
        }
        
        return APIKeyResponse(from: apiKey)
    }
    
    func create(req: Request) async throws -> CreateAPIKeyResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        let createRequest = try req.content.decode(CreateAPIKeyRequest.self)
        
        // Validate scopes
        let validScopes = ["read", "write", "admin"]
        let requestedScopes = createRequest.scopes ?? ["read", "write"]
        
        for scope in requestedScopes {
            guard validScopes.contains(scope) else {
                throw Abort(.badRequest, reason: "Invalid scope: \(scope)")
            }
        }
        
        // Check API key limit per user (max 10)
        let existingKeysCount = try await APIKey.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .count()
        
        if existingKeysCount >= 10 {
            throw Abort(.badRequest, reason: "Maximum API key limit reached (10 keys per user)")
        }
        
        // Generate the API key
        let fullKey = APIKey.generateAPIKey()
        let keyHash = APIKey.hashAPIKey(fullKey)
        let keyPrefix = String(fullKey.prefix(12)) + "..." // Show first 12 chars
        
        // Calculate expiration date
        var expiresAt: Date?
        if let expiresInDays = createRequest.expiresInDays {
            guard expiresInDays > 0 && expiresInDays <= 365 else {
                throw Abort(.badRequest, reason: "Expiration must be between 1 and 365 days")
            }
            expiresAt = Calendar.current.date(byAdding: .day, value: expiresInDays, to: Date())
        }
        
        // Create the API key
        let apiKey = APIKey(
            userID: user.id!,
            name: createRequest.name,
            keyHash: keyHash,
            keyPrefix: keyPrefix,
            scopes: requestedScopes,
            expiresAt: expiresAt
        )
        
        try await apiKey.save(on: req.db)
        
        return CreateAPIKeyResponse(apiKey: apiKey, fullKey: fullKey)
    }
    
    func update(req: Request) async throws -> APIKeyResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        guard let apiKeyID = req.parameters.get("apiKeyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid API key ID")
        }
        
        guard let apiKey = try await APIKey.query(on: req.db)
            .filter(\.$id == apiKeyID)
            .filter(\.$user.$id == user.id!)
            .first() else {
            throw Abort(.notFound)
        }
        
        let updateRequest = try req.content.decode(UpdateAPIKeyRequest.self)
        
        // Update fields
        if let name = updateRequest.name {
            apiKey.name = name
        }
        
        if let scopes = updateRequest.scopes {
            let validScopes = ["read", "write", "admin"]
            for scope in scopes {
                guard validScopes.contains(scope) else {
                    throw Abort(.badRequest, reason: "Invalid scope: \(scope)")
                }
            }
            apiKey.scopes = scopes
        }
        
        if let isActive = updateRequest.isActive {
            apiKey.isActive = isActive
        }
        
        try await apiKey.save(on: req.db)
        
        return APIKeyResponse(from: apiKey)
    }
    
    func delete(req: Request) async throws -> HTTPStatus {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        
        guard let apiKeyID = req.parameters.get("apiKeyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid API key ID")
        }
        
        guard let apiKey = try await APIKey.query(on: req.db)
            .filter(\.$id == apiKeyID)
            .filter(\.$user.$id == user.id!)
            .first() else {
            throw Abort(.notFound)
        }
        
        try await apiKey.delete(on: req.db)
        
        return .noContent
    }
}

// MARK: - API Documentation Endpoint

struct APIDocumentationController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("api", "docs", use: documentation)
    }
    
    func documentation(req: Request) async throws -> Response {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Strato API Documentation</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 40px; }
                .endpoint { margin: 20px 0; padding: 15px; border: 1px solid #ddd; border-radius: 8px; }
                .method { font-weight: bold; color: #2563eb; }
                .path { font-family: monospace; background: #f3f4f6; padding: 2px 6px; border-radius: 4px; }
                code { background: #f3f4f6; padding: 2px 6px; border-radius: 4px; }
                .auth-header { background: #fef3c7; padding: 10px; border-radius: 4px; margin: 20px 0; }
            </style>
        </head>
        <body>
            <h1>Strato API Documentation</h1>
            
            <div class="auth-header">
                <strong>Authentication:</strong> Include your API key in the Authorization header:<br>
                <code>Authorization: Bearer sk_your_api_key_here</code>
            </div>
            
            <h2>API Key Management</h2>
            
            <div class="endpoint">
                <div><span class="method">GET</span> <span class="path">/api-keys</span></div>
                <p>List all API keys for the authenticated user</p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">POST</span> <span class="path">/api-keys</span></div>
                <p>Create a new API key</p>
                <p><strong>Body:</strong> <code>{"name": "My API Key", "scopes": ["read", "write"], "expiresInDays": 30}</code></p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">PATCH</span> <span class="path">/api-keys/{id}</span></div>
                <p>Update an API key</p>
                <p><strong>Body:</strong> <code>{"name": "Updated Name", "isActive": false}</code></p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">DELETE</span> <span class="path">/api-keys/{id}</span></div>
                <p>Delete an API key</p>
            </div>
            
            <h2>Organizations</h2>
            
            <div class="endpoint">
                <div><span class="method">GET</span> <span class="path">/organizations</span></div>
                <p>List organizations for the authenticated user</p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">POST</span> <span class="path">/organizations</span></div>
                <p>Create a new organization</p>
                <p><strong>Body:</strong> <code>{"name": "My Org", "description": "Organization description"}</code></p>
            </div>
            
            <h2>Virtual Machines</h2>
            
            <div class="endpoint">
                <div><span class="method">GET</span> <span class="path">/vms</span></div>
                <p>List VMs in the current organization</p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">POST</span> <span class="path">/vms</span></div>
                <p>Create a new VM</p>
                <p><strong>Body:</strong> <code>{"name": "my-vm", "description": "My VM", "image": "ubuntu:latest", "cpu": 2, "memory": 1024, "disk": 20}</code></p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">POST</span> <span class="path">/vms/{id}/start</span></div>
                <p>Start a VM</p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">POST</span> <span class="path">/vms/{id}/stop</span></div>
                <p>Stop a VM</p>
            </div>
            
            <div class="endpoint">
                <div><span class="method">POST</span> <span class="path">/vms/{id}/restart</span></div>
                <p>Restart a VM</p>
            </div>
            
            <h2>Scopes</h2>
            <ul>
                <li><strong>read:</strong> Read access to resources</li>
                <li><strong>write:</strong> Create, update, and delete resources</li>
                <li><strong>admin:</strong> Full administrative access</li>
            </ul>
        </body>
        </html>
        """
        
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }
}