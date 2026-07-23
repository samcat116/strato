import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent

struct AgentWebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agentRoutes = routes.grouped("agent")
        // Observed-state reports carry an entry per VM on the agent, so frames
        // grow with placement count and the 16 KiB default would reject reports
        // from an agent hosting a few hundred VMs. Must match the agent
        // client's limit, which needs the same headroom for desired-state syncs.
        agentRoutes.webSocket(
            "ws", maxFrameSize: .init(integerLiteral: 1 << 24), onUpgrade: websocketHandler)
    }

    /// Frames received before authentication completes are buffered here and
    /// replayed once the agent's identity is established. Both auth paths hop
    /// actors/event loops before they know the agent name (mTLS additionally
    /// performs certificate chain verification), and the agent sends its
    /// register frame immediately after the upgrade — without this buffer that
    /// first frame would be dropped and registration would stall until the
    /// agent times out and reconnects.
    /// All access happens on the WebSocket's event loop, so no actual concurrency.
    private final class MessageState: @unchecked Sendable {
        var buffer: [String] = []
        /// Total bytes held in `buffer`, checked against
        /// `maxPreAuthBufferBytes` so an unauthenticated peer cannot grow the
        /// buffer without bound while validation is in flight.
        var bufferedBytes = 0
        /// Set exactly once, when authentication succeeds; nil means "buffer".
        var agent: AuthenticatedAgent?
    }

    /// Ceiling on bytes buffered for a connection whose authentication is
    /// still in flight. Legitimate pre-auth traffic is a register frame (a few
    /// KB), at most followed by an early observed-state report; 4 MiB covers
    /// both with orders-of-magnitude headroom. Without a cap, the route's
    /// 16 MiB max frame size would let an unauthenticated peer queue
    /// arbitrarily many large frames during the validation window.
    private static let maxPreAuthBufferBytes = 1 << 22

    /// Buffers a frame that arrived before authentication completed, closing
    /// the connection instead if the peer has exceeded the pre-auth cap.
    /// Runs on the WebSocket's event loop, like all `state` access.
    private func bufferPreAuthFrame(req: Request, ws: WebSocket, text: String, state: MessageState) {
        state.bufferedBytes += text.utf8.count
        guard state.bufferedBytes <= Self.maxPreAuthBufferBytes else {
            req.logger.warning(
                "Closing agent WebSocket: pre-authentication buffer limit exceeded",
                metadata: ["bufferedBytes": .stringConvertible(state.bufferedBytes)])
            state.buffer.removeAll()
            _ = ws.close(code: .policyViolation)
            return
        }
        state.buffer.append(text)
    }

    // Non-async handler - runs on WebSocket's event loop
    private func websocketHandler(req: Request, ws: WebSocket) {
        // Register message handlers IMMEDIATELY (before any await) so no frame
        // can slip through while authentication is in flight.
        let state = MessageState()

        ws.onText { ws, text in
            if let agent = state.agent {
                self.handleWebSocketMessage(req: req, ws: ws, text: text, agent: agent, state: state)
            } else {
                self.bufferPreAuthFrame(req: req, ws: ws, text: text, state: state)
            }
        }

        ws.onBinary { ws, buffer in
            guard let text = buffer.getString(at: 0, length: buffer.readableBytes) else {
                req.logger.error("Failed to convert binary buffer to string")
                return
            }
            if let agent = state.agent {
                self.handleWebSocketMessage(req: req, ws: ws, text: text, agent: agent, state: state)
            } else {
                self.bufferPreAuthFrame(req: req, ws: ws, text: text, state: state)
            }
        }

        // Agents authenticate solely by SPIFFE/mTLS. There is no token path to
        // fall back to, so a control plane without SPIRE configured cannot
        // accept an agent at all — refuse naming the missing configuration
        // rather than holding the socket open against an auth path that can
        // never complete.
        guard let spireService = req.application.spireService else {
            rejectUnconfigured(req: req, ws: ws)
            return
        }

        Task {
            guard await spireService.isEnabled else {
                self.rejectUnconfigured(req: req, ws: ws)
                return
            }
            await self.handleMTLSAuthentication(req: req, ws: ws, spireService: spireService, state: state)
        }
    }

    /// Refuses a connection on a control plane with no SPIRE configuration.
    /// Distinct from a rejected identity: nothing the agent could present would
    /// succeed here, so this is operator misconfiguration and is logged as such.
    private func rejectUnconfigured(req: Request, ws: WebSocket) {
        req.logger.error(
            "Refusing agent WebSocket: agent authentication requires SPIRE, which is not configured")
        sendErrorResponse(
            ws: ws, requestId: "",
            error: "Agent authentication requires SPIRE, which is not configured on this control plane",
            logger: req.logger)
        Task { try? await ws.close(code: .policyViolation) }
    }

    /// Switch a connection from buffering to routing: record the authenticated
    /// agent name and replay any frames that arrived during authentication.
    /// Hops to the WebSocket's event loop, where all `state` access lives.
    private func activateMessageRouting(req: Request, ws: WebSocket, state: MessageState, agent: AuthenticatedAgent) {
        ws.eventLoop.execute {
            state.agent = agent
            if !state.buffer.isEmpty {
                req.logger.info(
                    "Processing \(state.buffer.count) buffered messages",
                    metadata: ["agentName": .string(agent.name)]
                )
            }
            for text in state.buffer {
                self.handleWebSocketMessage(req: req, ws: ws, text: text, agent: agent, state: state)
            }
            state.buffer.removeAll()
        }
    }

    // MARK: - mTLS Authentication (SPIFFE/SPIRE)

    private func handleMTLSAuthentication(
        req: Request, ws: WebSocket, spireService: SPIREService, state: MessageState
    ) async {
        // The X-Forwarded-Client-Cert (XFCC) header is only trustworthy when the
        // request provably arrived through the pod-local Envoy sidecar. Envoy
        // terminates mTLS, applies SANITIZE_SET (stripping any client-supplied XFCC),
        // injects the verified client identity, and then dials the control plane over
        // loopback (127.0.0.1). A request carrying XFCC from any other peer never
        // passed through Envoy's certificate verification and is a spoofing attempt.
        if AgentMTLSAuthenticator.hasClientCertificate(req) {
            guard AgentMTLSAuthenticator.requestArrivedViaLocalSidecar(req) else {
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

            guard
                let verified = await AgentMTLSAuthenticator.extractVerifiedSPIFFEID(
                    req: req, spireService: spireService)
            else {
                // extractVerifiedSPIFFEID already logged the specific failure
                sendErrorResponse(
                    ws: ws, requestId: "", error: "Invalid client certificate identity", logger: req.logger)
                Task { try? await ws.close(code: .unacceptableData) }
                return
            }

            do {
                _ = try await spireService.validateAgentIdentity(verified.identity)
                guard let identity = verified.identity.agentIdentity else {
                    throw SPIREServiceError.certificateValidationFailed(
                        "SPIFFE ID is not an agent identity: \(verified.identity.uri)")
                }
                // The workload registry is authoritative for the mapping
                // (issue #491): a URI registered to a different principal is
                // rejected, and a first-seen agent identity is registered.
                try await WorkloadRegistry.requireAgentRegistration(identity: identity, on: req.db)

                req.logger.info(
                    "Agent authenticated via XFCC header (Envoy mTLS)",
                    metadata: [
                        "spiffeID": .string(verified.identity.uri),
                        "agentName": .string(identity.name),
                        "organizationId": .string(verified.organizationID?.uuidString ?? "platform"),
                    ])

                // Continue with WebSocket setup using the validated identity.
                // The socket is keyed by the full SPIFFE ID, not the bare name:
                // two organizations may each enroll an `agent-1` once per-org
                // trust domains are on (issue #613).
                setupWebSocketConnection(
                    req: req, ws: ws,
                    agent: AuthenticatedAgent(identity: identity, organizationID: verified.organizationID),
                    authMethod: "mTLS-XFCC", state: state)
            } catch {
                req.logger.error("SPIFFE ID validation failed: \(error)")
                sendErrorResponse(
                    ws: ws, requestId: "", error: "SPIFFE identity validation failed: \(error.localizedDescription)",
                    logger: req.logger)
                Task { try? await ws.close(code: .unacceptableData) }
            }
            return
        }

        // No client certificate was presented, and there is no token path to
        // downgrade to: mTLS is the only way an agent authenticates, so this is
        // always fatal. SPIRE_REQUIRE_CLIENT_CERT no longer softens it — with
        // token auth gone, a connection presenting no certificate carries no
        // credential at all.
        req.logger.error("mTLS required but no client certificate (X-Forwarded-Client-Cert) was presented")
        sendErrorResponse(
            ws: ws, requestId: "", error: "Client certificate required for agent authentication", logger: req.logger)
        Task { try? await ws.close(code: .unacceptableData) }
    }

    // The loopback-provenance check and XFCC extraction/verification live in
    // AgentMTLSAuthenticator, shared with the mTLS-authenticated artifact
    // download route (issue #493).

    private func handleWebSocketMessage(
        req: Request, ws: WebSocket, text: String, agent: AuthenticatedAgent, state: MessageState
    ) {
        // The key every agent-scoped registry is stored under (sockets,
        // presence, routes, session ownership) — the full SPIFFE ID, never the
        // bare name. `identity.name` is for display and the register response.
        let agentKey = agent.identity.key
        let agentName = agent.name
        // Routine per-message receipt is a debugging aid, not an operator
        // signal, and it is the one log line whose rate scales with fleet size
        // on a single host: every agent's heartbeat and observed-state report
        // lands here (issue #705). The raw-frame dump is noisier still, so it
        // sits a level below the decoded envelope.
        req.logger.trace(
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
            req.logger.debug(
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
                Task {
                    do {
                        // Site and organization scope come from the agent's
                        // enrollment row, resolved inside registerAgent: an SVID
                        // authenticates the node's identity but carries neither.
                        let agentUUID = try await req.agentService.registerAgent(
                            message, identity: agent.identity,
                            identityOrganizationID: agent.organizationID)

                        // Send registration response with the assigned UUID
                        let response = AgentRegisterResponseMessage(
                            requestId: message.requestId,
                            agentId: agentUUID.uuidString,
                            name: agentName
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

                        // A protocol-version rejection is permanent until the
                        // agent is upgraded — classify it so the agent can stop
                        // its reconnect loop. Everything else stays unclassified
                        // (treated as transient; the agent retries with backoff).
                        let errorCode: String?
                        switch error {
                        case AgentServiceError.unsupportedProtocolVersion:
                            errorCode = ErrorMessage.ErrorCode.unsupportedProtocolVersion
                        case AgentServiceError.missingOrganizationScope:
                            // Permanent until an operator acts: this node has no
                            // enrollment carrying an org scope, and reconnecting
                            // will not create one. Classified as invalid_token so
                            // the agent stops its reconnect loop and exits with
                            // instructions rather than looping on an
                            // unrecognized code.
                            errorCode = ErrorMessage.ErrorCode.invalidToken
                        default:
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
                        try await req.agentService.updateAgentHeartbeat(message, fromAgentKey: agentKey)
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
                        try await req.agentService.unregisterAgent(message.agentId, fromAgentKey: agentKey)
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
                // Correlated responses to control-plane-initiated requests.
                // Pass the authenticated connection's agent name so the service
                // only resolves a request it actually dispatched to this agent.
                Task {
                    await req.agentService.handleAgentResponse(envelope, fromAgentKey: agentKey)
                }

            case .observedState:
                // Full observed-state report from a state-sync agent: updates
                // observed status/generation, completes operations, confirms
                // deletions by absence (issue #260). Enqueued rather than
                // applied directly so same-agent reports apply in send order.
                Task {
                    await req.agentService.enqueueObservedStateReport(envelope, fromAgentKey: agentKey)
                }

            case .consoleData:
                // Route console data from agent to frontend
                let message = try envelope.decode(as: ConsoleDataMessage.self)
                if let data = message.rawData {
                    req.consoleSessionManager.routeToFrontend(
                        vmId: message.vmId,
                        sessionId: message.sessionId,
                        data: data,
                        fromAgentKey: agentKey
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
                req.consoleSessionManager.notifyFrontendReady(
                    sessionId: message.sessionId, fromAgentKey: agentKey)

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
                req.consoleSessionManager.removeSession(
                    sessionId: message.sessionId, fromAgentKey: agentKey)

            case .sandboxExecStarted:
                let message = try envelope.decode(as: SandboxExecStartedMessage.self)
                req.sandboxExecSessionManager.handleStarted(
                    sessionId: message.sessionId, fromAgentKey: agentKey)

            case .sandboxExecOutput:
                let message = try envelope.decode(as: SandboxExecOutputMessage.self)
                if let data = message.rawData {
                    req.sandboxExecSessionManager.handleOutput(
                        sessionId: message.sessionId, fromAgentKey: agentKey, data: data)
                }

            case .sandboxExecExit:
                let message = try envelope.decode(as: SandboxExecExitMessage.self)
                req.sandboxExecSessionManager.handleExit(
                    sessionId: message.sessionId, fromAgentKey: agentKey, exitCode: message.exitCode)

            case .sandboxExecClosed:
                let message = try envelope.decode(as: SandboxExecClosedMessage.self)
                req.sandboxExecSessionManager.handleClosed(
                    sessionId: message.sessionId, fromAgentKey: agentKey, reason: message.reason)

            case .sandboxLog:
                // Sandbox workload stdout/stderr line from the agent — push to
                // Loki. Skip entirely when Loki isn't deployed rather than
                // dropping the message downstream.
                guard req.application.lokiEnabled else {
                    break
                }
                let message = try envelope.decode(as: SandboxLogMessage.self)
                // Enqueue only: the ingestor's single serial consumer keeps
                // the agent's line order (Loki rejects out-of-order entries
                // per stream) and caches the per-line ownership check instead
                // of issuing a DB point query per line.
                req.application.sandboxLogIngestor.enqueue(message, fromAgentKey: agentKey)

            case .vmLog:
                // Handle VM log messages from agent - push to Loki.
                // Skip entirely when Loki isn't deployed rather than dropping the message downstream.
                guard req.application.lokiEnabled else {
                    break
                }
                let message = try envelope.decode(as: VMLogMessage.self)
                Task {
                    // Only accept logs for a VM actually assigned to the reporting
                    // agent. Without this a compromised agent could push fabricated
                    // log lines tagged with another tenant's VM id, which would then
                    // surface in that tenant's console/log view.
                    guard await req.agentService.vmIsOwnedByAgent(vmId: message.vmId, agentKey: agentKey) else {
                        req.logger.warning(
                            "Dropping VM log for a VM not owned by the reporting agent",
                            metadata: [
                                "vmId": .string(message.vmId),
                                "agentName": .string(agentName),
                            ])
                        return
                    }
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
    /// This method schedules the actual setup on the event loop to ensure handlers are registered correctly.
    /// Message handlers were already registered (buffering) at upgrade time; this
    /// registers close handling, records the connection, and switches the
    /// connection from buffering to routing.
    private func setupWebSocketConnection(
        req: Request, ws: WebSocket, agent: AuthenticatedAgent, authMethod: String, state: MessageState
    ) {
        // Every registry below is keyed by the agent's full SPIFFE ID: with a
        // trust domain per organization two orgs may each run an `agent-1`, and
        // a name-keyed socket map would cross their wires (issue #613). The
        // bare name stays in log metadata, where it is what an operator reads.
        let agentKey = agent.identity.key
        let agentName = agent.name

        // Execute on the WebSocket's event loop to avoid NIOLoopBound precondition failures
        ws.eventLoop.execute {
            req.logger.info(
                "Setting up WebSocket connection",
                metadata: [
                    "agentName": .string(agentName),
                    "authMethod": .string(authMethod),
                ])

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
                guard req.application.websocketManager.removeConnection(agentKey: agentKey, ifCurrent: ws) else {
                    req.logger.debug(
                        "Closed WebSocket was already superseded; skipping agent cleanup",
                        metadata: [
                            "agentName": .string(agentName)
                        ])
                    return
                }

                // Console and attached exec sessions cannot outlive the agent
                // socket: close their browser sockets with an error frame
                // instead of leaving frozen terminals behind.
                req.application.consoleSessionManager.closeAllSessions(
                    forAgent: agentKey, reason: "agent disconnected")
                req.application.sandboxExecSessionManager.closeAllSessions(
                    forAgent: agentKey, reason: "agent disconnected")

                // Mark agent as offline asynchronously
                Task {
                    await req.agentService.removeAgent(agentKey)
                }
            }

            // Store WebSocket for this agent. If this reconnect superseded a
            // still-open prior socket, its console sessions are now stale (a
            // fresh agent process holds no console pty) and the delayed close
            // will skip them — tear them down here so their browsers don't sit
            // on a frozen terminal.
            if req.application.websocketManager.setConnection(agentKey: agentKey, websocket: ws) != nil {
                req.application.consoleSessionManager.closeAllSessions(
                    forAgent: agentKey, reason: "agent reconnected")
            }

            // Advertise which replica holds this agent's socket so other
            // replicas can route sync nudges here (issue #261). Refreshed
            // by every heartbeat; a crashed replica's claim expires by TTL.
            Task {
                await req.application.replicaBridge.recordRoute(agentKey: agentKey)
            }

            // Switch from buffering to routing, replaying any frames that
            // arrived while authentication was in flight.
            self.activateMessageRouting(req: req, ws: ws, state: state, agent: agent)

            req.logger.info(
                "Agent WebSocket connection established via \(authMethod)",
                metadata: [
                    "agentName": .string(agentName)
                ])
        }
    }
}
