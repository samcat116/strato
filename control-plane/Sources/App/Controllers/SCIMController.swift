import Fluent
import Vapor
import SwiftSCIM

struct SCIMController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // SCIM routes: /organizations/:organizationID/scim/v2/...
        let scim = routes.grouped("organizations", ":organizationID", "scim", "v2")

        // Catch-all route to handle all SCIM endpoints
        scim.on(.GET, "**", use: handleRequest)
        scim.on(.POST, "**", use: handleRequest)
        scim.on(.PUT, "**", use: handleRequest)
        scim.on(.PATCH, "**", use: handleRequest)
        scim.on(.DELETE, "**", use: handleRequest)

        // Root endpoint
        scim.get(use: handleRoot)
    }

    // MARK: - Request Handling

    @Sendable
    func handleRoot(req: Request) async throws -> Response {
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "application/scim+json")]),
            body: .init(string: """
            {
                "schemas": ["urn:ietf:params:scim:api:messages:2.0:ListResponse"],
                "totalResults": 0,
                "Resources": []
            }
            """)
        )
    }

    @Sendable
    func handleRequest(req: Request) async throws -> Response {
        // Extract organization ID
        guard let organizationIDString = req.parameters.get("organizationID"),
              let organizationID = UUID(uuidString: organizationIDString)
        else {
            return scimErrorResponse(status: .badRequest, detail: "Invalid organization ID")
        }

        // Verify organization exists
        guard let _ = try await Organization.find(organizationID, on: req.db) else {
            return scimErrorResponse(status: .notFound, detail: "Organization not found")
        }

        // Authenticate via SCIM token
        guard let authContext = try await authenticateSCIMToken(req: req, organizationID: organizationID) else {
            return scimErrorResponse(status: .unauthorized, detail: "Invalid or missing SCIM token")
        }

        // Build SCIM request
        let scimRequest = try buildSCIMRequest(from: req)

        // Create processor with handlers
        let processor = await createProcessor(
            req: req,
            organizationID: organizationID,
            authContext: authContext
        )

        // Process request
        let scimResponse = await processor.process(scimRequest)

        // Convert to Vapor response
        return vaporResponse(from: scimResponse)
    }

    // MARK: - Authentication

    private func authenticateSCIMToken(req: Request, organizationID: UUID) async throws -> SCIMAuthContext? {
        guard let authHeader = req.headers.bearerAuthorization else {
            return nil
        }

        let token = authHeader.token

        // Verify token starts with scim_ prefix
        guard token.hasPrefix("scim_") else {
            return nil
        }

        // Find and validate token
        guard let scimToken = try await SCIMToken.findByToken(token, on: req.db) else {
            return nil
        }

        // Verify token belongs to this organization
        guard scimToken.$organization.id == organizationID else {
            return nil
        }

        // Check if token is valid
        guard scimToken.isValid else {
            return nil
        }

        // Update last used (best effort, with error logging)
        scimToken.updateLastUsed(ip: req.remoteAddress?.ipAddress)
        do {
            try await scimToken.save(on: req.db)
        } catch {
            req.logger.error("Failed to update SCIM token lastUsed fields: \(error.localizedDescription)")
        }

        return SCIMAuthContext(
            principal: "scim-token:\(scimToken.id?.uuidString ?? "unknown")",
            tenantId: organizationID.uuidString
        )
    }

    // MARK: - Request/Response Conversion

    private func buildSCIMRequest(from req: Request) throws -> SCIMRequest {
        // Extract path after /scim/v2/
        let fullPath = req.url.path
        let scimPath: String

        if let range = fullPath.range(of: "/scim/v2") {
            scimPath = String(fullPath[range.upperBound...])
        } else {
            scimPath = "/"
        }

        // Convert method
        let method: SCIMHTTPMethod
        switch req.method {
        case .GET: method = .GET
        case .POST: method = .POST
        case .PUT: method = .PUT
        case .PATCH: method = .PATCH
        case .DELETE: method = .DELETE
        default: method = .GET
        }

        // Extract query parameters
        var queryParams: [String: String] = [:]
        if let queryString = req.url.query {
            let pairs = queryString.split(separator: "&")
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                    let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                    queryParams[key] = value
                }
            }
        }

        // Extract headers - combine multiple values with comma per RFC 7230
        var headers: [String: String] = [:]
        for (name, value) in req.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        // Get body data
        let bodyData: Data?
        if let buffer = req.body.data {
            bodyData = Data(buffer: buffer)
        } else {
            bodyData = nil
        }

        return SCIMRequest(
            method: method,
            path: scimPath,
            queryParameters: queryParams,
            headers: headers,
            body: bodyData
        )
    }

    private func createProcessor(
        req: Request,
        organizationID: UUID,
        authContext: SCIMAuthContext
    ) async -> SCIMRequestProcessor {
        // Build base URL for this organization's SCIM endpoint
        // Prioritize X-Forwarded-Proto header (set by reverse proxies), then check TLS config, then URL scheme
        let forwardedProto = req.headers.first(name: "X-Forwarded-Proto")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme: String
        if let proto = forwardedProto, !proto.isEmpty {
            scheme = proto
        } else if let urlScheme = req.url.scheme {
            scheme = urlScheme
        } else if req.application.http.server.configuration.tlsConfiguration != nil {
            scheme = "https"
        } else {
            scheme = "http"
        }
        let host = req.headers.first(name: "Host") ?? "localhost:8080"
        let baseURLString = "\(scheme)://\(host)/organizations/\(organizationID.uuidString)/scim/v2"
        let baseURL: URL
        if let parsedURL = URL(string: baseURLString) {
            baseURL = parsedURL
        } else {
            req.logger.warning("Failed to construct valid SCIM base URL from request; falling back to localhost",
                               metadata: [
                                   "scim_base_url_string": .string(baseURLString),
                                   "scim_host_header": .string(host)
                               ])
            baseURL = URL(string: "http://localhost:8080")!
        }

        // Create configuration
        let config = SCIMProcessorConfiguration(
            baseURL: baseURL,
            maxResults: 1000,
            defaultPageSize: 100,
            serviceProviderConfig: serviceProviderConfig(),
            resourceTypes: resourceTypes(),
            schemas: schemas()
        )

        // Create processor with authenticator that validates our auth context
        let authenticator = PreAuthenticatedAuthenticator(context: authContext)
        let processor = SCIMRequestProcessor(configuration: config, authenticator: authenticator)

        // Register handlers
        let userHandler = UserSCIMHandler(
            db: req.db,
            organizationID: organizationID,
            spicedb: req.spicedb
        )
        await processor.register(userHandler)

        let groupHandler = GroupSCIMHandler(
            db: req.db,
            organizationID: organizationID,
            spicedb: req.spicedb
        )
        await processor.register(groupHandler)

        return processor
    }

    private func vaporResponse(from scimResponse: SCIMResponse) -> Response {
        var headers = HTTPHeaders()
        for (name, value) in scimResponse.headers {
            headers.add(name: name, value: value)
        }

        // Ensure SCIM content type
        if headers.first(name: .contentType) == nil {
            headers.add(name: .contentType, value: "application/scim+json")
        }

        let status = HTTPStatus(statusCode: scimResponse.statusCode)

        if let body = scimResponse.body {
            return Response(
                status: status,
                headers: headers,
                body: .init(data: body)
            )
        } else {
            return Response(status: status, headers: headers)
        }
    }

    private func scimErrorResponse(status: HTTPStatus, detail: String, scimType: String? = nil) -> Response {
        let error: [String: Any] = [
            "schemas": ["urn:ietf:params:scim:api:messages:2.0:Error"],
            "detail": detail,
            "status": status.code
        ]

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: error)
        } catch {
            body = Data()
        }

        return Response(
            status: status,
            headers: HTTPHeaders([("Content-Type", "application/scim+json")]),
            body: .init(data: body)
        )
    }

    // MARK: - Service Provider Config

    private func serviceProviderConfig() -> SCIMServiceProviderConfig {
        SCIMServiceProviderConfig(
            patch: SCIMFeatureConfig(supported: true),
            bulk: SCIMBulkConfig(supported: false, maxOperations: 0, maxPayloadSize: 0),
            filter: SCIMFilterConfig(supported: true, maxResults: 1000),
            changePassword: SCIMFeatureConfig(supported: false),
            sort: SCIMFeatureConfig(supported: true),
            etag: SCIMFeatureConfig(supported: true),
            authenticationSchemes: [
                SCIMAuthenticationScheme(
                    type: "oauthbearertoken",
                    name: "OAuth Bearer Token",
                    description: "Authentication using a Bearer token"
                )
            ]
        )
    }

    private func resourceTypes() -> [SCIMResourceType] {
        [
            SCIMResourceType(
                id: "User",
                name: "User",
                endpoint: "/Users",
                description: "User resource type",
                schema: "urn:ietf:params:scim:schemas:core:2.0:User"
            ),
            SCIMResourceType(
                id: "Group",
                name: "Group",
                endpoint: "/Groups",
                description: "Group resource type",
                schema: "urn:ietf:params:scim:schemas:core:2.0:Group"
            )
        ]
    }

    private func schemas() -> [SCIMSchema] {
        // Return minimal schemas - IdPs usually don't need full schema definitions
        []
    }
}

// MARK: - Pre-authenticated Authenticator

/// An authenticator that accepts an already-validated auth context
struct PreAuthenticatedAuthenticator: SCIMServerAuthenticator {
    let context: SCIMAuthContext

    func authenticate(request: SCIMRequest) async throws -> SCIMAuthContext {
        return context
    }
}
