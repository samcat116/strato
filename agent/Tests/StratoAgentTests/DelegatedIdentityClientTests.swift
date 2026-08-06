import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import Testing
import X509

@testable import StratoAgentSPIFFE

/// Tests for the SPIRE Delegated Identity client (STR-16): selector parsing,
/// the response-shape differences from the Workload API, streaming behaviour
/// against an in-process fake admin API over a Unix domain socket, and the
/// probe's four outcomes.
@Suite("SPIRE Delegated Identity Client")
struct DelegatedIdentityClientTests {

    private static let testLogger = Logger(label: "test.delegated-identity")
    private static let guestPath = "/vm/11111111-1111-1111-1111-111111111111"
    private static let guestSelectors = [
        DelegatedSelector(type: "strato", value: "instance:11111111-1111-1111-1111-111111111111"),
        DelegatedSelector(type: "strato", value: "kind:vm"),
    ]

    // MARK: - Selector parsing

    @Test("Parses a selector on the first colon only")
    func parsesSelectorOnFirstColon() throws {
        let selector = try #require(DelegatedSelector("strato:instance:a:b"))
        #expect(selector.type == "strato")
        #expect(selector.value == "instance:a:b")
        #expect(selector.description == "strato:instance:a:b")
        // Round-trips, so a probe's echoed selectors are the ones it sent
        #expect(DelegatedSelector(selector.description) == selector)
    }

    @Test(
        "Rejects selectors with no colon or an empty side",
        arguments: ["nocolon", ":value", "type:", ""])
    func rejectsMalformedSelectors(text: String) {
        #expect(DelegatedSelector(text) == nil)
    }

    // MARK: - Response conversion

    @Test("Converts a delegated response with an already-split certificate chain")
    func convertsDelegatedResponse() throws {
        let pki = try SPIFFETestPKI()
        let expiry = Date().addingTimeInterval(1800)
        let response = try pki.makeDelegatedSVIDResponse(
            trustDomain: "strato.local",
            path: Self.guestPath,
            notValidAfter: expiry,
            federatesWith: ["org-abc.strato.local"]
        )

        let svids = try DelegatedIdentityConversion.makeSVIDs(from: response)
        #expect(svids.count == 1)
        let svid = try #require(svids.first)

        // The SPIFFE ID comes from a {trust_domain, path} message, not a URI
        #expect(svid.spiffeID.uri == "spiffe://strato.local\(Self.guestPath)")
        #expect(svid.spiffeID.trustDomain == "strato.local")

        // cert_chain is `repeated bytes` — one PEM block per element, leaf
        // first, and each must survive a real X.509 parser
        #expect(svid.certificateChain.count == 2)
        for pem in svid.certificateChain {
            #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
            _ = try Certificate(pemEncoded: pem)
        }
        let leaf = try Certificate(pemEncoded: svid.certificateChain[0])
        #expect(abs(leaf.notValidAfter.timeIntervalSince(expiry)) < 2)

        #expect(svid.privateKey.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        #expect(abs(svid.expiresAt.timeIntervalSince(expiry)) < 2)
        #expect(svid.federatesWith == ["org-abc.strato.local"])
        #expect(svid.hint == nil)
    }

    @Test("An empty SVID set converts to [] rather than throwing")
    func emptyResponseIsEmptyArray() throws {
        // This is how SPIRE signals revocation: the entry is gone, so the
        // stream pushes an empty set. Treating it as an error would turn "tear
        // this identity down now" into a retry loop.
        let response = Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse()
        #expect(try DelegatedIdentityConversion.makeSVIDs(from: response).isEmpty)
    }

    @Test("A non-certificate chain element raises parseError")
    func malformedChainThrows() {
        var svid = Spire_Api_Types_X509SVID()
        var id = Spire_Api_Types_SPIFFEID()
        id.trustDomain = "strato.local"
        id.path = Self.guestPath
        svid.id = id
        svid.certChain = [Data([0x30, 0x03, 0x02, 0x01, 0x00])]  // a SEQUENCE, not a cert

        var withKey = Spire_Api_Agent_Delegatedidentity_V1_X509SVIDWithKey()
        withKey.x509Svid = svid
        var response = Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse()
        response.x509Svids = [withKey]

        #expect(throws: SPIFFEError.self) {
            _ = try DelegatedIdentityConversion.makeSVIDs(from: response)
        }
    }

    /// SPIRE 1.9.6 writes `caCerts[td.IDString()]` even though the proto
    /// comment promises a bare trust domain name — verified against a real
    /// spire-agent, which returned `spiffe://strato.local`. Both forms must
    /// normalize to the bare name, because that is what a parsed
    /// `SPIFFEIdentity.trustDomain` can look up.
    @Test(
        "Bundle keys normalize to the bare trust domain name in either wire form",
        arguments: [false, true])
    func normalizesBundleKeys(keyByBareName: Bool) throws {
        let pki = try SPIFFETestPKI()
        let response = pki.makeDelegatedBundlesResponse(
            trustDomains: ["strato.local"], keyByBareName: keyByBareName)

        let bundles = try DelegatedIdentityConversion.makeTrustBundles(from: response)
        #expect(bundles["spiffe://strato.local"] == nil)
        let bundle = try #require(bundles["strato.local"])
        #expect(bundle.trustDomain == "strato.local")
        #expect(bundle.x509Authorities.count == 1)
        #expect(bundle.x509Authorities[0].hasPrefix("-----BEGIN CERTIFICATE-----"))
    }

    @Test("Composing an SVID with bundles carries only the federated domains it names")
    func composesWithBundles() throws {
        let pki = try SPIFFETestPKI()
        let response = try pki.makeDelegatedSVIDResponse(
            trustDomain: "strato.local",
            path: Self.guestPath,
            notValidAfter: Date().addingTimeInterval(1800),
            federatesWith: ["org-abc.strato.local"]
        )
        let delegated = try #require(try DelegatedIdentityConversion.makeSVIDs(from: response).first)
        let bundles = try DelegatedIdentityConversion.makeTrustBundles(
            from: pki.makeDelegatedBundlesResponse(
                trustDomains: ["strato.local", "org-abc.strato.local", "unrelated.example"]))

        let svid = try delegated.withBundles(bundles)
        #expect(svid.trustBundle.count == 1)
        #expect(svid.roots(forTrustDomain: "org-abc.strato.local")?.count == 1)
        // A domain the entry does not federate with must not become a root, or
        // any federated CA could vouch for a peer in any other domain.
        #expect(svid.roots(forTrustDomain: "unrelated.example") == nil)
    }

    // MARK: - Against a fake Delegated Identity server

    @Test("Fetches a guest SVID over the admin socket", .timeLimit(.minutes(1)))
    func fetchesGuestSVID() async throws {
        let pki = try SPIFFETestPKI()
        let expiry = Date().addingTimeInterval(1800)
        let response = try pki.makeDelegatedSVIDResponse(
            trustDomain: "strato.local", path: Self.guestPath, notValidAfter: expiry)

        try await withFakeDelegatedIdentityAPI(
            responses: [response],
            expectedSelectors: Self.guestSelectors
        ) { socketPath in
            let client = DelegatedIdentitySPIFFEClient(
                socketPath: socketPath, logger: Self.testLogger)
            let svids = try await client.fetchX509SVIDs(selectors: Self.guestSelectors)
            #expect(svids.count == 1)
            #expect(svids.first?.spiffeID.uri == "spiffe://strato.local\(Self.guestPath)")
            #expect(abs((svids.first?.expiresAt ?? .distantPast).timeIntervalSince(expiry)) < 2)
            await client.close()
        }
    }

    @Test("The probe reports OK end to end against a live socket", .timeLimit(.minutes(1)))
    func probeReportsOKEndToEnd() async throws {
        let pki = try SPIFFETestPKI()
        let response = try pki.makeDelegatedSVIDResponse(
            trustDomain: "strato.local",
            path: Self.guestPath,
            notValidAfter: Date().addingTimeInterval(3540))

        try await withFakeDelegatedIdentityAPI(
            responses: [response],
            expectedSelectors: Self.guestSelectors,
            bundles: pki.makeDelegatedBundlesResponse(trustDomains: ["strato.local"])
        ) { socketPath in
            let client = DelegatedIdentitySPIFFEClient(
                socketPath: socketPath, logger: Self.testLogger)
            let report = await DelegatedIdentityProbe.probe(
                client: client, selectors: Self.guestSelectors)

            #expect(report.outcome == .ok)
            #expect(report.succeeded)
            #expect(report.socketPresent)
            #expect(report.identities.count == 1)
            #expect(report.identities[0].spiffeID == "spiffe://strato.local\(Self.guestPath)")
            #expect(report.trustDomains["strato.local"] == 1)
            await client.close()
        }
    }

    @Test("The watch stream delivers rotation and then revocation", .timeLimit(.minutes(1)))
    func watchDeliversRotationThenRevocation() async throws {
        let pki = try SPIFFETestPKI()
        let firstExpiry = Date().addingTimeInterval(600)
        let secondExpiry = Date().addingTimeInterval(3600)
        let responses = [
            try pki.makeDelegatedSVIDResponse(
                trustDomain: "strato.local", path: Self.guestPath, notValidAfter: firstExpiry),
            try pki.makeDelegatedSVIDResponse(
                trustDomain: "strato.local", path: Self.guestPath, notValidAfter: secondExpiry),
            // Entry deleted: SPIRE pushes an empty set rather than ending the
            // stream. This is revocation, and it must reach the consumer.
            Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse(),
        ]

        try await withFakeDelegatedIdentityAPI(
            responses: responses, pauseBetween: .milliseconds(50)
        ) { socketPath in
            let client = DelegatedIdentitySPIFFEClient(
                socketPath: socketPath,
                logger: Self.testLogger,
                watchRetryDelay: .milliseconds(100)
            )

            var iterator = client.watchX509SVIDs(selectors: Self.guestSelectors).makeAsyncIterator()
            let first = try #require(await iterator.next())
            let second = try #require(await iterator.next())
            let third = try #require(await iterator.next())

            #expect(abs((first.first?.expiresAt ?? .distantPast).timeIntervalSince(firstExpiry)) < 2)
            #expect(
                abs((second.first?.expiresAt ?? .distantPast).timeIntervalSince(secondExpiry)) < 2)
            #expect(third.isEmpty)
            await client.close()
        }
    }

    @Test("The request carries no workload.spiffe.io security header", .timeLimit(.minutes(1)))
    func sendsNoSecurityHeader() async throws {
        let pki = try SPIFFETestPKI()
        let response = try pki.makeDelegatedSVIDResponse(
            trustDomain: "strato.local",
            path: Self.guestPath,
            notValidAfter: Date().addingTimeInterval(600))

        // The SPIRE agent enforces that header only for `/SpiffeWorkloadAPI/`
        // methods; the fake refuses the call if the delegated client sends it.
        try await withFakeDelegatedIdentityAPI(
            responses: [response], rejectSecurityHeader: true
        ) { socketPath in
            let client = DelegatedIdentitySPIFFEClient(
                socketPath: socketPath, logger: Self.testLogger)
            let svids = try await client.fetchX509SVIDs(selectors: Self.guestSelectors)
            #expect(svids.count == 1)
            await client.close()
        }
    }

    @Test("PermissionDenied becomes delegateNotAuthorized", .timeLimit(.minutes(1)))
    func permissionDeniedMapsToDelegateNotAuthorized() async throws {
        try await withFakeDelegatedIdentityAPI(
            responses: [],
            failure: RPCError(
                code: .permissionDenied, message: "caller not configured as an authorized delegate")
        ) { socketPath in
            let client = DelegatedIdentitySPIFFEClient(
                socketPath: socketPath, logger: Self.testLogger)
            do {
                _ = try await client.fetchX509SVIDs(selectors: Self.guestSelectors)
                Issue.record("Expected the refusal to surface")
            } catch let error as SPIFFEError {
                guard case .delegateNotAuthorized = error else {
                    Issue.record("Expected delegateNotAuthorized, got \(error)")
                    return
                }
                // The message is the whole operator experience of this failure
                let description = try #require(error.errorDescription)
                #expect(description.contains("authorized_delegates"))
                #expect(description.contains("/etc/spire/agent.conf"))
            }
            await client.close()
        }
    }

    @Test("A missing admin socket raises workloadAPIUnavailable")
    func missingSocketThrows() async {
        let client = DelegatedIdentitySPIFFEClient(
            socketPath: "/tmp/strato-di-absent-\(UUID().uuidString.prefix(8)).sock",
            logger: Self.testLogger
        )
        await #expect(throws: SPIFFEError.self) {
            _ = try await client.fetchX509SVIDs(selectors: Self.guestSelectors)
        }
    }

    // MARK: - Socket path resolution

    @Test("Resolves the admin socket from the override, then the environment, then the default")
    func resolvesSocketPath() {
        let environment = ["SPIRE_ADMIN_ENDPOINT_SOCKET": "/env/admin.sock"]
        #expect(
            DelegatedIdentitySPIFFEClient.resolveSocketPath(
                override: "/flag/admin.sock", environment: environment) == "/flag/admin.sock")
        #expect(
            DelegatedIdentitySPIFFEClient.resolveSocketPath(
                override: nil, environment: environment) == "/env/admin.sock")
        #expect(
            DelegatedIdentitySPIFFEClient.resolveSocketPath(override: nil, environment: [:])
                == DelegatedIdentitySPIFFEClient.defaultAdminSocketPath)
        // The default must not sit under the Workload API socket's directory,
        // which spire-agent refuses to start with.
        #expect(
            !DelegatedIdentitySPIFFEClient.defaultAdminSocketPath.hasPrefix(
                "/var/run/spire/sockets/"))
    }

    // MARK: - Probe reporting

    @Test("A successful report names the identity and never prints the key")
    func formatsSuccessWithoutLeakingKey() throws {
        let pki = try SPIFFETestPKI()
        let response = try pki.makeDelegatedSVIDResponse(
            trustDomain: "strato.local",
            path: Self.guestPath,
            notValidAfter: Date().addingTimeInterval(3540))
        let svid = try #require(try DelegatedIdentityConversion.makeSVIDs(from: response).first)

        let report = DelegatedIdentityProbe.Report(
            socketPath: "/var/run/spire/admin.sock",
            socketPresent: true,
            selectors: Self.guestSelectors.map(\.description),
            identities: [DelegatedIdentityProbe.makeIdentityReport(svid)],
            trustDomains: ["strato.local": 1],
            outcome: .ok
        )

        #expect(report.succeeded)
        let output = DelegatedIdentityProbe.format(report)
        #expect(output.contains("spiffe://strato.local\(Self.guestPath)"))
        #expect(output.contains("not printed"))
        #expect(output.contains("DELEGATED IDENTITY OK"))
        #expect(output.contains("1 X.509 authority"))
        #expect(!output.contains("BEGIN PRIVATE KEY"))

        // The key material must not survive into the report at all, only its
        // length — so no formatter can leak what it was never given.
        let keyBody = svid.privateKey.split(separator: "\n").filter { !$0.hasPrefix("-----") }
            .joined()
        #expect(!output.contains(keyBody))
        #expect(report.identities[0].privateKeyDERByteCount > 0)
        #expect(
            report.identities[0].privateKeyDERByteCount
                == DelegatedIdentityProbe.derByteCount(pem: svid.privateKey))
    }

    @Test("Zero identities with no error reports NO ENTRY MATCHED, not success")
    func formatsNoEntryMatched() {
        let report = DelegatedIdentityProbe.Report(
            socketPath: "/var/run/spire/admin.sock",
            socketPresent: true,
            selectors: ["strato:instance:missing"],
            outcome: .noEntryMatched
        )

        #expect(!report.succeeded)
        let output = DelegatedIdentityProbe.format(report)
        #expect(output.contains("NO ENTRY MATCHED"))
        #expect(output.contains("parentID"))
        #expect(!output.contains("DELEGATED IDENTITY OK"))
    }

    @Test("A refusal report names authorized_delegates")
    func formatsRefusal() {
        let report = DelegatedIdentityProbe.Report(
            socketPath: "/var/run/spire/admin.sock",
            socketPresent: true,
            selectors: ["strato:instance:x"],
            outcome: .refused,
            detail: SPIFFEError.delegateNotAuthorized("caller not configured as an authorized delegate")
                .localizedDescription
        )

        #expect(!report.succeeded)
        let output = DelegatedIdentityProbe.format(report)
        #expect(output.contains("DELEGATED IDENTITY REFUSED"))
        #expect(output.contains("authorized_delegates"))
    }

    @Test("An unavailable report points at admin_socket_path")
    func formatsUnavailable() throws {
        let report = DelegatedIdentityProbe.Report(
            socketPath: "/var/run/spire/admin.sock",
            socketPresent: false,
            selectors: ["strato:instance:x"],
            outcome: .unavailable
        )

        let output = DelegatedIdentityProbe.format(report)
        #expect(output.contains("(absent)"))
        #expect(output.contains("DELEGATED IDENTITY UNAVAILABLE"))
        #expect(output.contains("admin_socket_path"))

        let json = try DelegatedIdentityProbe.formatJSON(report)
        #expect(json.contains("\"outcome\" : \"unavailable\""))
        #expect(json.contains("\"succeeded\" : false"))
    }

    @Test("Probing an unreachable socket reports unavailable rather than throwing")
    func probeReportsUnavailable() async {
        let client = DelegatedIdentitySPIFFEClient(
            socketPath: "/tmp/strato-di-absent-\(UUID().uuidString.prefix(8)).sock",
            logger: Self.testLogger
        )
        let report = await DelegatedIdentityProbe.probe(
            client: client, selectors: Self.guestSelectors)
        #expect(report.outcome == .unavailable)
        #expect(!report.socketPresent)
        #expect(!report.succeeded)
    }

    // MARK: - Fake server plumbing

    /// Run `body` with a fake Delegated Identity gRPC server on a fresh Unix
    /// domain socket. Each SubscribeToX509SVIDs call streams `responses` in
    /// order; SubscribeToX509Bundles serves the CA for `strato.local`.
    private func withFakeDelegatedIdentityAPI(
        responses: [Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse],
        pauseBetween: Duration = .zero,
        expectedSelectors: [DelegatedSelector]? = nil,
        rejectSecurityHeader: Bool = false,
        failure: RPCError? = nil,
        bundles: Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse =
            Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse(),
        _ body: @Sendable @escaping (String) async throws -> Void
    ) async throws {
        // Keep the path short: UDS paths have a ~104 byte limit
        let socketPath = "/tmp/strato-di-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let service = FakeDelegatedIdentityService(
            responses: responses,
            pauseBetween: pauseBetween,
            expectedSelectors: expectedSelectors?.map(\.description).sorted(),
            rejectSecurityHeader: rejectSecurityHeader,
            failure: failure,
            bundles: bundles
        )

        try await withGRPCServer(transport: transport, services: [service]) { _ in
            _ = try await transport.listeningAddress
            try await body(socketPath)
        }
    }
}

// MARK: - Fake Delegated Identity service

/// Minimal `spire.api.agent.delegatedidentity.v1.DelegatedIdentity`
/// implementation.
private struct FakeDelegatedIdentityService: RegistrableRPCService {
    let responses: [Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse]
    let pauseBetween: Duration
    /// When set, the call fails unless the client sent exactly these selectors —
    /// the check that proves Strato's synthetic selector type survives the wire.
    let expectedSelectors: [String]?
    let rejectSecurityHeader: Bool
    let failure: RPCError?
    let bundles: Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse

    private static let service = ServiceDescriptor(
        fullyQualifiedService: "spire.api.agent.delegatedidentity.v1.DelegatedIdentity")

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(service: Self.service, method: "SubscribeToX509SVIDs"),
            deserializer: ProtobufDeserializer<
                Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsRequest
            >(),
            serializer: ProtobufSerializer<
                Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509SVIDsResponse
            >()
        ) { request, _ in
            if let failure = self.failure { throw failure }

            if self.rejectSecurityHeader, request.metadata["workload.spiffe.io"].contains("true") {
                throw RPCError(
                    code: .invalidArgument,
                    message: "the Delegated Identity API takes no workload.spiffe.io header")
            }

            var received: [String] = []
            for try await message in request.messages {
                received = message.selectors.map { "\($0.type):\($0.value)" }.sorted()
                // `pid` and `selectors` are mutually exclusive
                if message.pid != 0 {
                    throw RPCError(code: .invalidArgument, message: "pid and selectors are mutually exclusive")
                }
                break
            }
            if let expected = self.expectedSelectors, received != expected {
                throw RPCError(
                    code: .invalidArgument,
                    message: "selectors \(received) do not match expected \(expected)")
            }

            let responses = self.responses
            let pause = self.pauseBetween
            return StreamingServerResponse { writer in
                for (index, response) in responses.enumerated() {
                    if index > 0 {
                        try await Task.sleep(for: pause)
                    }
                    try await writer.write(response)
                }
                return [:]
            }
        }

        router.registerHandler(
            forMethod: MethodDescriptor(service: Self.service, method: "SubscribeToX509Bundles"),
            deserializer: ProtobufDeserializer<
                Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesRequest
            >(),
            serializer: ProtobufSerializer<
                Spire_Api_Agent_Delegatedidentity_V1_SubscribeToX509BundlesResponse
            >()
        ) { _, _ in
            let bundles = self.bundles
            return StreamingServerResponse { writer in
                try await writer.write(bundles)
                return [:]
            }
        }
    }
}
