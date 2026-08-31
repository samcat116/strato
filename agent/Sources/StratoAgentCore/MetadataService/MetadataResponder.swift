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
    private let identityTokens: GuestIdentityTokenCache
    private let identityMinter: GuestIdentityMinter?
    private let logger: Logger

    public init(
        snapshot: MetadataSnapshot,
        tokens: MetadataTokenStore = MetadataTokenStore(),
        identityTokens: GuestIdentityTokenCache = GuestIdentityTokenCache(),
        identityMinter: GuestIdentityMinter? = nil,
        logger: Logger
    ) {
        self.snapshot = snapshot
        self.index = MetadataCallerIndex(networkId: snapshot.networkId, instances: snapshot.instances)
        self.byVM = Dictionary(snapshot.instances.map { ($0.instanceId, $0) }, uniquingKeysWith: { first, _ in first })
        self.tokens = tokens
        self.identityTokens = identityTokens
        self.identityMinter = identityMinter
        self.logger = logger
    }

    /// Adopt a newly pushed snapshot.
    ///
    /// Sessions belonging to instances that are no longer servable are dropped
    /// here rather than left to expire: an address outlives the VM it was
    /// allocated to, so a token minted by a deleted instance must not stay valid
    /// for whoever inherits its address.
    ///
    /// An instance whose kill switch has just been thrown counts as no longer
    /// servable, so throwing it *revokes* the session rather than only refusing
    /// the next request with it. Step 4 of `respond(to:at:)` would catch that
    /// request anyway; retiring the token means the guest cannot be holding one
    /// at the moment an operator decides it should not.
    public func update(_ snapshot: MetadataSnapshot) async {
        self.snapshot = snapshot
        self.index = MetadataCallerIndex(networkId: snapshot.networkId, instances: snapshot.instances)
        self.byVM = Dictionary(snapshot.instances.map { ($0.instanceId, $0) }, uniquingKeysWith: { first, _ in first })
        await tokens.retain(servable: Set(byVM.filter { $0.value.isServiceEnabled }.keys))
        await identityTokens.retain(
            policies: Dictionary(
                uniqueKeysWithValues: byVM.compactMap { vmId, metadata in
                    guard metadata.isServiceEnabled, let identity = metadata.identity,
                        !identity.audiences.isEmpty
                    else { return nil }
                    return (vmId, identity)
                }))
    }

    /// The response to `request`.
    ///
    /// The order of the checks is load-bearing, and each step says why it is
    /// where it is.
    public func respond(
        to request: MetadataRequest,
        at now: ContinuousClock.Instant,
        wallTime: Date = Date()
    ) async -> MetadataResponse {
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

        // 4. The per-instance kill switch (STR-185). After identification —
        //    there is no way to know whose switch to read before the caller has
        //    a name — and deliberately *before* the handshake, so a switched-off
        //    instance cannot even mint a token: a session it could never spend
        //    is state a guest can make this process hold by asking.
        //
        //    The instance stays in `index` rather than being dropped from the
        //    servable set, which is the whole reason this check exists as its
        //    own step. Omitting it upstream would have been simpler and is
        //    wrong: its addresses would leave the index, so a collision with a
        //    live instance would stop resolving `.ambiguous` and start
        //    resolving to the *other* VM — handing its identity to the very
        //    workload someone hardened. Refusing a caller we can name costs one
        //    branch and keeps the collision detectable.
        if let metadata = byVM[vmId], !metadata.isServiceEnabled {
            logger.debug(
                "Refusing metadata: the service is switched off for this instance",
                metadata: [
                    "networkId": .string(snapshot.networkId.uuidString),
                    "strato.vm.id": .string(vmId.uuidString),
                ])
            // Again `.unknown`'s answer. A guest learning that the service is
            // *deliberately* off for it learns which of its neighbours are
            // worth attacking instead, and it has nothing to do with the
            // information either way.
            return .rejected(404, "not found")
        }

        // 5. NoCloud's narrow bootstrap capability. Stock NoCloud follows a
        //    `seedfrom` URL with ordinary GETs and cannot mint or attach an
        //    IMDSv2 session token. The unguessable URL authenticates only the
        //    three NoCloud documents, remains bound to the source VM by step 3,
        //    and remains subject to the kill switch in step 4.
        if case .noCloudSeed(let presented, let path) = route {
            guard let metadata = byVM[vmId],
                Self.seedTokenMatches(presented, expected: metadata.noCloudSeedToken),
                let path,
                let body = MetadataDocument.render(path, for: metadata)
            else {
                return .rejected(404, "not found")
            }
            return MetadataResponse(status: 200, body: body)
        }

        // 6. The session handshake for every ordinary IMDS document.
        switch route {
        case .mintToken(let ttlSeconds):
            let token = await tokens.mint(for: vmId, ttlSeconds: ttlSeconds, at: now)
            return MetadataResponse(
                status: 200,
                headers: [.init(MetadataHeaderName.tokenTTL, String(ttlSeconds))],
                body: token)

        case .document, .identity, .unknownDocument:
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

        case .noCloudSeed:
            // Handled above; unreachable.
            return .rejected(400, "bad request")

        case .rejected:
            // Handled at step 1; unreachable.
            return .rejected(400, "bad request")
        }

        // 7. The document itself, now that the caller is known and authenticated.
        if case .identity(let audience) = route {
            // A missing or empty policy is the VM-level opt-in boundary. Use
            // the same 404 as an unknown caller so this endpoint never confirms
            // that a disabled VM has an instance identity registration.
            guard let metadata = byVM[vmId], let policy = metadata.identity,
                !policy.audiences.isEmpty
            else {
                return .rejected(404, "not found")
            }
            guard policy.audiences.contains(audience) else {
                return .rejected(403, "audience is not allowed")
            }
            guard let identityMinter else {
                return .rejected(
                    503, "identity is temporarily unavailable", headers: [.init("retry-after", "2")])
            }
            do {
                let svid = try await identityTokens.token(
                    vmId: vmId, audience: audience, policy: policy, now: wallTime,
                    minter: identityMinter)
                guard byVM[vmId]?.isServiceEnabled == true,
                    byVM[vmId]?.identity == policy,
                    policy.audiences.contains(audience)
                else {
                    return .rejected(404, "not found")
                }
                return MetadataResponse(status: 200, body: svid.token)
            } catch {
                guard byVM[vmId]?.isServiceEnabled == true,
                    let currentPolicy = byVM[vmId]?.identity,
                    !currentPolicy.audiences.isEmpty
                else {
                    return .rejected(404, "not found")
                }
                guard currentPolicy.audiences.contains(audience) else {
                    return .rejected(403, "audience is not allowed")
                }
                logger.warning(
                    "Could not mint a guest identity",
                    metadata: [
                        "networkId": .string(snapshot.networkId.uuidString),
                        "strato.vm.id": .string(vmId.uuidString),
                        "audience": .string(audience),
                        "error": .string("\(error)"),
                    ])
                return .rejected(
                    503, "identity is temporarily unavailable", headers: [.init("retry-after", "2")])
            }
        }

        guard case .document(let path) = route else { return .rejected(404, "not found") }
        guard let metadata = byVM[vmId], let body = MetadataDocument.render(path, for: metadata) else {
            // A key that exists in the tree but not for this instance — a
            // hostname-less VM. 404 rather than an empty 200: nothing here may
            // invent a value (`InstanceMetadata.hostname`).
            return .rejected(404, "not found")
        }
        return MetadataResponse(status: 200, body: body)
    }

    /// Compares the fixed-size capability without exposing a useful matching
    /// prefix through request timing. Bootstrap is rare, so the small temporary
    /// byte arrays are preferable to introducing a second token-store API.
    private static func seedTokenMatches(_ presented: UUID, expected: UUID?) -> Bool {
        guard let expected else { return false }
        let presentedBytes = Array(presented.uuidString.utf8)
        let expectedBytes = Array(expected.uuidString.utf8)
        guard presentedBytes.count == expectedBytes.count else { return false }

        var difference: UInt8 = 0
        for index in presentedBytes.indices {
            difference |= presentedBytes[index] ^ expectedBytes[index]
        }
        return difference == 0
    }
}
