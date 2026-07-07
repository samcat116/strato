import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
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

    private(set) var createEntryStatusCode: Int32 = 0
    private(set) var existingEntryID = ""
    private(set) var listedEntryIDs: [String] = []

    func setCreateEntryStatus(code: Int32, existingEntryID: String) {
        self.createEntryStatusCode = code
        self.existingEntryID = existingEntryID
    }

    func setListedEntryIDs(_ ids: [String]) {
        self.listedEntryIDs = ids
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

            let entryIDs = await self.state.listedEntryIDs
            var response = Spire_Api_Server_Entry_V1_ListEntriesResponse()
            response.entries = entryIDs.map { id in
                var entry = Spire_Api_Types_Entry()
                entry.id = id
                entry.spiffeID = message.filter.bySpiffeID
                return entry
            }
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
