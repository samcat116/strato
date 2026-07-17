import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import SwiftProtobuf
import Testing

@testable import SPIREServerAPI

/// Tests for the SPIRE Server registration API gRPC client: address parsing,
/// SPIFFE ID splitting, and the CreateJoinToken / BatchCreateEntry /
/// ListEntries / BatchDeleteEntry round trips against an in-process fake
/// SPIRE server over a Unix domain socket.
@Suite("SPIRE Server API Client Tests")
struct SPIREServerAPIClientTests {

    private static let testLogger = Logger(label: "test.spire-server-api")

    // MARK: - Address parsing

    @Test("Parses unix:// addresses")
    func parsesUnixAddress() throws {
        let address = try SPIREServerAPIAddress(parsing: "unix:///run/spire/server/api.sock")
        #expect(address == .unixSocket(path: "/run/spire/server/api.sock"))
    }

    @Test("Parses tcp:// and bare host:port addresses")
    func parsesTCPAddress() throws {
        let explicit = try SPIREServerAPIAddress(parsing: "tcp://127.0.0.1:8087")
        #expect(explicit == .tcp(host: "127.0.0.1", port: 8087))

        let bare = try SPIREServerAPIAddress(parsing: "spire-server:8081")
        #expect(bare == .tcp(host: "spire-server", port: 8081))
    }

    @Test("Rejects malformed addresses")
    func rejectsMalformedAddresses() {
        #expect(throws: SPIREServerAPIError.self) {
            _ = try SPIREServerAPIAddress(parsing: "unix://relative/path.sock")
        }
        #expect(throws: SPIREServerAPIError.self) {
            _ = try SPIREServerAPIAddress(parsing: "no-port-here")
        }
        #expect(throws: SPIREServerAPIError.self) {
            _ = try SPIREServerAPIAddress(parsing: "host:notaport")
        }
        #expect(throws: SPIREServerAPIError.self) {
            _ = try SPIREServerAPIAddress(parsing: ":8081")
        }
    }

    // MARK: - SPIFFE ID splitting

    @Test("Splits SPIFFE IDs into trust domain and path")
    func splitsSPIFFEID() throws {
        let payload = try SPIREServerAPIClient.spiffeIDPayload("spiffe://strato.local/agent/node-a")
        #expect(payload.trustDomain == "strato.local")
        #expect(payload.path == "/agent/node-a")
    }

    @Test("Rejects malformed SPIFFE IDs")
    func rejectsMalformedSPIFFEID() {
        #expect(throws: SPIREServerAPIError.self) {
            _ = try SPIREServerAPIClient.spiffeIDPayload("https://strato.local/agent/x")
        }
        #expect(throws: SPIREServerAPIError.self) {
            _ = try SPIREServerAPIClient.spiffeIDPayload("spiffe://no-path")
        }
    }

    // MARK: - Round trips against a fake SPIRE server

    @Test("CreateJoinToken round trip", .timeLimit(.minutes(1)))
    func createJoinToken() async throws {
        let state = FakeSPIREServerState()
        try await withFakeSPIREServer(state: state) { client in
            let token = try await client.createJoinToken(
                ttlSeconds: 3600,
                agentID: "spiffe://strato.local/node/node-a"
            )
            #expect(token.value == "generated-join-token")

            let requests = await state.joinTokenRequests
            #expect(requests.count == 1)
            #expect(requests.first?.ttl == 3600)
            #expect(requests.first?.agentID.trustDomain == "strato.local")
            #expect(requests.first?.agentID.path == "/node/node-a")
        }
    }

    @Test("BatchCreateEntry returns created", .timeLimit(.minutes(1)))
    func createEntryCreated() async throws {
        let state = FakeSPIREServerState()
        try await withFakeSPIREServer(state: state) { client in
            let result = try await client.createEntry(
                spiffeID: "spiffe://strato.local/agent/node-a",
                parentID: "spiffe://strato.local/node/node-a",
                selectors: [SPIRESelector(type: "unix", value: "uid:0")],
                x509SVIDTTLSeconds: 1800
            )
            #expect(result == .created(entryID: "new-entry-id"))

            let entries = await state.createdEntries
            #expect(entries.count == 1)
            #expect(entries.first?.spiffeID.path == "/agent/node-a")
            #expect(entries.first?.parentID.path == "/node/node-a")
            #expect(entries.first?.selectors.first?.type == "unix")
            #expect(entries.first?.selectors.first?.value == "uid:0")
            #expect(entries.first?.x509SvidTtl == 1800)
        }
    }

    @Test("BatchCreateEntry maps ALREADY_EXISTS to a reused entry", .timeLimit(.minutes(1)))
    func createEntryAlreadyExists() async throws {
        let state = FakeSPIREServerState()
        await state.setCreateEntryStatus(code: 6, existingEntryID: "existing-id")
        try await withFakeSPIREServer(state: state) { client in
            let result = try await client.createEntry(
                spiffeID: "spiffe://strato.local/agent/node-a",
                parentID: "spiffe://strato.local/node/node-a",
                selectors: [],
                x509SVIDTTLSeconds: 0
            )
            #expect(result == .alreadyExists(entryID: "existing-id"))
        }
    }

    @Test("BatchCreateEntry surfaces other failure codes", .timeLimit(.minutes(1)))
    func createEntryFailure() async throws {
        let state = FakeSPIREServerState()
        await state.setCreateEntryStatus(code: 3, existingEntryID: "")  // INVALID_ARGUMENT
        try await withFakeSPIREServer(state: state) { client in
            await #expect(throws: SPIREServerAPIError.self) {
                _ = try await client.createEntry(
                    spiffeID: "spiffe://strato.local/agent/node-a",
                    parentID: "spiffe://strato.local/node/node-a",
                    selectors: [],
                    x509SVIDTTLSeconds: 0
                )
            }
        }
    }

    @Test("deleteEntries lists matching entries and deletes them", .timeLimit(.minutes(1)))
    func deleteEntriesDeletesMatches() async throws {
        let state = FakeSPIREServerState()
        await state.setListedEntryIDs(["entry-1", "entry-2"])
        try await withFakeSPIREServer(state: state) { client in
            let deleted = try await client.deleteEntries(spiffeID: "spiffe://strato.local/agent/node-a")
            #expect(deleted == 2)

            let listRequests = await state.listRequests
            #expect(listRequests.first?.filter.bySpiffeID.path == "/agent/node-a")

            let deleteRequests = await state.deleteRequests
            #expect(deleteRequests.first?.ids == ["entry-1", "entry-2"])
        }
    }

    @Test("deleteEntries pages through the full ListEntries result set", .timeLimit(.minutes(1)))
    func deleteEntriesPaginates() async throws {
        let state = FakeSPIREServerState()
        await state.setListedEntryPages([["entry-1"], ["entry-2", "entry-3"]])
        try await withFakeSPIREServer(state: state) { client in
            let deleted = try await client.deleteEntries(spiffeID: "spiffe://strato.local/agent/node-a")
            #expect(deleted == 3)

            // Two list calls: the second carries the server's page token
            let listRequests = await state.listRequests
            #expect(listRequests.count == 2)
            #expect(listRequests.first?.pageToken == "")
            let secondToken = listRequests.dropFirst().first?.pageToken ?? ""
            #expect(!secondToken.isEmpty)

            let deleteRequests = await state.deleteRequests
            #expect(deleteRequests.first?.ids == ["entry-1", "entry-2", "entry-3"])
        }
    }

    @Test("deleteEntries with no matches deletes nothing", .timeLimit(.minutes(1)))
    func deleteEntriesNoMatches() async throws {
        let state = FakeSPIREServerState()
        try await withFakeSPIREServer(state: state) { client in
            let deleted = try await client.deleteEntries(spiffeID: "spiffe://strato.local/agent/absent")
            #expect(deleted == 0)

            let deleteRequests = await state.deleteRequests
            #expect(deleteRequests.isEmpty)
        }
    }

    @Test("DeleteAgent evicts an attested agent", .timeLimit(.minutes(1)))
    func evictAgentEvicts() async throws {
        let state = FakeSPIREServerState()
        try await withFakeSPIREServer(state: state) { client in
            let evicted = try await client.evictAgent(spiffeID: "spiffe://strato.local/node/node-a")
            #expect(evicted)

            let requests = await state.deleteAgentRequests
            #expect(requests.first?.id.path == "/node/node-a")
        }
    }

    @Test("DeleteAgent maps NOT_FOUND to a no-op eviction", .timeLimit(.minutes(1)))
    func evictAgentNotFound() async throws {
        let state = FakeSPIREServerState()
        await state.setDeleteAgentNotFound(true)
        try await withFakeSPIREServer(state: state) { client in
            let evicted = try await client.evictAgent(spiffeID: "spiffe://strato.local/node/absent")
            #expect(!evicted)
        }
    }

    @Test("listFederationRelationships maps profiles and bundle state across pages", .timeLimit(.minutes(1)))
    func listFederationRelationshipsMapsAndPaginates() async throws {
        let state = FakeSPIREServerState()

        var withBundle = Spire_Api_Types_FederationRelationship()
        withBundle.trustDomain = "partner.example"
        withBundle.bundleEndpointURL = "https://partner.example/bundle"
        var spiffeProfile = Spire_Api_Types_HTTPSSPIFFEProfile()
        spiffeProfile.endpointSpiffeID = "spiffe://partner.example/spire/server"
        withBundle.httpsSpiffe = spiffeProfile
        var bundle = Spire_Api_Types_Bundle()
        bundle.trustDomain = "partner.example"
        var authority = Spire_Api_Types_X509Certificate()
        authority.asn1 = Data([0x30, 0x01])
        bundle.x509Authorities = [authority, authority]
        bundle.sequenceNumber = 7
        withBundle.trustDomainBundle = bundle

        var pending = Spire_Api_Types_FederationRelationship()
        pending.trustDomain = "pending.example"
        pending.bundleEndpointURL = "https://pending.example/bundle"
        pending.httpsWeb = Spire_Api_Types_HTTPSWebProfile()

        // Two pages, so the client must follow the nextPageToken.
        await state.setFederationPages([[withBundle], [pending]])

        try await withFakeSPIREServer(state: state) { client in
            let relationships = try await client.listFederationRelationships()
            #expect(relationships.count == 2)

            let partner = try #require(relationships.first { $0.trustDomain == "partner.example" })
            #expect(partner.bundleEndpointProfile == "https_spiffe")
            #expect(partner.endpointSPIFFEID == "spiffe://partner.example/spire/server")
            #expect(partner.bundleX509AuthorityCount == 2)
            #expect(partner.bundleSequenceNumber == 7)

            let notFetched = try #require(relationships.first { $0.trustDomain == "pending.example" })
            #expect(notFetched.bundleEndpointProfile == "https_web")
            #expect(notFetched.endpointSPIFFEID == nil)
            #expect(notFetched.bundleX509AuthorityCount == 0)

            // The output mask must request the bundle so sync state is knowable,
            // and pagination must carry the server's page token on the 2nd call.
            // Pagination: the first call sends no token and the client follows
            // the server's nextPageToken on the second page; the request must
            // also ask for the bundle via the output mask so sync state is
            // knowable. (Asserted by content, not exact count, to stay robust.)
            let requests = await state.listFederationRequests
            let tokens = requests.map(\.pageToken)
            #expect(requests.first?.outputMask.trustDomainBundle == true)
            #expect(tokens.first == "", "tokens=\(tokens)")
            #expect(tokens.contains("fed-page-1"), "tokens=\(tokens)")
        }
    }

    @Test("A missing Unix socket is reported as unreachable")
    func missingSocketUnreachable() async throws {
        let client = SPIREServerAPIClient(
            address: .unixSocket(path: "/tmp/strato-spire-nonexistent.sock"),
            logger: Self.testLogger
        )
        await #expect(throws: SPIREServerAPIError.self) {
            _ = try await client.createJoinToken(ttlSeconds: 60, agentID: nil)
        }
    }

    // MARK: - Fake server plumbing

    /// Run `body` with a client wired to a fake SPIRE server gRPC service
    /// listening on a fresh Unix domain socket.
    private func withFakeSPIREServer(
        state: FakeSPIREServerState,
        _ body: @Sendable @escaping (SPIREServerAPIClient) async throws -> Void
    ) async throws {
        // Keep the path short: UDS paths have a ~104 byte limit
        let socketPath = "/tmp/strato-sp-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let service = FakeSPIREServerService(state: state)

        try await withGRPCServer(transport: transport, services: [service]) { _ in
            // Wait for the listener to bind before letting the client connect
            _ = try await transport.listeningAddress
            let client = SPIREServerAPIClient(
                address: .unixSocket(path: socketPath),
                logger: Self.testLogger,
                timeout: .seconds(10)
            )
            try await body(client)
        }
    }
}

// MARK: - Fake SPIRE server service

/// Recorded requests and canned responses for the fake SPIRE server.
private actor FakeSPIREServerState {
    private(set) var joinTokenRequests: [Spire_Api_Server_Agent_V1_CreateJoinTokenRequest] = []
    private(set) var createdEntries: [Spire_Api_Types_Entry] = []
    private(set) var listRequests: [Spire_Api_Server_Entry_V1_ListEntriesRequest] = []
    private(set) var deleteRequests: [Spire_Api_Server_Entry_V1_BatchDeleteEntryRequest] = []
    private(set) var deleteAgentRequests: [Spire_Api_Server_Agent_V1_DeleteAgentRequest] = []
    private(set) var deleteAgentNotFound = false
    private(set) var listFederationRequests: [Spire_Api_Server_Trustdomain_V1_ListFederationRelationshipsRequest] =
        []
    private var federationPages: [[Spire_Api_Types_FederationRelationship]] = []

    /// Serve ListFederationRelationships results one page at a time. Paging is
    /// idempotent — keyed on the request's page token rather than a destructive
    /// queue — so a transparently retried request returns the same page instead
    /// of advancing, keeping the pagination test deterministic.
    func setFederationPages(_ pages: [[Spire_Api_Types_FederationRelationship]]) {
        self.federationPages = pages
    }

    func federationPage(for pageToken: String) -> (
        relationships: [Spire_Api_Types_FederationRelationship], nextPageToken: String
    ) {
        let index = pageToken.isEmpty ? 0 : (Int(pageToken.split(separator: "-").last ?? "") ?? 0)
        guard index < federationPages.count else { return ([], "") }
        let nextToken = index + 1 < federationPages.count ? "fed-page-\(index + 1)" : ""
        return (federationPages[index], nextToken)
    }

    func recordListFederation(_ request: Spire_Api_Server_Trustdomain_V1_ListFederationRelationshipsRequest) {
        listFederationRequests.append(request)
    }

    func setDeleteAgentNotFound(_ notFound: Bool) {
        self.deleteAgentNotFound = notFound
    }

    func recordDeleteAgent(_ request: Spire_Api_Server_Agent_V1_DeleteAgentRequest) {
        deleteAgentRequests.append(request)
    }

    private(set) var createEntryStatusCode: Int32 = 0
    private(set) var existingEntryID = ""
    private var listedEntryPages: [[String]] = []

    func setCreateEntryStatus(code: Int32, existingEntryID: String) {
        self.createEntryStatusCode = code
        self.existingEntryID = existingEntryID
    }

    func setListedEntryIDs(_ ids: [String]) {
        self.listedEntryPages = ids.isEmpty ? [] : [ids]
    }

    /// Serve ListEntries results one page per call, with a nextPageToken on
    /// every page but the last — like a server imposing its own page size.
    func setListedEntryPages(_ pages: [[String]]) {
        self.listedEntryPages = pages
    }

    func nextListPage() -> (ids: [String], nextPageToken: String) {
        guard !listedEntryPages.isEmpty else { return ([], "") }
        let page = listedEntryPages.removeFirst()
        return (page, listedEntryPages.isEmpty ? "" : "page-\(listedEntryPages.count)")
    }

    func recordJoinToken(_ request: Spire_Api_Server_Agent_V1_CreateJoinTokenRequest) {
        joinTokenRequests.append(request)
    }

    func recordCreateEntry(_ entries: [Spire_Api_Types_Entry]) {
        createdEntries.append(contentsOf: entries)
    }

    func recordList(_ request: Spire_Api_Server_Entry_V1_ListEntriesRequest) {
        listRequests.append(request)
    }

    func recordDelete(_ request: Spire_Api_Server_Entry_V1_BatchDeleteEntryRequest) {
        deleteRequests.append(request)
    }
}

/// Minimal SPIRE server Agent + Entry API implementation backed by
/// `FakeSPIREServerState`.
private struct FakeSPIREServerService: RegistrableRPCService {
    let state: FakeSPIREServerState

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.agent.v1.Agent"),
                method: "CreateJoinToken"
            ),
            deserializer: ProtobufDeserializer<Spire_Api_Server_Agent_V1_CreateJoinTokenRequest>(),
            serializer: ProtobufSerializer<Spire_Api_Types_JoinToken>()
        ) { request, _ in
            let message = try await Self.singleMessage(request)
            await self.state.recordJoinToken(message)

            var token = Spire_Api_Types_JoinToken()
            token.value = "generated-join-token"
            token.expiresAt = Int64(Date().addingTimeInterval(TimeInterval(message.ttl)).timeIntervalSince1970)
            return Self.singleResponse(token)
        }

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.agent.v1.Agent"),
                method: "DeleteAgent"
            ),
            deserializer: ProtobufDeserializer<Spire_Api_Server_Agent_V1_DeleteAgentRequest>(),
            serializer: ProtobufSerializer<Google_Protobuf_Empty>()
        ) { request, _ in
            let message = try await Self.singleMessage(request)
            if await self.state.deleteAgentNotFound {
                throw RPCError(code: .notFound, message: "agent not found")
            }
            await self.state.recordDeleteAgent(message)
            return Self.singleResponse(Google_Protobuf_Empty())
        }

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
                method: "BatchCreateEntry"
            ),
            deserializer: ProtobufDeserializer<Spire_Api_Server_Entry_V1_BatchCreateEntryRequest>(),
            serializer: ProtobufSerializer<Spire_Api_Server_Entry_V1_BatchCreateEntryResponse>()
        ) { request, _ in
            let message = try await Self.singleMessage(request)
            await self.state.recordCreateEntry(message.entries)

            let statusCode = await self.state.createEntryStatusCode
            let existingID = await self.state.existingEntryID

            var response = Spire_Api_Server_Entry_V1_BatchCreateEntryResponse()
            response.results = message.entries.map { entry in
                var result = Spire_Api_Server_Entry_V1_BatchCreateEntryResponse.Result()
                result.status.code = statusCode
                result.entry = entry
                result.entry.id = statusCode == 0 ? "new-entry-id" : existingID
                return result
            }
            return Self.singleResponse(response)
        }

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
                method: "ListEntries"
            ),
            deserializer: ProtobufDeserializer<Spire_Api_Server_Entry_V1_ListEntriesRequest>(),
            serializer: ProtobufSerializer<Spire_Api_Server_Entry_V1_ListEntriesResponse>()
        ) { request, _ in
            let message = try await Self.singleMessage(request)
            await self.state.recordList(message)

            let page = await self.state.nextListPage()
            var response = Spire_Api_Server_Entry_V1_ListEntriesResponse()
            response.entries = page.ids.map { id in
                var entry = Spire_Api_Types_Entry()
                entry.id = id
                entry.spiffeID = message.filter.bySpiffeID
                return entry
            }
            response.nextPageToken = page.nextPageToken
            return Self.singleResponse(response)
        }

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "spire.api.server.entry.v1.Entry"),
                method: "BatchDeleteEntry"
            ),
            deserializer: ProtobufDeserializer<Spire_Api_Server_Entry_V1_BatchDeleteEntryRequest>(),
            serializer: ProtobufSerializer<Spire_Api_Server_Entry_V1_BatchDeleteEntryResponse>()
        ) { request, _ in
            let message = try await Self.singleMessage(request)
            await self.state.recordDelete(message)

            var response = Spire_Api_Server_Entry_V1_BatchDeleteEntryResponse()
            response.results = message.ids.map { id in
                var result = Spire_Api_Server_Entry_V1_BatchDeleteEntryResponse.Result()
                result.id = id
                result.status.code = 0
                return result
            }
            return Self.singleResponse(response)
        }

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(
                    fullyQualifiedService: "spire.api.server.trustdomain.v1.TrustDomain"),
                method: "ListFederationRelationships"
            ),
            deserializer: ProtobufDeserializer<Spire_Api_Server_Trustdomain_V1_ListFederationRelationshipsRequest>(),
            serializer: ProtobufSerializer<Spire_Api_Server_Trustdomain_V1_ListFederationRelationshipsResponse>()
        ) { request, _ in
            let message = try await Self.singleMessage(request)
            await self.state.recordListFederation(message)

            let page = await self.state.federationPage(for: message.pageToken)
            var response = Spire_Api_Server_Trustdomain_V1_ListFederationRelationshipsResponse()
            response.federationRelationships = page.relationships
            response.nextPageToken = page.nextPageToken
            return Self.singleResponse(response)
        }
    }

    private static func singleMessage<Message: Sendable>(
        _ request: StreamingServerRequest<Message>
    ) async throws -> Message {
        for try await message in request.messages {
            return message
        }
        throw RPCError(code: .invalidArgument, message: "expected a request message")
    }

    private static func singleResponse<Message: Sendable>(_ message: Message) -> StreamingServerResponse<Message> {
        StreamingServerResponse { writer in
            try await writer.write(message)
            return [:]
        }
    }
}
