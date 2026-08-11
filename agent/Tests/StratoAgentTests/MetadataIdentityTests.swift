import Foundation
import Logging
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentCore

@Suite("Metadata Guest Identity Tests")
struct MetadataIdentityTests {
    private enum MintFailure: Error { case unavailable }

    private enum MintOutcome: Sendable {
        case token(GuestJWTSVIDResponse)
        case failure
    }

    private actor ScriptedMinter {
        private var outcomes: [MintOutcome]
        private(set) var requests: [(UUID, String, Int)] = []

        init(_ outcomes: [MintOutcome]) { self.outcomes = outcomes }

        func mint(vmId: UUID, audience: String, ttlSeconds: Int) throws -> GuestJWTSVIDResponse {
            requests.append((vmId, audience, ttlSeconds))
            guard !outcomes.isEmpty else { throw MintFailure.unavailable }
            switch outcomes.removeFirst() {
            case .token(let response): return response
            case .failure: throw MintFailure.unavailable
            }
        }

        var requestCount: Int { requests.count }
    }

    private static let networkId = UUID()
    private static let source = "10.0.0.5"
    private static let audience = "spiffe://strato.local/control-plane"

    private static func instance(
        vmId: UUID,
        identity: IdentityPolicy?
    ) -> InstanceMetadata {
        InstanceMetadata(
            instanceId: vmId,
            projectId: UUID(),
            nics: [
                MetadataNIC(
                    deviceName: "net0", macAddress: "52:54:00:00:00:01",
                    networkId: networkId, networkName: "tenant",
                    ipAddress: source, prefixLength: 24)
            ],
            identity: identity,
            serviceEnabled: true)
    }

    private static func request(
        _ method: String,
        _ target: String,
        token: String? = nil
    ) -> MetadataRequest {
        var headers: [(name: String, value: String)] = []
        if let token { headers.append((MetadataHeaderName.token, token)) }
        return MetadataRequest(
            method: method, target: target, headers: MetadataHeaders(headers),
            source: MetadataCallerAddress(source)!)
    }

    private static func session(
        from responder: MetadataResponder,
        at now: ContinuousClock.Instant
    ) async -> String {
        await responder.respond(
            to: MetadataRequest(
                method: "PUT", target: MetadataRouter.tokenPath,
                headers: MetadataHeaders([(MetadataHeaderName.tokenTTL, "600")]),
                source: MetadataCallerAddress(source)!),
            at: now
        ).body
    }

    private static func endpoint(_ audience: String = audience) -> String {
        let encoded = audience.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        return "\(MetadataRouter.identityPath)?audience=\(encoded)"
    }

    private static func token(
        _ value: String,
        vmId: UUID,
        issuedAt: Date,
        expiresAt: Date
    ) -> GuestJWTSVIDResponse {
        GuestJWTSVIDResponse(
            token: value,
            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)",
            audiences: [audience],
            expiresAt: expiresAt,
            issuedAt: issuedAt)
    }

    @Test("A valid IMDSv2 session is required")
    func sessionIsRequired() async {
        let vmId = UUID()
        let minter = ScriptedMinter([])
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [
                    Self.instance(
                        vmId: vmId,
                        identity: IdentityPolicy(
                            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)",
                            audiences: [Self.audience], ttlSeconds: 900))
                ]),
            identityMinter: GuestIdentityMinter { vmId, audience, ttl in
                try await minter.mint(vmId: vmId, audience: audience, ttlSeconds: ttl)
            },
            logger: Logger(label: "test"))

        let response = await responder.respond(
            to: Self.request("GET", Self.endpoint()), at: .now)
        #expect(response.status == 401)
        #expect(await minter.requestCount == 0)
    }

    @Test("An audience outside the VM policy is rejected before minting")
    func audienceAllowlistIsEnforced() async {
        let vmId = UUID()
        let minter = ScriptedMinter([])
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [
                    Self.instance(
                        vmId: vmId,
                        identity: IdentityPolicy(
                            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)",
                            audiences: [Self.audience], ttlSeconds: 900))
                ]),
            identityMinter: GuestIdentityMinter { vmId, audience, ttl in
                try await minter.mint(vmId: vmId, audience: audience, ttlSeconds: ttl)
            },
            logger: Logger(label: "test"))
        let now = ContinuousClock.now
        let session = await Self.session(from: responder, at: now)

        let response = await responder.respond(
            to: Self.request("GET", Self.endpoint("https://untrusted.example"), token: session),
            at: now)
        #expect(response.status == 403)
        #expect(await minter.requestCount == 0)
    }

    @Test("Identity-disabled VMs receive the same 404 as an unknown surface")
    func disabledIdentityIsHidden() async {
        let vmId = UUID()
        let minter = ScriptedMinter([])
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [
                    Self.instance(
                        vmId: vmId,
                        identity: IdentityPolicy(
                            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)"))
                ]),
            identityMinter: GuestIdentityMinter { vmId, audience, ttl in
                try await minter.mint(vmId: vmId, audience: audience, ttlSeconds: ttl)
            },
            logger: Logger(label: "test"))
        let now = ContinuousClock.now
        let session = await Self.session(from: responder, at: now)

        let response = await responder.respond(
            to: Self.request("GET", Self.endpoint(), token: session), at: now)
        #expect(response.status == 404)
        #expect(await minter.requestCount == 0)
    }

    @Test("Tokens refresh at half-life and a failed refresh serves the still-valid token")
    func refreshAndFallback() async {
        let vmId = UUID()
        let wallStart = Date(timeIntervalSince1970: 2_000_000_000)
        let first = Self.token(
            "token-a", vmId: vmId, issuedAt: wallStart,
            expiresAt: wallStart.addingTimeInterval(300))
        let secondIssued = wallStart.addingTimeInterval(151)
        let second = Self.token(
            "token-b", vmId: vmId, issuedAt: secondIssued,
            expiresAt: secondIssued.addingTimeInterval(300))
        let minter = ScriptedMinter([.token(first), .token(second), .failure])
        let policy = IdentityPolicy(
            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)",
            audiences: [Self.audience], ttlSeconds: 900)
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [Self.instance(vmId: vmId, identity: policy)]),
            identityMinter: GuestIdentityMinter { vmId, audience, ttl in
                try await minter.mint(vmId: vmId, audience: audience, ttlSeconds: ttl)
            },
            logger: Logger(label: "test"))
        let monotonic = ContinuousClock.now
        let session = await Self.session(from: responder, at: monotonic)
        let request = Self.request("GET", Self.endpoint(), token: session)

        let initial = await responder.respond(to: request, at: monotonic, wallTime: wallStart)
        #expect(initial.body == "token-a")

        // One second beyond A's half-life refreshes while A is still valid.
        let refreshed = await responder.respond(
            to: request, at: monotonic,
            wallTime: wallStart.addingTimeInterval(151))
        #expect(refreshed.body == "token-b")

        // B reaches its half-life; the third mint fails, so B is served rather
        // than turning a transient SPIRE outage into an IMDS error.
        let fallback = await responder.respond(
            to: request, at: monotonic,
            wallTime: wallStart.addingTimeInterval(302))
        #expect(fallback.status == 200)
        #expect(fallback.body == "token-b")
        #expect(await minter.requestCount == 3)
        let requests = await minter.requests
        #expect(requests.map { $0.2 } == [300, 300, 300])
    }

    @Test("A policy change invalidates a still-fresh cached token")
    func policyChangeInvalidatesCache() async {
        let vmId = UUID()
        let wallStart = Date(timeIntervalSince1970: 2_000_000_000)
        let first = Self.token(
            "token-a", vmId: vmId, issuedAt: wallStart,
            expiresAt: wallStart.addingTimeInterval(300))
        let second = Self.token(
            "token-b", vmId: vmId, issuedAt: wallStart.addingTimeInterval(1),
            expiresAt: wallStart.addingTimeInterval(121))
        let minter = ScriptedMinter([.token(first), .token(second)])
        let initialPolicy = IdentityPolicy(
            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)",
            audiences: [Self.audience], ttlSeconds: 900)
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [Self.instance(vmId: vmId, identity: initialPolicy)]),
            identityMinter: GuestIdentityMinter { vmId, audience, ttl in
                try await minter.mint(vmId: vmId, audience: audience, ttlSeconds: ttl)
            },
            logger: Logger(label: "test"))
        let monotonic = ContinuousClock.now
        let session = await Self.session(from: responder, at: monotonic)
        let request = Self.request("GET", Self.endpoint(), token: session)

        let initial = await responder.respond(to: request, at: monotonic, wallTime: wallStart)
        #expect(initial.body == "token-a")

        let tightenedPolicy = IdentityPolicy(
            spiffeId: initialPolicy.spiffeId,
            audiences: initialPolicy.audiences,
            ttlSeconds: 120)
        await responder.update(
            MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [Self.instance(vmId: vmId, identity: tightenedPolicy)]))

        let afterUpdate = await responder.respond(
            to: request, at: monotonic,
            wallTime: wallStart.addingTimeInterval(1))
        #expect(afterUpdate.body == "token-b")
        let requests = await minter.requests
        #expect(requests.map { $0.2 } == [300, 120])
    }

    @Test("A mint response cannot exceed the policy lifetime")
    func policyLifetimeBoundsResponse() async {
        let vmId = UUID()
        let wallStart = Date(timeIntervalSince1970: 2_000_000_000)
        let tooLong = Self.token(
            "too-long", vmId: vmId, issuedAt: wallStart,
            expiresAt: wallStart.addingTimeInterval(121))
        let minter = ScriptedMinter([.token(tooLong)])
        let policy = IdentityPolicy(
            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)",
            audiences: [Self.audience], ttlSeconds: 120)
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [Self.instance(vmId: vmId, identity: policy)]),
            identityMinter: GuestIdentityMinter { vmId, audience, ttl in
                try await minter.mint(vmId: vmId, audience: audience, ttlSeconds: ttl)
            },
            logger: Logger(label: "test"))
        let monotonic = ContinuousClock.now
        let session = await Self.session(from: responder, at: monotonic)

        let response = await responder.respond(
            to: Self.request("GET", Self.endpoint(), token: session),
            at: monotonic,
            wallTime: wallStart)

        #expect(response.status == 503)
        let requests = await minter.requests
        #expect(requests.map { $0.2 } == [120])
    }

    @Test("A token that expires while minting is never served")
    func expiryIsRecheckedAfterMint() async {
        let vmId = UUID()
        let wallStart = Date(timeIntervalSince1970: 2_000_000_000)
        let currentDate = Mutex(wallStart)
        let cache = GuestIdentityTokenCache(
            currentDate: { currentDate.withLock { $0 } })
        let response = Self.token(
            "already-expired", vmId: vmId, issuedAt: wallStart,
            expiresAt: wallStart.addingTimeInterval(1))
        let policy = IdentityPolicy(
            spiffeId: "spiffe://strato.local/vm/\(vmId.uuidString)",
            audiences: [Self.audience], ttlSeconds: 1)
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkId, origin: .live,
                instances: [Self.instance(vmId: vmId, identity: policy)]),
            identityTokens: cache,
            identityMinter: GuestIdentityMinter { _, _, _ in
                currentDate.withLock { $0 = wallStart.addingTimeInterval(2) }
                return response
            },
            logger: Logger(label: "test"))
        let monotonic = ContinuousClock.now
        let session = await Self.session(from: responder, at: monotonic)

        let result = await responder.respond(
            to: Self.request("GET", Self.endpoint(), token: session),
            at: monotonic,
            wallTime: wallStart)

        #expect(result.status == 503)
    }
}
