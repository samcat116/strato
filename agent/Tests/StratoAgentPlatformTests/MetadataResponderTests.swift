import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// The listener's security argument, asserted without a socket, a namespace or
/// a guest. These are the tests STR-56 names.
@Suite("Metadata Responder Tests")
struct MetadataResponderTests {

    // MARK: - Fixtures

    private static let networkA = UUID()
    private static let networkB = UUID()

    private static func instance(
        _ vmId: UUID,
        hostname: String? = nil,
        network: UUID,
        mac: String = "52:54:00:00:00:01",
        ipv4: String? = nil,
        ipv6: String? = nil,
        sshAuthorizedKeys: [String] = [],
        userData: String? = nil,
        noCloudSeedToken: UUID? = nil,
        serviceEnabled: Bool = true
    ) -> InstanceMetadata {
        InstanceMetadata(
            instanceId: vmId,
            hostname: hostname,
            projectId: UUID(),
            nics: [
                MetadataNIC(
                    deviceName: "net0", macAddress: mac, networkId: network, networkName: "tenant",
                    ipAddress: ipv4, prefixLength: ipv4 == nil ? nil : 24,
                    ipv6Address: ipv6, ipv6PrefixLength: ipv6 == nil ? nil : 64)
            ],
            sshAuthorizedKeys: sshAuthorizedKeys,
            userData: userData,
            noCloudSeedToken: noCloudSeedToken,
            serviceEnabled: serviceEnabled)
    }

    private static func responder(
        network: UUID = networkA,
        origin: MetadataSnapshotOrigin = .live,
        instances: [InstanceMetadata]
    ) -> MetadataResponder {
        MetadataResponder(
            snapshot: MetadataSnapshot(networkId: network, origin: origin, instances: instances),
            logger: Logger(label: "test"))
    }

    private static func request(
        _ method: String, _ target: String, from source: String, _ pairs: (String, String)...
    ) -> MetadataRequest {
        MetadataRequest(
            method: method, target: target,
            headers: MetadataHeaders(pairs.map { (name: $0.0, value: $0.1) }),
            source: MetadataCallerAddress(source)!)
    }

    /// Mints a session the way a guest would: PUT, with the TTL header.
    private static func mint(
        _ responder: MetadataResponder, from source: String, ttl: Int = 60,
        at now: ContinuousClock.Instant = .now
    ) async -> MetadataResponse {
        await responder.respond(
            to: request("PUT", "/latest/api/token", from: source, (MetadataHeaderName.tokenTTL, String(ttl))),
            at: now)
    }

    // MARK: - The issue's first demanded test

    @Test("A GET with no token header is refused")
    func getWithoutTokenIsRejected() async {
        let vmId = UUID()
        let responder = Self.responder(instances: [Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")])

        let response = await responder.respond(
            to: Self.request("GET", "/latest/meta-data/instance-id", from: "10.0.0.5"), at: .now)

        #expect(response.status == 401)
        // The refusal must not leak the very thing it refused to serve.
        #expect(!response.body.contains(vmId.uuidString))
    }

    @Test("NoCloud seed capability serves bootstrap documents without weakening IMDSv2")
    func noCloudSeedCapability() async {
        let vmId = UUID()
        let seedToken = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let responder = Self.responder(instances: [
            Self.instance(
                vmId, hostname: "web-01", network: Self.networkA, ipv4: "10.0.0.5",
                sshAuthorizedKeys: ["ssh-ed25519 AAAA test@example"],
                userData: "#cloud-config\npackages: [nginx]\n",
                noCloudSeedToken: seedToken)
        ])
        let root = MetadataRouter.noCloudSeedPath(for: seedToken)

        let metadata = await responder.respond(
            to: Self.request("GET", root + "meta-data", from: "10.0.0.5"), at: .now)
        let userData = await responder.respond(
            to: Self.request("GET", root + "user-data", from: "10.0.0.5"), at: .now)
        #expect(metadata.status == 200)
        #expect(metadata.body.contains("instance-id: \(vmId.uuidString)"))
        #expect(userData.status == 200)
        #expect(userData.body.contains("packages: [nginx]"))

        // The capability does not turn the ordinary document tree into IMDSv1.
        let ordinary = await responder.respond(
            to: Self.request("GET", "/latest/user-data", from: "10.0.0.5"), at: .now)
        #expect(ordinary.status == 401)

        let wrongRoot = MetadataRouter.noCloudSeedPath(for: UUID())
        let wrong = await responder.respond(
            to: Self.request("GET", wrongRoot + "user-data", from: "10.0.0.5"), at: .now)
        #expect(wrong.status == 404)

        // NoCloud may probe optional filenames. A valid seed capability gets
        // an ordinary 404, not an IMDSv2 challenge it cannot answer.
        let optional = await responder.respond(
            to: Self.request("GET", root + "vendor-data", from: "10.0.0.5"), at: .now)
        #expect(optional.status == 404)
    }

    @Test("NoCloud seed capability remains source-bound and obeys the kill switch")
    func noCloudSeedCapabilityPolicy() async {
        let tokenA = UUID()
        let tokenB = UUID()
        let responder = Self.responder(instances: [
            Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.5", noCloudSeedToken: tokenA),
            Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.6", noCloudSeedToken: tokenB),
            Self.instance(
                UUID(), network: Self.networkA, ipv4: "10.0.0.7",
                noCloudSeedToken: tokenA, serviceEnabled: false),
        ])
        let target = MetadataRouter.noCloudSeedPath(for: tokenA) + "meta-data"

        let neighbour = await responder.respond(
            to: Self.request("GET", target, from: "10.0.0.6"), at: .now)
        #expect(neighbour.status == 404)

        let disabled = await responder.respond(
            to: Self.request("GET", target, from: "10.0.0.7"), at: .now)
        #expect(disabled.status == 404)
    }

    @Test("A token that was never minted, or has expired, is refused")
    func invalidTokensAreRejected() async {
        let vmId = UUID()
        let responder = Self.responder(instances: [Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")])
        let start = ContinuousClock.now

        let never = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5",
                (MetadataHeaderName.token, "not-a-token")),
            at: start)
        #expect(never.status == 401)

        let token = await Self.mint(responder, from: "10.0.0.5", ttl: 60, at: start).body
        let expired = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: start.advanced(by: .seconds(61)))
        #expect(expired.status == 401)

        // Still valid a second before it lapses, so the refusal above is expiry
        // and not something else.
        let live = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: start.advanced(by: .seconds(59)))
        #expect(live.status == 200)
    }

    // MARK: - The issue's second demanded test

    @Test("A token minted via GET rather than PUT is refused")
    func tokenMintedByGETIsRejected() async {
        let vmId = UUID()
        let tokens = MetadataTokenStore()
        let responder = MetadataResponder(
            snapshot: MetadataSnapshot(
                networkId: Self.networkA, origin: .live,
                instances: [Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")]),
            tokens: tokens, logger: Logger(label: "test"))

        let attempted = await responder.respond(
            to: Self.request(
                "GET", "/latest/api/token", from: "10.0.0.5", (MetadataHeaderName.tokenTTL, "60")),
            at: .now)
        #expect(attempted.status == 405)
        #expect(attempted.header("allow") == "PUT")

        // Nothing was minted — asserting only on the 405 would pass against an
        // implementation that mints and then throws the token away.
        #expect(await tokens.liveTokenCount() == 0)

        // And whatever that response said is not a credential.
        let replayed = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5",
                (MetadataHeaderName.token, attempted.body)),
            at: .now)
        #expect(replayed.status == 401)
    }

    // MARK: - The issue's third demanded test

    @Test("A caller cannot read another instance's metadata on the same network")
    func oneCallerCannotReadAnother() async {
        let vmA = UUID()
        let vmB = UUID()
        let responder = Self.responder(instances: [
            Self.instance(vmA, network: Self.networkA, mac: "52:54:00:00:00:0a", ipv4: "10.0.0.5"),
            Self.instance(vmB, network: Self.networkA, mac: "52:54:00:00:00:0b", ipv4: "10.0.0.6"),
        ])
        let now = ContinuousClock.now

        let tokenA = await Self.mint(responder, from: "10.0.0.5", at: now).body
        let tokenB = await Self.mint(responder, from: "10.0.0.6", at: now).body

        // Each reads itself, and reads *only* itself.
        let readA = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, tokenA)),
            at: now)
        #expect(readA.status == 200)
        #expect(readA.body == vmA.uuidString)

        let readB = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.6", (MetadataHeaderName.token, tokenB)),
            at: now)
        #expect(readB.body == vmB.uuidString)

        // B presenting A's stolen token gets nothing: the identity is
        // re-derived from the source address every time, and the session has to
        // agree with it.
        let stolen = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.6", (MetadataHeaderName.token, tokenA)),
            at: now)
        #expect(stolen.status == 401)
        #expect(!stolen.body.contains(vmA.uuidString))
    }

    @Test("Overlapping subnets on two networks resolve to different instances")
    func overlappingSubnetsResolveSeparately() async {
        // ADR 0003's motivating case: routers are scoped per project, so two
        // projects may both use 10.0.0.0/24, and one address means two guests.
        let vmA = UUID()
        let vmB = UUID()
        let listenerA = Self.responder(
            network: Self.networkA,
            instances: [Self.instance(vmA, network: Self.networkA, ipv4: "10.0.0.5")])
        let listenerB = Self.responder(
            network: Self.networkB,
            instances: [Self.instance(vmB, network: Self.networkB, ipv4: "10.0.0.5")])
        let now = ContinuousClock.now

        let tokenA = await Self.mint(listenerA, from: "10.0.0.5", at: now).body
        let tokenB = await Self.mint(listenerB, from: "10.0.0.5", at: now).body

        let fromA = await listenerA.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, tokenA)),
            at: now)
        let fromB = await listenerB.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, tokenB)),
            at: now)

        #expect(fromA.body == vmA.uuidString)
        #expect(fromB.body == vmB.uuidString)

        // And neither listener honors the other's session, even though the
        // source address is identical.
        let crossed = await listenerA.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, tokenB)),
            at: now)
        #expect(crossed.status == 401)
    }

    // MARK: - Identification

    @Test("An address this host does not serve gets a 404, not a hint")
    func unknownCallerGets404() async {
        let responder = Self.responder(instances: [
            Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.5")
        ])
        let response = await Self.mint(responder, from: "10.0.0.9")
        #expect(response.status == 404)
    }

    @Test("An address claimed by two instances is refused, never guessed")
    func ambiguousCallerIsRefused() async {
        // Reachable in ordinary operation: a VM is deleted, IPAM hands its
        // address to the next one, and the withdrawal has not landed here yet.
        let responder = Self.responder(instances: [
            Self.instance(UUID(), network: Self.networkA, mac: "52:54:00:00:00:0a", ipv4: "10.0.0.5"),
            Self.instance(UUID(), network: Self.networkA, mac: "52:54:00:00:00:0b", ipv4: "10.0.0.5"),
        ])
        let response = await Self.mint(responder, from: "10.0.0.5")
        #expect(response.status == 404)
    }

    @Test("A withdrawn instance is unreachable even from its own address")
    func withdrawnInstanceIsUnreachable() async {
        let vmId = UUID()
        let responder = Self.responder(instances: [
            Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")
        ])
        let now = ContinuousClock.now
        let token = await Self.mint(responder, from: "10.0.0.5", at: now).body

        // The VM leaves this host: MetadataStore.snapshot() omits it, so the
        // next push simply does not list it.
        await responder.update(
            MetadataSnapshot(networkId: Self.networkA, origin: .live, instances: []))

        let response = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: now)
        // 404 at identification — the address no longer names an instance this
        // host serves, which is what stops a released VM's metadata reaching
        // whoever next holds its address.
        #expect(response.status == 404)
    }

    // MARK: - The per-instance kill switch (STR-185)

    @Test("A switched-off instance cannot even mint a token")
    func killSwitchRefusesTheHandshake() async {
        let responder = Self.responder(instances: [
            Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.5", serviceEnabled: false)
        ])
        let response = await Self.mint(responder, from: "10.0.0.5")
        // Refused before the handshake, so a guest cannot make this process
        // hold a session it could never spend.
        #expect(response.status == 404)
    }

    @Test("A switched-off instance is refused with the same answer an unknown address gets")
    func killSwitchIsIndistinguishableFromUnknown() async {
        let off = Self.responder(instances: [
            Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.5", serviceEnabled: false)
        ])
        let unknown = Self.responder(instances: [
            Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.6")
        ])
        let refused = await off.respond(
            to: Self.request("GET", "/latest/meta-data/instance-id", from: "10.0.0.5"), at: .now)
        let missing = await unknown.respond(
            to: Self.request("GET", "/latest/meta-data/instance-id", from: "10.0.0.5"), at: .now)
        // Byte for byte: a guest must not be able to learn that it was singled
        // out, only that nothing answers.
        #expect(refused.status == missing.status)
        #expect(refused.body == missing.body)
    }

    @Test("Throwing the switch retires the session the guest already holds")
    func killSwitchRevokesLiveSessions() async {
        let vmId = UUID()
        let responder = Self.responder(instances: [
            Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")
        ])
        let now = ContinuousClock.now
        let token = await Self.mint(responder, from: "10.0.0.5", at: now).body

        // An operator throws the switch; the next sync carries the same
        // document with `serviceEnabled: false`.
        await responder.update(
            MetadataSnapshot(
                networkId: Self.networkA, origin: .live,
                instances: [
                    Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5", serviceEnabled: false)
                ]))

        let response = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: now)
        #expect(response.status == 404)

        // …and turning it back on does not resurrect the old token: the switch
        // retired it, so the guest has to mint again.
        await responder.update(
            MetadataSnapshot(
                networkId: Self.networkA, origin: .live,
                instances: [Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")]))
        let afterRestore = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: now)
        #expect(afterRestore.status == 401)
    }

    @Test("A switched-off instance still shadows a colliding address rather than yielding it")
    func killSwitchKeepsTheCollisionDetectable() async {
        // The reason the switch is a refusal rather than an omission: were the
        // switched-off instance dropped from the servable set, `10.0.0.5` would
        // resolve cleanly to its neighbour, and the hardened workload could read
        // that neighbour's identity from the address they share.
        let neighbour = UUID()
        let responder = Self.responder(instances: [
            Self.instance(
                UUID(), network: Self.networkA, mac: "52:54:00:00:00:0a", ipv4: "10.0.0.5",
                serviceEnabled: false),
            Self.instance(neighbour, network: Self.networkA, mac: "52:54:00:00:00:0b", ipv4: "10.0.0.5"),
        ])
        let response = await Self.mint(responder, from: "10.0.0.5")
        #expect(response.status == 404)
    }

    @Test("A v6 caller is resolved through its allocated address or its EUI-64 link-local")
    func ipv6Callers() async {
        let vmId = UUID()
        let responder = Self.responder(instances: [
            Self.instance(
                vmId, network: Self.networkA, mac: "52:54:00:12:34:56", ipv4: "10.0.0.5",
                ipv6: "fd12:3456:789a::5")
        ])
        let now = ContinuousClock.now

        // Non-canonical spelling of the same address still resolves.
        let global = await Self.mint(responder, from: "FD12:3456:789A:0:0:0:0:5", at: now)
        #expect(global.status == 200)

        let linkLocal = IPv6Address.linkLocalEUI64(fromMAC: "52:54:00:12:34:56")!
        let fromLinkLocal = await Self.mint(responder, from: linkLocal.description, at: now)
        #expect(fromLinkLocal.status == 200)
    }

    // MARK: - Cold start

    @Test("A host that knows nothing yet answers 503, not 404 and not an empty 200")
    func coldStartIsNotAnAnswer() async {
        let vmId = UUID()
        let cold = Self.responder(
            origin: .cold, instances: [Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")])

        // Both verbs, and for an address that *would* resolve: with no
        // knowledge, 404 would assert something the agent cannot know.
        let read = await cold.respond(
            to: Self.request("GET", "/latest/meta-data/instance-id", from: "10.0.0.5"), at: .now)
        #expect(read.status == 503)
        #expect(read.header("retry-after") == "2")

        let mint = await Self.mint(cold, from: "10.0.0.5")
        #expect(mint.status == 503)
    }

    @Test("Restored knowledge answers like live knowledge")
    func restoredSnapshotServes() async {
        let vmId = UUID()
        let responder = Self.responder(
            origin: .restored, instances: [Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")])
        let now = ContinuousClock.now
        let token = await Self.mint(responder, from: "10.0.0.5", at: now).body
        let response = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/instance-id", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: now)
        #expect(response.status == 200)
        #expect(response.body == vmId.uuidString)
    }

    // MARK: - Documents

    @Test("The served tree is exactly what the listing advertises")
    func documentTree() async {
        let vmId = UUID()
        let metadata = Self.instance(
            vmId, hostname: "web-01", network: Self.networkA, ipv4: "10.0.0.5",
            sshAuthorizedKeys: ["ssh-ed25519 AAAA key@host"],
            userData: "#cloud-config\nruncmd:\n  - echo caller\n")
        let responder = Self.responder(instances: [metadata])
        let now = ContinuousClock.now
        let token = await Self.mint(responder, from: "10.0.0.5", at: now).body

        func get(_ target: String) async -> MetadataResponse {
            await responder.respond(
                to: Self.request("GET", target, from: "10.0.0.5", (MetadataHeaderName.token, token)), at: now)
        }

        #expect(await get("/latest/").body == "meta-data\nnetwork-config\nuser-data")
        #expect(await get("/latest/meta-data").body == CloudInitProvisioner.metaDataDocument(for: metadata))
        #expect(
            await get("/latest/meta-data/").body
                == "hostname\ninstance-id\nlocal-hostname\nlocal-ipv4\nmac\nnetwork/\npublic-keys/")
        #expect(await get("/latest/meta-data/instance-id").body == vmId.uuidString)
        #expect(await get("/latest/meta-data/hostname").body == "web-01")
        #expect(await get("/latest/meta-data/local-hostname").body == "web-01")
        #expect(await get("/latest/meta-data/local-ipv4").body == "10.0.0.5")
        #expect(await get("/latest/meta-data/public-keys/0/openssh-key").body == "ssh-ed25519 AAAA key@host")
        #expect(await get("/latest/user-data").body == CloudInitProvisioner.userDataDocument(for: metadata))
        #expect(await get("/latest/network-config").body == CloudInitProvisioner.networkConfigYAML(for: metadata))
    }

    @Test("An absent NoCloud network-config is a 404 and is not advertised")
    func absentNetworkConfig() async {
        let metadata = Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.5")
        let withoutAddressing = InstanceMetadata(
            instanceId: metadata.instanceId,
            projectId: metadata.projectId,
            nics: [
                MetadataNIC(
                    deviceName: "net0", macAddress: metadata.nics[0].macAddress,
                    networkId: Self.networkA, networkName: "tenant",
                    ipAddress: "10.0.0.5")
            ],
            serviceEnabled: true)
        let responder = Self.responder(instances: [withoutAddressing])
        let now = ContinuousClock.now
        let token = await Self.mint(responder, from: "10.0.0.5", at: now).body

        func get(_ target: String) async -> MetadataResponse {
            await responder.respond(
                to: Self.request("GET", target, from: "10.0.0.5", (MetadataHeaderName.token, token)), at: now)
        }

        #expect(await get("/latest/").body == "meta-data\nuser-data")
        #expect(await get("/latest/network-config").status == 404)
    }

    @Test("A hostname-less instance 404s rather than inventing one")
    func hostnameIsNeverInvented() async {
        let vmId = UUID()
        let responder = Self.responder(instances: [
            Self.instance(vmId, network: Self.networkA, ipv4: "10.0.0.5")
        ])
        let now = ContinuousClock.now
        let token = await Self.mint(responder, from: "10.0.0.5", at: now).body

        let hostname = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/hostname", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: now)
        #expect(hostname.status == 404)

        // And the listing does not advertise a key it cannot answer.
        let listing = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: now)
        #expect(listing.body == "instance-id\nlocal-ipv4\nmac\nnetwork/")
    }

    @Test("An unserved path 404s only after authentication")
    func unknownPathNeedsASessionFirst() async {
        // Otherwise anything that can reach the address maps the tree without
        // ever holding a session.
        let responder = Self.responder(instances: [
            Self.instance(UUID(), network: Self.networkA, ipv4: "10.0.0.5")
        ])
        let now = ContinuousClock.now

        let unauthenticated = await responder.respond(
            to: Self.request("GET", "/latest/meta-data/ami-id", from: "10.0.0.5"), at: now)
        #expect(unauthenticated.status == 401)

        let token = await Self.mint(responder, from: "10.0.0.5", at: now).body
        let authenticated = await responder.respond(
            to: Self.request(
                "GET", "/latest/meta-data/ami-id", from: "10.0.0.5", (MetadataHeaderName.token, token)),
            at: now)
        #expect(authenticated.status == 404)
    }
}
