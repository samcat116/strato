import Fluent
import Foundation
import Vapor

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

        guard
            let apiKey = try await APIKey.query(on: req.db)
                .filter(\.$id == apiKeyID)
                .filter(\.$user.$id == user.id!)
                .first()
        else {
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
        let keyPrefix = String(fullKey.prefix(12)) + "..."  // Show first 12 chars

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

        guard
            let apiKey = try await APIKey.query(on: req.db)
                .filter(\.$id == apiKeyID)
                .filter(\.$user.$id == user.id!)
                .first()
        else {
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

        guard
            let apiKey = try await APIKey.query(on: req.db)
                .filter(\.$id == apiKeyID)
                .filter(\.$user.$id == user.id!)
                .first()
        else {
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
                    <meta charset="UTF-8" />
                    <title>Strato API Docs</title>
                    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" />
                </head>
                <body>
                    <div id="swagger-ui"></div>
                    <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js" crossorigin></script>
                    <script>
                        window.ui = SwaggerUIBundle({
                            url: '/openapi.json',
                            dom_id: '#swagger-ui',
                            presets: [SwaggerUIBundle.presets.apis],
                            layout: 'BaseLayout'
                        });
                    </script>
                </body>
            </html>
            """
        return Response(
            status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html))
    }
}
