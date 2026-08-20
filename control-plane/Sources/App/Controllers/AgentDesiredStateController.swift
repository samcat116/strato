import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// `GET /agent/desired-state` — the desired-state long-poll (ADR 0001 stage
/// 10, STR-146).
///
/// Agents fetch their desired state here instead of waiting for a pushed
/// `desired_state` frame. The request arrives over the Envoy SVID-mTLS
/// listener that already carries image downloads, and is scoped by the
/// forwarded SVID identity exactly as the image-download route is (issue
/// #562) — an agent can only ever fetch its own state.
///
/// Why this direction: a push has to answer "which replica can reach agent X",
/// which is what the `agent:{name}:replica` routing directory and the targeted
/// `replica:{id}:nudges` channel existed for. A pull answers it structurally —
/// the agent dials whichever replica the load balancer picks, and a mutation
/// only has to ring a contentless broadcast doorbell that every replica
/// evaluates against its own parked polls.
///
/// The response body is a full `MessageEnvelope`, not a bare payload, so it
/// enters the agent's ordinary message-routing and desired-state serialization
/// lane.
struct AgentDesiredStateController: RouteCollection {
    private let agents: AgentsPersistence

    init(agents: AgentsPersistence) {
        self.agents = agents
    }

    /// How long a poll parks before answering `304`.
    ///
    /// Bounded above by what sits between the agent and the handler: Envoy's
    /// `/agent/` route has `timeout: 0s`, but the HTTP connection manager's
    /// default `stream_idle_timeout` (5 minutes) still applies to a stream
    /// with no bytes flowing, and load balancers commonly idle out at 60s.
    /// Bounded below by cost: every expiry costs a re-poll and an assembly.
    /// 45s clears the 60s convention with room to spare.
    ///
    /// Every poll assembles at least once, converged or not, so an idle fleet
    /// incurs one full multi-table read set per agent per hold window. The
    /// latency trade is deliberate, and it is why outbound registry calls in
    /// assembly are behind `RegistryOperationBackoff`: at this rate a failing
    /// call must not be retried per assembly.
    static let defaultHoldWindow: Duration = .seconds(45)

    /// Ceiling on assemblies within one parked poll. The doorbell is
    /// contentless and deliberately over-rings — a fleet-wide ring wakes every
    /// parked poll on every replica, including for agents the change cannot
    /// touch — and each wake-up costs a full assembly.
    ///
    /// Past this the poll stops re-assembling and waits out the rest of its
    /// hold window before answering `304`. It deliberately does **not** answer
    /// immediately: the agent treats `304` as "re-poll now" (correctly, since
    /// the server normally spent the whole window parked), so an instant `304`
    /// here would put the pair in a hot loop for as long as the mutation burst
    /// lasted. Nothing is lost by waiting — if the state really did change, the
    /// agent's next poll assembles once and gets its `200` immediately.
    static let maxAssembliesPerPoll = 20

    func boot(routes: any RoutesBuilder) throws {
        // Registered under `/agent/` deliberately: that prefix is the one
        // Envoy routes with `timeout: 0s`, so a parked poll is not cut off at
        // the default route timeout the way it would be under `/api/`.
        routes.get("agent", "desired-state", use: poll)
    }

    func poll(req: Request) async throws -> Response {
        // Agents only — no session fallback. Unlike the image-download route
        // there is no human-facing use for this endpoint, and a request
        // carrying XFCC that doesn't verify is a spoofing attempt rather than
        // a browser.
        guard AgentMTLSAuthenticator.hasClientCertificate(req) else {
            throw Abort(.unauthorized, reason: "Desired state requires an agent client certificate")
        }
        let agent = try await AgentMTLSAuthenticator.authenticateAgent(req: req)

        // Resolved by the SVID's full identity, not its bare name: two
        // organizations may each enroll an `agent-1` (issue #613), and one
        // must never be served the other's desired state.
        guard let agentRow = try await agents.agent(
            trustDomain: agent.identity.trustDomain,
            name: agent.identity.name
        ) else {
            req.logger.warning(
                "Desired-state poll from an agent identity with no registered agent",
                metadata: ["agent": .string(agent.identity.key)])
            throw Abort(.forbidden, reason: "No agent is registered for this identity")
        }
        let agentId = agentRow.id.uuidString

        let agentKey = agent.identity.key
        // An absent `If-None-Match` is not a cache miss to be worked around —
        // it is the agent explicitly asking for a full payload, which is the
        // correctness invariant of the whole design (ADR 0001: "the version is
        // a bandwidth saving", the unconditional re-fetch is what guarantees a
        // missed doorbell can only cost latency). Never park such a request,
        // and never answer it `304`.
        let ifNoneMatch = req.headers.first(name: .ifNoneMatch)
        let mode = Telemetry.DesiredStatePollMode.from(ifNoneMatch: ifNoneMatch)
        let clock = ContinuousClock()
        let deadline = clock.now + req.application.desiredStatePollHoldWindow
        var assemblies = 0

        while true {
            // Assembly is not side-effect free, and that is deliberate here:
            // it records image-download grants (issue #562) and mints registry
            // credentials, and ADR 0001 requires both to happen on the serving
            // replica at response-assembly time rather than from a cache.
            //
            // A conditional poll therefore assembles at least once even when
            // it ends in `304`, recording grants for a payload that is never
            // delivered. That is safe, and it is the specific question the ADR
            // left open: `grantImageDownload` is a fixed-TTL `SETEX` of
            // `imggrant:agent:{agentId}:image:{imageId}` — purely additive, and
            // scoped to the placement this assembly just read. Re-recording it
            // for an agent that is *currently* placed on the image is exactly
            // right; the agent may still be mid-pull. The rejected
            // "cache assembled payloads" alternative is different in kind: it
            // grants against a *stale* placement and serves stale credentials.
            let message = try await req.application.desiredStateAssembler.assemble(agentId: agentId)
            let etag = try DesiredStateDigest.etag(for: message)
            assemblies += 1

            if ifNoneMatch != etag {
                let response = try Self.payloadResponse(message: message, etag: etag)
                Telemetry.recordDesiredStatePoll(mode: mode, outcome: .served)
                if mode == .unconditional {
                    Telemetry.recordDesiredStateFullRefetch(agentName: agent.identity.name)
                }
                req.logger.debug(
                    "Desired-state poll served",
                    metadata: [
                        "agentId": .string(agentId),
                        "syncId": .string(message.syncId),
                        "vmCount": .stringConvertible(message.vms.count),
                        "conditional": .stringConvertible(ifNoneMatch != nil),
                    ])
                return response
            }

            if clock.now >= deadline {
                Telemetry.recordDesiredStatePoll(mode: mode, outcome: .notModified)
                return Self.notModifiedResponse(etag: etag)
            }

            // Out of assembly budget for this request. Sleep out the rest of
            // the window rather than answering now — see `maxAssembliesPerPoll`
            // for why an early `304` would put the agent in a hot loop.
            if assemblies >= Self.maxAssembliesPerPoll {
                Telemetry.recordDesiredStatePoll(mode: mode, outcome: .assemblyBudgetExhausted)
                req.logger.notice(
                    "Desired-state poll exhausted its assembly budget; idling out the hold window",
                    metadata: ["agentId": .string(agentId)])
                try? await Task.sleep(until: deadline, clock: clock)
                return Self.notModifiedResponse(etag: etag)
            }

            let parked = await req.application.desiredStatePollRegistry.wait(
                agentKey: agentKey, until: deadline)

            // Too many polls already parked for this agent. Same treatment as
            // budget exhaustion, and for the same reason: refusing to park has
            // to mean "wait", not "answer now", or the excess polls become a
            // hot loop instead of an idle one.
            if parked == .refused {
                Telemetry.recordDesiredStatePoll(mode: mode, outcome: .parkRefused)
                try? await Task.sleep(until: deadline, clock: clock)
                return Self.notModifiedResponse(etag: etag)
            }

            // The client hung up while we were parked. Re-assembling for a
            // response nobody will read would spend a database round trip per
            // abandoned poll, which on a reconnecting fleet is exactly when the
            // control plane can least afford it.
            if Task.isCancelled { return Self.notModifiedResponse(etag: etag) }
        }
    }

    private static func payloadResponse(message: DesiredStateMessage, etag: String) throws -> Response {
        let body = try WireProtocol.encodeEnvelope(message)
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        // The payload is per-agent and changes without notice; the ETag is the
        // only caching contract, and it is between the agent and the handler.
        response.headers.cacheControl = HTTPHeaders.CacheControl(noStore: true)
        return response
    }

    private static func notModifiedResponse(etag: String) -> Response {
        let response = Response(status: .notModified)
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        response.headers.cacheControl = HTTPHeaders.CacheControl(noStore: true)
        return response
    }
}

extension Application {
    private struct DesiredStatePollHoldWindowKey: StorageKey {
        typealias Value = Duration
    }

    /// How long a desired-state poll parks before answering `304`. Settable so
    /// tests can drive the park/expire path without waiting out a production
    /// hold window.
    var desiredStatePollHoldWindow: Duration {
        get { storage[DesiredStatePollHoldWindowKey.self] ?? AgentDesiredStateController.defaultHoldWindow }
        set { storage[DesiredStatePollHoldWindowKey.self] = newValue }
    }
}
