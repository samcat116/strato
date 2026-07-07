import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent

struct AgentWebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agentRoutes = routes.grouped("agent")
        agentRoutes.webSocket("ws", onUpgrade: websocketHandler)
    }

    // Non-async handler - runs on WebSocket's event loop
    private func websocketHandler(req: Request, ws: WebSocket) {
        // Check for SPIFFE/mTLS authentication first
        if let spireService = req.application.spireService {
            Task {
                let isEnabled = await spireService.isEnabled
                if isEnabled {
                    await self.handleMTLSAuthentication(req: req, ws: ws, spireService: spireService)
                } else {
                    self.handleTokenAuthentication(req: req, ws: ws)
                }
            }
            return
        }

        // Fall back to token-based authentication
        handleTokenAuthentication(req: req, ws: ws)
    }

    // MARK: - mTLS Authentication (SPIFFE/SPIRE)

    private func handleMTLSAuthentication(req: Request, ws: WebSocket, spireService: SPIREService) async {
        let requireClientCert = await spireService.requireClientCert

        // The X-Forwarded-Client-Cert (XFCC) header is only trustworthy when the
        // request provably arrived through the pod-local Envoy sidecar. Envoy
        // terminates mTLS, applies SANITIZE_SET (stripping any client-supplied XFCC),
        // injects the verified client identity, and then dials the control plane over
        // loopback (127.0.0.1). A request carrying XFCC from any other peer never
        // passed through Envoy's certificate verification and is a spoofing attempt.
        if req.headers.contains(name: "X-Forwarded-Client-Cert") {
            guard requestArrivedViaLocalSidecar(req) else {
                req.logger.warning(
                    "Rejecting X-Forwarded-Client-Cert from non-loopback peer (possible mTLS spoofing)",
                    metadata: [
                        "remoteAddress": .string(req.remoteAddress?.ipAddress ?? "unknown")
                    ])
                sendErrorResponse(
                    ws: ws, requestId: "", error: "Client certificate header not accepted from this source",
                    logger: req.logger)
                Task { try? await ws.close(code: .policyViolation) }
                return
            }

            guard let spiffeID = await extractVerifiedSPIFFEID(req: req, spireService: spireService) else {
                // extractVerifiedSPIFFEID already logged the specific failure
                sendErrorResponse(
                    ws: ws, requestId: "", error: "Invalid client certificate identity", logger: req.logger)
                Task { try? await ws.close(code: .unacceptableData) }
                return
            }

            do {
                let agentID = try await spireService.validateAgentIdentity(spiffeID)

                req.logger.info(
                    "Agent authenticated via XFCC header (Envoy mTLS)",
                    metadata: [
                        "spiffeID": .string(spiffeID.uri),
                        "agentID": .string(agentID),
                    ])

                // Continue with WebSocket setup using the validated agent ID
                setupWebSocketConnection(req: req, ws: ws, agentName: agentID, authMethod: "mTLS-XFCC")
            } catch {
                req.logger.error("SPIFFE ID validation failed: \(error)")
                sendErrorResponse(
                    ws: ws, requestId: "", error: "SPIFFE identity validation failed: \(error.localizedDescription)",
                    logger: req.logger)
                Task { try? await ws.close(code: .unacceptableData) }
            }
            return
        }

        // No client certificate was presented. When SPIRE requires client certs,
        // mTLS is mandatory — never silently downgrade to token auth, which would
        // let any caller that can reach the port authenticate as an agent.
        if requireClientCert {
            req.logger.error("mTLS required but no client certificate (X-Forwarded-Client-Cert) was presented")
            sendErrorResponse(
                ws: ws, requestId: "", error: "Client certificate required for agent authentication", logger: req.logger
            )
            Task { try? await ws.close(code: .unacceptableData) }
            return
        }

        // requireClientCert is explicitly disabled: permit legacy token authentication.
        req.logger.warning("SPIRE enabled without requireClientCert; falling back to token authentication")
        handleTokenAuthentication(req: req, ws: ws)
    }

    /// Whether the request arrived over the pod-local loopback interface, i.e. from
    /// the co-located Envoy sidecar that terminates mTLS, rather than directly over
    /// the pod network. Envoy forwards to the control plane on 127.0.0.1, so only
    /// loopback peers may be trusted to have passed through certificate verification.
    private func requestArrivedViaLocalSidecar(_ req: Request) -> Bool {
        guard let ip = req.remoteAddress?.ipAddress else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip == "::ffff:127.0.0.1"
    }

    // MARK: - XFCC Header Parsing

    /// Extract the client's SPIFFE ID from the X-Forwarded-Client-Cert header and,
    /// when Envoy also forwarded the certificate itself (`Cert=`/`Chain=`),
    /// independently re-verify that certificate against the SPIRE trust bundle and
    /// require its SAN URI to match the `URI=` field. This means a compromised or
    /// misconfigured proxy cannot assert an identity it does not hold a
    /// SPIRE-issued certificate for. Returns nil (after logging why) on any failure.
    private func extractVerifiedSPIFFEID(req: Request, spireService: SPIREService) async -> SPIFFEIdentity? {
        guard let xfcc = req.headers.first(name: "X-Forwarded-Client-Cert") else {
            return nil
        }

        guard let element = XFCCElement.parseNearestHop(header: xfcc) else {
            req.logger.warning("XFCC header present but unparseable", metadata: ["xfcc": .string(xfcc)])
            return nil
        }

        guard let uriString = element.uri, let claimedID = SPIFFEIdentity(uri: uriString) else {
            req.logger.warning("XFCC header present but no valid SPIFFE URI found", metadata: ["xfcc": .string(xfcc)])
            return nil
        }

        // Chain= includes the leaf (leaf first); Cert= is the leaf alone.
        if let certificatePEM = element.chainPEM ?? element.certPEM {
            guard await spireService.hasTrustBundle else {
                // No bundle to verify against: accept Envoy's verification alone,
                // as before cert forwarding was enabled. Deployments that configure
                // a trust bundle get the stronger check automatically.
                req.logger.warning(
                    "XFCC forwarded a client certificate but no SPIRE trust bundle is configured; relying on Envoy's verification only"
                )
                return claimedID
            }

            do {
                let verifiedID = try await spireService.validateCertificate(certificatePEM)
                guard verifiedID == claimedID else {
                    req.logger.error(
                        "XFCC URI does not match the SAN URI of the forwarded client certificate",
                        metadata: [
                            "claimed": .string(claimedID.uri),
                            "verified": .string(verifiedID.uri),
                        ])
                    return nil
                }
            } catch {
                req.logger.error(
                    "Forwarded client certificate failed verification against the SPIRE trust bundle: \(error)",
                    metadata: ["claimed": .string(claimedID.uri)])
                return nil
            }
        }

        req.logger.debug("Extracted SPIFFE ID from XFCC", metadata: ["spiffeID": .string(claimedID.uri)])
        return claimedID
    }

    // MARK: - Token Authentication (Legacy)

    private func handleTokenAuthentication(req: Request, ws: WebSocket) {
        // Extract token from the Authorization header (Bearer) and agent name from the
        // query. The token is kept out of the URL so it never lands in access logs.
        guard let token = req.headers.bearerAuthorization?.token,
            let agentName = req.query[String.self, at: "name"]
        else {
            sendErrorResponse(
                ws: ws, requestId: "", error: "Registration token and agent name are required", logger: req.logger)
            Task { try? await ws.close(code: .unacceptableData) }
            return
        }

        // Set up message handlers IMMEDIATELY to prevent message loss
        // Messages will be buffered until validation completes
        // Note: All access to these variables happens on ws.eventLoop, so no actual concurrency
        final class MessageState: @unchecked Sendable {
            var buffer: [String] = []
            var isValidated = false
        }
        let state = MessageState()

        ws.onText { ws, text in
            if state.isValidated {
                self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
            } else {
                // Buffer messages until validation completes
                state.buffer.append(text)
            }
        }

        ws.onBinary { ws, buffer in
            req.logger.info(
                "Received WebSocket binary message from agent",
                metadata: ["agentName": .string(agentName), "bytes": .string("\(buffer.readableBytes)")])
            // Convert binary buffer to string and process as text message
            if let text = buffer.getString(at: 0, length: buffer.readableBytes) {
                if state.isValidated {
                    self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
                } else {
                    // Buffer messages until validation completes
                    state.buffer.append(text)
                }
            } else {
                req.logger.error("Failed to convert binary buffer to string")
            }
        }

        ws.onClose.whenComplete { result in
            switch result {
            case .success:
                req.logger.info(
                    "Agent WebSocket connection closed normally",
                    metadata: [
                        "agentName": .string(agentName)
                    ])
            case .failure(let error):
                req.logger.error(
                    "Agent WebSocket connection closed with error: \(error)",
                    metadata: [
                        "agentName": .string(agentName)
                    ])
            }

            // Only tear down agent state if this socket is still the agent's current
            // connection — a delayed close from a connection the agent has already
            // replaced (reconnect under the same name) must not remove its successor.
            guard req.application.websocketManager.removeConnection(agentName: agentName, ifCurrent: ws) else {
                req.logger.debug(
                    "Closed WebSocket was already superseded; skipping agent cleanup",
                    metadata: [
                        "agentName": .string(agentName)
                    ])
                return
            }

            // Mark agent as offline asynchronously
            Task {
                await req.agentService.removeAgent(agentName)
            }
        }

        // Validate registration token using EventLoopFuture
        validateRegistrationToken(req: req, ws: ws, token: token, agentName: agentName)
            .flatMap { isValid -> EventLoopFuture<Void> in
                guard isValid else {
                    return ws.eventLoop.makeSucceededFuture(())
                }

                req.logger.info(
                    "Agent WebSocket connection established",
                    metadata: [
                        "agentName": .string(agentName)
                    ])

                // Store WebSocket for this agent - we're already on the WebSocket's event loop
                req.application.websocketManager.setConnection(agentName: agentName, websocket: ws)

                // Advertise which replica holds this agent's socket so other
                // replicas can route sync nudges here (issue #261). Refreshed
                // by every heartbeat; a crashed replica's claim expires by TTL.
                Task {
                    await req.application.coordination.recordAgentRoute(
                        agentName: agentName, replicaId: req.application.replicaID)
                }

                // Mark as validated and process buffered messages
                state.isValidated = true
                req.logger.info(
                    "Processing \(state.buffer.count) buffered messages", metadata: ["agentName": .string(agentName)])

                for text in state.buffer {
                    self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
                }
                state.buffer.removeAll()

                return ws.eventLoop.makeSucceededFuture(())
            }
            .whenFailure { error in
                req.logger.error("WebSocket handler error: \(error)")
                _ = ws.close(code: .unexpectedServerError)
            }
    }

    private func validateRegistrationToken(
        req: Request,
        ws: WebSocket,
        token: String,
        agentName: String
    ) -> EventLoopFuture<Bool> {
        // Query database for token
        let query = AgentRegistrationToken.query(on: req.db)
            .filter(\.$token == token)
            .filter(\.$agentName == agentName)
            .first()

        return query.flatMap { registrationToken -> EventLoopFuture<Bool> in
            guard let registrationToken = registrationToken else {
                Telemetry.agentRegistrationFailed(reason: "invalid_token")
                // The explicit code lets the agent tell a hopeless credential apart
                // from a transient server error, so only the former stops its
                // reconnect loop.
                self.sendErrorResponse(
                    ws: ws, requestId: "", error: "Invalid registration token",
                    code: ErrorMessage.ErrorCode.invalidToken, logger: req.logger)
                _ = ws.close(code: .unacceptableData)
                return req.eventLoop.makeSucceededFuture(false)
            }

            guard registrationToken.isValid else {
                Telemetry.agentRegistrationFailed(reason: "expired_token")
                self.sendErrorResponse(
                    ws: ws, requestId: "", error: "Registration token is invalid or expired",
                    code: ErrorMessage.ErrorCode.invalidToken, logger: req.logger)
                _ = ws.close(code: .unacceptableData)
                return req.eventLoop.makeSucceededFuture(false)
            }

            // Mark the single-use token consumed and persist it *before* accepting
            // the connection. Persisting is part of validation, not fire-and-forget:
            // if the save were swallowed and we proceeded anyway, the token would
            // stay unused in the store and remain replayable. On save failure we
            // reject instead — the token is untouched and the agent can retry.
            registrationToken.markAsUsed()
            return registrationToken.save(on: req.db).map { _ -> Bool in
                // Never log the raw token value — logs are lower-trust than the token
                // store and may be shipped off-host. The agent name is sufficient.
                req.logger.info(
                    "Agent registration token validated",
                    metadata: [
                        "agentName": .string(agentName)
                    ])
                return true
            }.flatMapError { error in
                Telemetry.agentRegistrationFailed(reason: "token_save_failed")
                req.logger.error(
                    "Failed to persist registration token as used; rejecting connection",
                    metadata: [
                        "agentName": .string(agentName),
                        "error": .string("\(error)"),
                    ])
                self.sendErrorResponse(
                    ws: ws, requestId: "", error: "Internal server error persisting registration token",
                    logger: req.logger)
                _ = ws.close(code: .unexpectedServerError)
                return req.eventLoop.makeSucceededFuture(false)
            }
        }.flatMapErrorThrowing { error in
            req.logger.error("Error validating registration token: \(error)")
            self.sendErrorResponse(
                ws: ws, requestId: "", error: "Internal server error during token validation", logger: req.logger)
            _ = ws.close(code: .unexpectedServerError)
            return false
        }
    }

    private func handleWebSocketMessage(req: Request, ws: WebSocket, text: String, agentName: String) {
        req.logger.info(
            "Processing WebSocket message",
            metadata: [
                "agentName": .string(agentName),
                "messageLength": .string("\(text.count)"),
                "rawTextPreview": .string(String(text.prefix(500))),
            ])

        guard let data = text.data(using: .utf8) else {
            req.logger.error("Failed to convert WebSocket text to data")
            return
        }

        do {
            let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: data)
            req.logger.info(
                "Decoded message envelope",
                metadata: ["type": .string("\(envelope.type)"), "agentName": .string(agentName)])

            switch envelope.type {
            case .agentRegister:
                let message = try envelope.decode(as: AgentRegisterMessage.self)
                let agentProtocolVersion = message.protocolVersion ?? 0
                if agentProtocolVersion != WireProtocol.currentVersion {
                    req.logger.warning(
                        "Agent wire protocol version differs from control plane",
                        metadata: [
                            "agentName": .string(agentName),
                            "agentProtocolVersion": .stringConvertible(agentProtocolVersion),
                            "controlPlaneProtocolVersion": .stringConvertible(WireProtocol.currentVersion),
                        ])
                }
                let isTokenAuthenticated = req.headers.bearerAuthorization != nil
                Task {
                    do {
                        let agentUUID = try await req.agentService.registerAgent(message, agentName: agentName)

                        // Rotate the single-use registration token: the one this
                        // connection presented was consumed at validation, so without a
                        // fresh token an automatic reconnect after an unexpected drop
                        // would be rejected. Rotation failure is non-fatal — the agent
                        // is registered either way, reconnect just needs a new token.
                        var reconnectToken: String?
                        if isTokenAuthenticated {
                            do {
                                // Generous expiry: the token sits unused until the
                                // connection drops, which may be long after registration.
                                let rotated = AgentRegistrationToken(agentName: agentName, expirationHours: 24 * 30)
                                try await rotated.save(on: req.db)
                                reconnectToken = rotated.token
                            } catch {
                                req.logger.error("Failed to rotate reconnect token for agent \(agentName): \(error)")
                            }
                        }

                        // Send registration response with the assigned UUID
                        let response = AgentRegisterResponseMessage(
                            requestId: message.requestId,
                            agentId: agentUUID.uuidString,
                            name: agentName,
                            reconnectToken: reconnectToken
                        )
                        self.sendMessage(ws: ws, message: response, logger: req.logger)

                        // A state-sync agent gets its authoritative desired
                        // state immediately on (re)registration, so drift
                        // accumulated while it was away converges without
                        // waiting for the periodic timer (issue #260).
                        await req.agentService.syncDesiredState(agentId: agentUUID.uuidString)
                    } catch {
                        Telemetry.agentRegistrationFailed(reason: "register_error")
                        req.logger.error("Failed to register agent: \(error)")

                        // Restore the presented token: it was marked used at connect
                        // validation, but registration failed before a rotated
                        // replacement was minted. Without this, a transient failure
                        // here (e.g. a DB blip) would permanently consume the agent's
                        // only credential and lock it out until an operator mints a
                        // new join token.
                        if isTokenAuthenticated, let bearer = req.headers.bearerAuthorization?.token {
                            do {
                                if let presented = try await AgentRegistrationToken.query(on: req.db)
                                    .filter(\.$token == bearer)
                                    .filter(\.$agentName == agentName)
                                    .first()
                                {
                                    presented.isUsed = false
                                    presented.usedAt = nil
                                    try await presented.save(on: req.db)
                                    req.logger.info(
                                        "Restored registration token after failed registration",
                                        metadata: [
                                            "agentName": .string(agentName)
                                        ])
                                }
                            } catch {
                                req.logger.error(
                                    "Failed to restore registration token for agent \(agentName): \(error)")
                            }
                        }

                        // A protocol-version rejection is permanent until the
                        // agent is upgraded — classify it so the agent can stop
                        // its reconnect loop. Everything else stays unclassified
                        // (treated as transient; the agent retries with backoff).
                        let errorCode: String?
                        if case AgentServiceError.unsupportedProtocolVersion = error {
                            errorCode = ErrorMessage.ErrorCode.unsupportedProtocolVersion
                        } else {
                            errorCode = nil
                        }
                        self.sendErrorResponse(
                            ws: ws, requestId: message.requestId,
                            error: "Failed to register agent: \(error.localizedDescription)",
                            code: errorCode, logger: req.logger)
                    }
                }

            case .agentHeartbeat:
                let message = try envelope.decode(as: AgentHeartbeatMessage.self)
                Task {
                    do {
                        try await req.agentService.updateAgentHeartbeat(message, fromAgentNamed: agentName)
                        self.sendSuccessResponse(
                            ws: ws, requestId: message.requestId, message: "Heartbeat acknowledged", logger: req.logger)
                    } catch {
                        req.logger.error("Failed to update heartbeat: \(error)")
                        self.sendErrorResponse(
                            ws: ws, requestId: message.requestId, error: "Failed to update heartbeat",
                            logger: req.logger)
                    }
                }

            case .agentUnregister:
                let message = try envelope.decode(as: AgentUnregisterMessage.self)
                Task {
                    do {
                        try await req.agentService.unregisterAgent(message.agentId)
                        self.sendSuccessResponse(
                            ws: ws, requestId: message.requestId, message: "Agent unregistered successfully",
                            logger: req.logger)
                    } catch {
                        req.logger.error("Failed to unregister agent: \(error)")
                        self.sendErrorResponse(
                            ws: ws, requestId: message.requestId, error: "Failed to unregister agent",
                            logger: req.logger)
                    }
                }

            case .success, .error:
                // Correlated responses to control-plane-initiated requests
                Task {
                    await req.agentService.handleAgentResponse(envelope)
                }

            case .statusUpdate:
                // Unsolicited VM state change reported by the agent; persist it
                Task {
                    await req.agentService.applyStatusUpdate(envelope, fromAgentNamed: agentName)
                }

            case .observedState:
                // Full observed-state report from a state-sync agent: updates
                // observed status/generation, completes operations, confirms
                // deletions by absence (issue #260). Enqueued rather than
                // applied directly so same-agent reports apply in send order.
                Task {
                    await req.agentService.enqueueObservedStateReport(envelope, fromAgentNamed: agentName)
                }

            case .consoleData:
                // Route console data from agent to frontend
                let message = try envelope.decode(as: ConsoleDataMessage.self)
                if let data = message.rawData {
                    req.consoleSessionManager.routeToFrontend(
                        vmId: message.vmId,
                        sessionId: message.sessionId,
                        data: data
                    )
                }

            case .consoleConnected:
                let message = try envelope.decode(as: ConsoleConnectedMessage.self)
                req.logger.info(
                    "Console connected confirmation from agent",
                    metadata: [
                        "vmId": .string(message.vmId),
                        "sessionId": .string(message.sessionId),
                    ])
                // Notify the frontend that the console is ready for input
                req.consoleSessionManager.notifyFrontendReady(sessionId: message.sessionId)

            case .consoleDisconnected:
                let message = try envelope.decode(as: ConsoleDisconnectedMessage.self)
                req.logger.info(
                    "Console disconnected from agent",
                    metadata: [
                        "vmId": .string(message.vmId),
                        "sessionId": .string(message.sessionId),
                        "reason": .string(message.reason ?? "unknown"),
                    ])
                // Clean up the session
                req.consoleSessionManager.removeSession(sessionId: message.sessionId)

            case .vmLog:
                // Handle VM log messages from agent - push to Loki
                let message = try envelope.decode(as: VMLogMessage.self)
                Task {
                    do {
                        try await req.lokiService.pushLog(message)
                        req.logger.debug(
                            "VM log pushed to Loki",
                            metadata: [
                                "vmId": .string(message.vmId),
                                "level": .string(message.level.rawValue),
                                "eventType": .string(message.eventType.rawValue),
                            ])
                    } catch {
                        req.logger.error("Failed to push VM log to Loki: \(error)")
                    }
                }

            default:
                req.logger.warning("Received unexpected message type from agent: \(envelope.type)")
                sendErrorResponse(
                    ws: ws, requestId: "", error: "Unexpected message type: \(envelope.type)", logger: req.logger)
            }

        } catch {
            req.logger.error("Failed to handle WebSocket message: \(error)")
            sendErrorResponse(
                ws: ws, requestId: "", error: "Failed to process message: \(error.localizedDescription)",
                logger: req.logger)
        }
    }

    private func sendMessage<T: WebSocketMessage>(ws: WebSocket, message: T, logger: Logger) {
        do {
            let envelope = try MessageEnvelope(message: message)
            let data = try WireProtocol.makeEncoder().encode(envelope)
            ws.send(data)
        } catch {
            Telemetry.agentSendFailed(kind: "message")
            logger.error("Failed to send message to agent", metadata: ["error": .string("\(error)")])
        }
    }

    private func sendSuccessResponse(ws: WebSocket, requestId: String, message: String, logger: Logger) {
        do {
            let response = SuccessMessage(requestId: requestId, message: message)
            let envelope = try MessageEnvelope(message: response)
            let data = try WireProtocol.makeEncoder().encode(envelope)
            ws.send(data)
        } catch {
            Telemetry.agentSendFailed(kind: "success")
            logger.error(
                "Failed to send success response to agent",
                metadata: [
                    "requestId": .string(requestId),
                    "error": .string("\(error)"),
                ])
        }
    }

    private func sendErrorResponse(ws: WebSocket, requestId: String, error: String, code: String? = nil, logger: Logger)
    {
        do {
            let response = ErrorMessage(requestId: requestId, error: error, code: code)
            let envelope = try MessageEnvelope(message: response)
            let data = try WireProtocol.makeEncoder().encode(envelope)
            ws.send(data)
        } catch {
            Telemetry.agentSendFailed(kind: "error")
            logger.error(
                "Failed to send error response to agent",
                metadata: [
                    "requestId": .string(requestId),
                    "error": .string("\(error)"),
                ])
        }
    }

    // MARK: - WebSocket Connection Setup (shared by both auth methods)

    /// Set up WebSocket connection - MUST be called from WebSocket's event loop
    /// This method schedules the actual setup on the event loop to ensure handlers are registered correctly
    private func setupWebSocketConnection(req: Request, ws: WebSocket, agentName: String, authMethod: String) {
        // Execute on the WebSocket's event loop to avoid NIOLoopBound precondition failures
        ws.eventLoop.execute {
            req.logger.info(
                "Setting up WebSocket connection",
                metadata: [
                    "agentName": .string(agentName),
                    "authMethod": .string(authMethod),
                ])

            // Set up message handlers
            ws.onText { [self] ws, text in
                self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
            }

            ws.onBinary { [self] ws, buffer in
                req.logger.info(
                    "Received WebSocket binary message from agent",
                    metadata: [
                        "agentName": .string(agentName),
                        "bytes": .string("\(buffer.readableBytes)"),
                    ])
                if let text = buffer.getString(at: 0, length: buffer.readableBytes) {
                    self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
                } else {
                    req.logger.error("Failed to convert binary buffer to string")
                }
            }

            ws.onClose.whenComplete { result in
                switch result {
                case .success:
                    req.logger.info(
                        "Agent WebSocket connection closed normally",
                        metadata: [
                            "agentName": .string(agentName),
                            "authMethod": .string(authMethod),
                        ])
                case .failure(let error):
                    req.logger.error(
                        "Agent WebSocket connection closed with error: \(error)",
                        metadata: [
                            "agentName": .string(agentName),
                            "authMethod": .string(authMethod),
                        ])
                }

                // Only tear down agent state if this socket is still the agent's current
                // connection — a delayed close from a connection the agent has already
                // replaced (reconnect under the same name) must not remove its successor.
                guard req.application.websocketManager.removeConnection(agentName: agentName, ifCurrent: ws) else {
                    req.logger.debug(
                        "Closed WebSocket was already superseded; skipping agent cleanup",
                        metadata: [
                            "agentName": .string(agentName)
                        ])
                    return
                }

                // Mark agent as offline asynchronously
                Task {
                    await req.agentService.removeAgent(agentName)
                }
            }

            // Store WebSocket for this agent
            req.application.websocketManager.setConnection(agentName: agentName, websocket: ws)

            // Advertise which replica holds this agent's socket so other
            // replicas can route sync nudges here (issue #261). Refreshed
            // by every heartbeat; a crashed replica's claim expires by TTL.
            Task {
                await req.application.coordination.recordAgentRoute(
                    agentName: agentName, replicaId: req.application.replicaID)
            }

            req.logger.info(
                "Agent WebSocket connection established via \(authMethod)",
                metadata: [
                    "agentName": .string(agentName)
                ])
        }
    }
}
