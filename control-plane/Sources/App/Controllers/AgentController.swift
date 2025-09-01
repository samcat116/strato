import Fluent
import Vapor
import Elementary

struct AgentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agents = routes.grouped("api", "agents")
        
        // Agent registration token endpoints
        let tokenRoutes = agents.grouped("registration-tokens")
        tokenRoutes.post(use: createRegistrationToken)
        tokenRoutes.get(use: listRegistrationTokens)
        tokenRoutes.delete(":tokenId", use: revokeRegistrationToken)
        
        // Agent management endpoints
        agents.get(use: listAgents)
        agents.get(":agentId", use: getAgent)
        agents.delete(":agentId", use: deregisterAgent)
        agents.post(":agentId", "actions", "force-offline", use: forceAgentOffline)
        
        // Web UI endpoint
        let webRoutes = routes.grouped("agents")
        webRoutes.get(use: agentManagementPage)
        
        // HTMX endpoints for agent management page
        let htmx = routes.grouped("htmx")
        let htmxAgents = htmx.grouped("agents")
        htmxAgents.post("registration-tokens", use: createRegistrationTokenHTMX)
        htmxAgents.get("registration-tokens", use: listRegistrationTokensHTMX)
        htmxAgents.get("stats", use: getAgentStatsHTMX)
        htmxAgents.get(use: listAgentsHTMX)
    }
    
    // MARK: - Registration Token Management
    
    func createRegistrationToken(req: Request) async throws -> AgentRegistrationTokenResponse {
        let createRequest = try req.content.decode(CreateAgentRegistrationTokenRequest.self)
        try createRequest.validate()
        
        // Check if agent name is already in use by an existing agent
        let existingAgent = try await Agent.query(on: req.db)
            .filter(\.$name == createRequest.agentName)
            .first()
        
        if existingAgent != nil {
            throw Abort(.conflict, reason: "Agent name '\(createRequest.agentName)' is already registered")
        }
        
        // Check if there's already an unused token for this agent name
        let existingToken = try await AgentRegistrationToken.query(on: req.db)
            .filter(\.$agentName == createRequest.agentName)
            .filter(\.$isUsed == false)
            .first()
        
        if let existing = existingToken, existing.isValid {
            throw Abort(.conflict, reason: "A valid registration token already exists for agent '\(createRequest.agentName)'")
        }
        
        // Create new registration token
        let token = AgentRegistrationToken(
            agentName: createRequest.agentName,
            expirationHours: createRequest.expirationHours ?? 1
        )
        
        try await token.save(on: req.db)
        
        // Get base URL for WebSocket connection
        let scheme = req.url.scheme == "https" ? "wss" : "ws"
        let host = req.headers["host"].first ?? "localhost:8080"
        let baseURL = "\(scheme)://\(host)"
        
        req.logger.info("Created agent registration token", metadata: [
            "agentName": .string(createRequest.agentName),
            "tokenId": .string(token.id?.uuidString ?? "unknown"),
            "expiresAt": .string(token.expiresAt?.description ?? "no expiration")
        ])
        
        return try AgentRegistrationTokenResponse(from: token, baseURL: baseURL)
    }
    
    func listRegistrationTokens(req: Request) async throws -> [AgentRegistrationTokenResponse] {
        let tokens = try await AgentRegistrationToken.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()
        
        let scheme = req.url.scheme == "https" ? "wss" : "ws"
        let host = req.headers["host"].first ?? "localhost:8080"
        let baseURL = "\(scheme)://\(host)"
        
        return try tokens.map { try AgentRegistrationTokenResponse(from: $0, baseURL: baseURL) }
    }
    
    func revokeRegistrationToken(req: Request) async throws -> HTTPStatus {
        guard let tokenId = req.parameters.get("tokenId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid token ID")
        }
        
        guard let token = try await AgentRegistrationToken.find(tokenId, on: req.db) else {
            throw Abort(.notFound, reason: "Registration token not found")
        }
        
        try await token.delete(on: req.db)
        
        req.logger.info("Revoked agent registration token", metadata: [
            "tokenId": .string(tokenId.uuidString),
            "agentName": .string(token.agentName)
        ])
        
        return .noContent
    }
    
    // MARK: - Agent Management
    
    func listAgents(req: Request) async throws -> [AgentResponse] {
        let agents = try await Agent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()
        
        // Update status based on heartbeat before returning
        for agent in agents {
            agent.updateStatusBasedOnHeartbeat()
        }
        
        try await agents.map { $0.save(on: req.db) }.flatten(on: req.eventLoop).get()
        
        return try agents.map { try AgentResponse(from: $0) }
    }
    
    func getAgent(req: Request) async throws -> AgentResponse {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        
        agent.updateStatusBasedOnHeartbeat()
        try await agent.save(on: req.db)
        
        return try AgentResponse(from: agent)
    }
    
    func deregisterAgent(req: Request) async throws -> HTTPStatus {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        
        // Remove from in-memory registry if present
        await req.agentService.forceUnregisterAgent(agent.name)
        
        // Delete from database
        try await agent.delete(on: req.db)
        
        req.logger.info("Deregistered agent", metadata: [
            "agentId": .string(agentId.uuidString),
            "agentName": .string(agent.name)
        ])
        
        return .noContent
    }
    
    func forceAgentOffline(req: Request) async throws -> HTTPStatus {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        
        // Force agent offline in in-memory registry
        await req.agentService.forceUnregisterAgent(agent.name)
        
        // Update database status
        agent.status = .offline
        try await agent.save(on: req.db)
        
        req.logger.info("Forced agent offline", metadata: [
            "agentId": .string(agentId.uuidString),
            "agentName": .string(agent.name)
        ])
        
        return .noContent
    }
    
    // MARK: - Web UI
    
    func agentManagementPage(req: Request) async throws -> Response {
        let html = AgentManagementTemplate().render()
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }
    
    // MARK: - HTMX Endpoints
    
    func createRegistrationTokenHTMX(req: Request) async throws -> Response {
        do {
            let tokenResponse = try await createRegistrationToken(req: req)
            
            let dockerComposeContent = """
version: '3.8'
services:
  strato-agent:
    image: strato/agent:latest
    restart: unless-stopped
    privileged: true
    network_mode: host
    volumes:
      - /dev:/dev
      - /sys:/sys
      - /var/run:/var/run
    environment:
      - REGISTRATION_URL=\(tokenResponse.registrationURL)
    command: ["--registration-url", "\(tokenResponse.registrationURL)"]
"""
            
            let systemdContent = """
[Unit]
Description=Strato Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/strato-agent --registration-url "\(tokenResponse.registrationURL)"
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
"""
            
            let html = div(.class("bg-green-900 border border-green-700 text-green-300 px-6 py-4 rounded-lg")) {
                div(.class("flex items-start space-x-3")) {
                    span(.class("text-2xl")) { "✅" }
                    div(.class("flex-1")) {
                        div(.class("font-medium text-lg")) { "Registration Token Created!" }
                        div(.class("mt-2 text-sm space-y-2")) {
                            div { 
                                strong { "Agent Name: " }
                                span(.class("text-green-100")) { tokenResponse.agentName }
                            }
                            div { 
                                strong { "Expires: " }
                                span(.class("text-green-100")) { tokenResponse.expiresAt.formatted() }
                            }
                        }
                        
                        // Deployment Options Tabs
                        div(.class("mt-4")) {
                            div(.class("border-b border-green-700")) {
                                nav(.class("flex space-x-6")) {
                                    button(.class("py-2 px-1 border-b-2 border-transparent text-green-200 hover:text-green-100 font-medium text-sm tab-button active"),
                                           .data("tab", value: "docker")) {
                                        "🐳 Docker Compose"
                                    }
                                    button(.class("py-2 px-1 border-b-2 border-transparent text-green-200 hover:text-green-100 font-medium text-sm tab-button"),
                                           .data("tab", value: "systemd")) {
                                        "⚙️ systemd"
                                    }
                                    button(.class("py-2 px-1 border-b-2 border-transparent text-green-200 hover:text-green-100 font-medium text-sm tab-button"),
                                           .data("tab", value: "manual")) {
                                        "💻 Manual"
                                    }
                                }
                            }
                            
                            // Docker Compose Tab
                            div(.class("tab-content mt-4"), .id("docker-tab")) {
                                div(.class("text-sm text-green-200 mb-2")) { "Save this as docker-compose.yml and run:" }
                                pre(.class("bg-gray-800 text-gray-100 p-3 rounded text-xs overflow-x-auto mb-3")) {
                                    code { dockerComposeContent }
                                }
                                div(.class("flex space-x-2")) {
                                    button(.class("bg-blue-600 hover:bg-blue-700 text-white px-3 py-1 rounded text-sm copy-button"),
                                           .data("copy-text", value: dockerComposeContent)) {
                                        "📋 Copy docker-compose.yml"
                                    }
                                    button(.class("bg-gray-600 hover:bg-gray-700 text-white px-3 py-1 rounded text-sm copy-button"),
                                           .data("copy-text", value: "docker-compose up -d")) {
                                        "📋 Copy run command"
                                    }
                                }
                            }
                            
                            // systemd Tab
                            div(.class("tab-content mt-4 hidden"), .id("systemd-tab")) {
                                div(.class("text-sm text-green-200 mb-2")) { "Create /etc/systemd/system/strato-agent.service:" }
                                pre(.class("bg-gray-800 text-gray-100 p-3 rounded text-xs overflow-x-auto mb-3")) {
                                    code { systemdContent }
                                }
                                div(.class("flex space-x-2")) {
                                    button(.class("bg-blue-600 hover:bg-blue-700 text-white px-3 py-1 rounded text-sm copy-button"),
                                           .data("copy-text", value: systemdContent)) {
                                        "📋 Copy service file"
                                    }
                                    button(.class("bg-gray-600 hover:bg-gray-700 text-white px-3 py-1 rounded text-sm copy-button"),
                                           .data("copy-text", value: "sudo systemctl enable --now strato-agent")) {
                                        "📋 Copy enable command"
                                    }
                                }
                            }
                            
                            // Manual Tab
                            div(.class("tab-content mt-4 hidden"), .id("manual-tab")) {
                                div(.class("text-sm text-green-200 mb-2")) { "Download and run the agent manually:" }
                                pre(.class("bg-gray-800 text-gray-100 p-3 rounded text-xs overflow-x-auto mb-3")) {
                                    code { "strato-agent --registration-url \"\(tokenResponse.registrationURL)\"" }
                                }
                                button(.class("bg-blue-600 hover:bg-blue-700 text-white px-3 py-1 rounded text-sm copy-button"),
                                       .data("copy-text", value: "strato-agent --registration-url \"\(tokenResponse.registrationURL)\"")) {
                                    "📋 Copy command"
                                }
                            }
                        }
                    }
                }
            }.render()
            
            return Response(
                status: .ok,
                headers: HTTPHeaders([("Content-Type", "text/html")]),
                body: .init(string: html)
            )
            
        } catch {
            let errorHtml = div(.class("bg-red-900 border border-red-700 text-red-300 px-4 py-3 rounded")) {
                div(.class("font-medium")) { "Failed to create registration token" }
                div(.class("text-sm mt-1")) { error.localizedDescription }
            }.render()
            
            return Response(
                status: .badRequest,
                headers: HTTPHeaders([("Content-Type", "text/html")]),
                body: .init(string: errorHtml)
            )
        }
    }
    
    func listAgentsHTMX(req: Request) async throws -> Response {
        let agents = try await listAgents(req: req)
        let template = AgentListTemplate(agents: agents)
        let html = template.render()
        
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }
    
    func listRegistrationTokensHTMX(req: Request) async throws -> Response {
        let tokens = try await listRegistrationTokens(req: req)
        let template = RegistrationTokenListTemplate(tokens: tokens)
        let html = template.render()
        
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }
    
    func getAgentStatsHTMX(req: Request) async throws -> Response {
        let agents = try await Agent.query(on: req.db)
            .all()
        
        // Update status based on heartbeat
        for agent in agents {
            agent.updateStatusBasedOnHeartbeat()
        }
        
        let connectedCount = agents.filter { $0.isOnline }.count
        let totalCount = agents.count
        
        let html = div(.class("space-y-1")) {
            div(.class("flex items-center justify-between p-2 bg-gray-800 rounded text-sm")) {
                span(.class("text-gray-300")) { "Connected Agents" }
                span(.class(connectedCount > 0 ? "text-xs text-green-400" : "text-xs text-gray-500")) { 
                    "\(connectedCount)/\(totalCount)"
                }
            }
            if totalCount > 0 {
                div(.class("flex items-center justify-between p-2 bg-gray-800 rounded text-sm")) {
                    span(.class("text-gray-300")) { "Status" }
                    span(.class(connectedCount == totalCount ? "text-xs text-green-400" : "text-xs text-yellow-400")) { 
                        connectedCount == totalCount ? "All Online" : "Some Offline"
                    }
                }
            }
        }.render()
        
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "text/html")]),
            body: .init(string: html)
        )
    }
}