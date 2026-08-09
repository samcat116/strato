import Foundation
import Logging
import StratoShared

/// One request, reduced to what the responder needs.
public struct MetadataRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: MetadataHeaders
    /// The peer address of the connection it arrived on. The entire
    /// identification mechanism — see `MetadataCallerIndex`.
    public let source: MetadataCallerAddress

    public init(method: String, target: String, headers: MetadataHeaders, source: MetadataCallerAddress) {
        self.method = method
        self.target = target
        self.headers = headers
        self.source = source
    }
}

/// The whole request policy of one network's metadata listener (STR-56): the
/// only place state is consulted, and the thing the issue's three demanded
/// tests drive.
///
/// Socket-free by construction. What an instance metadata service gets wrong is
/// never framing — it is answering the wrong caller, or answering one that never
/// authenticated — so the rules live where they can be asserted directly instead
/// of through a listener, a namespace and a guest.
public actor MetadataResponder {
    private var snapshot: MetadataSnapshot
    private var index: MetadataCallerIndex
    private var byVM: [UUID: InstanceMetadata]
    private let tokens: MetadataTokenStore
    private let logger: Logger

    public init(snapshot: MetadataSnapshot, tokens: MetadataTokenStore = MetadataTokenStore(), logger: Logger) {
        self.snapshot = snapshot
        self.index = MetadataCallerIndex(networkId: snapshot.networkId, instances: snapshot.instances)
        self.byVM = Dictionary(snapshot.instances.map { ($0.instanceId, $0) }, uniquingKeysWith: { first, _ in first })
        self.tokens = tokens
        self.logger = logger
    }

    /// Adopt a newly pushed snapshot.
    ///
    /// Sessions belonging to instances that are no longer servable are dropped
    /// here rather than left to expire: an address outlives the VM it was
    /// allocated to, so a token minted by a deleted instance must not stay valid
    /// for whoever inherits its address.
    public func update(_ snapshot: MetadataSnapshot) async {
        self.snapshot = snapshot
        self.index = MetadataCallerIndex(networkId: snapshot.networkId, instances: snapshot.instances)
        self.byVM = Dictionary(snapshot.instances.map { ($0.instanceId, $0) }, uniquingKeysWith: { first, _ in first })
        await tokens.retain(servable: Set(byVM.keys))
    }

    /// The response to `request`.
    ///
    /// The order of the checks is load-bearing, and each step says why it is
    /// where it is.
    public func respond(to request: MetadataRequest, at now: ContinuousClock.Instant) async -> MetadataResponse {
        // 1. Syntax, method and path shape. Pure and cheap, and it answers a
        //    malformed request without consulting — or revealing — any state.
        let route = MetadataRouter.route(method: request.method, target: request.target, headers: request.headers)
        if case .rejected(let response) = route { return response }

        // 2. Readiness, before identification rather than after. With no
        //    snapshot every caller is unresolvable, and 404 would assert "this
        //    host does not serve you" — a claim the agent cannot honestly make
        //    when it has not yet been told anything. 503 is what every IMDS
        //    client already retries; a confidently empty 200 is what breaks a
        //    guest's boot.
        guard snapshot.origin != .cold else {
            return .rejected(
                503, "metadata is not available on this host yet", headers: [.init("retry-after", "2")])
        }

        // 3. Identification. Necessarily before authentication: a session is
        //    bound to an instance, so there is nothing to validate a token
        //    against until the caller has a name. ("Authenticate, then
        //    identify" is the intuitive order and the impossible one.)
        let vmId: UUID
        switch index.resolve(request.source) {
        case .vm(let resolved):
            vmId = resolved
        case .unknown:
            logger.debug(
                "Metadata request from an address this host does not serve",
                metadata: [
                    "networkId": .string(snapshot.networkId.uuidString),
                    "source": .string(request.source.description),
                ])
            return .rejected(404, "not found")
        case .ambiguous(let vmIds):
            // An invariant violation, not a routine miss: two live instances
            // claim one address on one network. Refusing is the only safe
            // answer (see `MetadataCallerIndex`), and it is logged loudly
            // because nothing else in the system will notice.
            logger.warning(
                "Refusing metadata: two instances claim one address on this network",
                metadata: [
                    "networkId": .string(snapshot.networkId.uuidString),
                    "source": .string(request.source.description),
                    "instances": .string(vmIds.map(\.uuidString).joined(separator: ",")),
                ])
            // Same status as `.unknown`, so a response never distinguishes "no
            // such address" from "an address worth looking at".
            return .rejected(404, "not found")
        }

        // 4. The session handshake.
        switch route {
        case .mintToken(let ttlSeconds):
            let token = await tokens.mint(for: vmId, ttlSeconds: ttlSeconds, at: now)
            return MetadataResponse(
                status: 200,
                headers: [.init(MetadataHeaderName.tokenTTL, String(ttlSeconds))],
                body: token)

        case .document, .unknownDocument:
            guard case .one(let presented) = request.headers.lookup(MetadataHeaderName.token) else {
                return .rejected(
                    401, "missing \(MetadataHeaderName.token)",
                    headers: [.init("www-authenticate", "Strato-IMDSv2")])
            }
            guard await tokens.isValid(presented, for: vmId, at: now) else {
                // Covers three cases that must not be distinguishable from
                // outside: never minted, expired, and minted for a different
                // instance. The third is the one that matters — it is what
                // makes a token stolen from another guest worthless here.
                return .rejected(
                    401, "invalid \(MetadataHeaderName.token)",
                    headers: [.init("www-authenticate", "Strato-IMDSv2")])
            }

        case .rejected:
            // Handled at step 1; unreachable.
            return .rejected(400, "bad request")
        }

        // 5. The document itself, now that the caller is known and authenticated.
        guard case .document(let path) = route else { return .rejected(404, "not found") }
        guard let metadata = byVM[vmId], let body = MetadataDocument.render(path, for: metadata) else {
            // A key that exists in the tree but not for this instance — a
            // hostname-less VM. 404 rather than an empty 200: nothing here may
            // invent a value (`InstanceMetadata.hostname`).
            return .rejected(404, "not found")
        }
        return MetadataResponse(status: 200, body: body)
    }
}
