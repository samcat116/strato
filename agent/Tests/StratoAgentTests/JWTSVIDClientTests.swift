import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCProtobuf
import Logging
import SwiftProtobuf
import Testing

@testable import StratoAgentSPIFFE

/// Tests for the SPIFFE Workload API's JWT-SVID profile (issue #495):
/// FetchJWTSVID / FetchJWTBundles / ValidateJWTSVID, the unverified claim
/// decoding that gives a minted token its expiry, and the file-based source's
/// refusal to pretend it can do any of it.
@Suite("Workload API JWT-SVID Client")
struct JWTSVIDClientTests {

    private static let testLogger = Logger(label: "test.jwt-svid")

    // MARK: - Token claim decoding

    @Test("Decodes the registered claims of a JWT-SVID")
    func decodesClaims() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let token = TestJWT.make(
            claims: [
                "sub": "spiffe://strato.local/ci/builder",
                "aud": ["spiffe://strato.local/control-plane"],
                "exp": expiry.timeIntervalSince1970,
                "iat": expiry.timeIntervalSince1970 - 300,
            ])

        let claims = try JWTSVIDToken.decodeUnverifiedClaims(token)
        #expect(claims.subject == "spiffe://strato.local/ci/builder")
        #expect(claims.audience == ["spiffe://strato.local/control-plane"])
        #expect(claims.expiresAt == expiry)
        #expect(claims.issuedAt == expiry.addingTimeInterval(-300))
    }

    @Test("Accepts a single-string audience claim")
    func decodesStringAudience() throws {
        let token = TestJWT.make(
            claims: [
                "sub": "spiffe://strato.local/ci/builder",
                "aud": "spiffe://strato.local/control-plane",
                "exp": Date().addingTimeInterval(300).timeIntervalSince1970,
            ])

        let claims = try JWTSVIDToken.decodeUnverifiedClaims(token)
        #expect(claims.audience == ["spiffe://strato.local/control-plane"])
    }

    @Test("Rejects tokens missing a claim the profile requires")
    func rejectsIncompleteClaims() {
        let noExpiry = TestJWT.make(
            claims: [
                "sub": "spiffe://strato.local/ci/builder",
                "aud": ["spiffe://strato.local/control-plane"],
            ])
        #expect(throws: SPIFFEError.self) {
            _ = try JWTSVIDToken.decodeUnverifiedClaims(noExpiry)
        }

        let noSubject = TestJWT.make(
            claims: [
                "aud": ["spiffe://strato.local/control-plane"],
                "exp": Date().timeIntervalSince1970,
            ])
        #expect(throws: SPIFFEError.self) {
            _ = try JWTSVIDToken.decodeUnverifiedClaims(noSubject)
        }

        let noAudience = TestJWT.make(
            claims: [
                "sub": "spiffe://strato.local/ci/builder",
                "exp": Date().timeIntervalSince1970,
            ])
        #expect(throws: SPIFFEError.self) {
            _ = try JWTSVIDToken.decodeUnverifiedClaims(noAudience)
        }
    }

    @Test("Rejects tokens that are not compact-serialized JWS")
    func rejectsMalformedTokens() {
        #expect(throws: SPIFFEError.self) {
            _ = try JWTSVIDToken.decodeUnverifiedClaims("not-a-jwt")
        }
        #expect(throws: SPIFFEError.self) {
            _ = try JWTSVIDToken.decodeUnverifiedClaims("a.b")
        }
        #expect(throws: SPIFFEError.self) {
            _ = try JWTSVIDToken.decodeUnverifiedClaims("aaa.!!!.ccc")
        }
    }

    @Test("Recognizes the compact JWS shape without validating it")
    func recognizesJWSShape() {
        #expect(JWTSVIDToken.hasCompactJWSShape("aaa.bbb.ccc"))
        #expect(JWTSVIDToken.hasCompactJWSShape(TestJWT.make(claims: ["sub": "x"])))
        #expect(!JWTSVIDToken.hasCompactJWSShape("sk_live_abcdefghijklmnop"))
        #expect(!JWTSVIDToken.hasCompactJWSShape("st_abcdefghijklmnop"))
        #expect(!JWTSVIDToken.hasCompactJWSShape("aaa.bbb"))
        #expect(!JWTSVIDToken.hasCompactJWSShape("aaa..ccc"))
    }

    // MARK: - Proto -> SVID conversion

    @Test("Converts a JWTSVIDResponse, taking expiry from the token")
    func convertsJWTSVIDResponse() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let token = TestJWT.make(
            claims: [
                "sub": "spiffe://strato.local/ci/builder",
                "aud": ["spiffe://strato.local/control-plane"],
                "exp": expiry.timeIntervalSince1970,
            ])

        var proto = Workload_JWTSVID()
        proto.spiffeID = "spiffe://strato.local/ci/builder"
        proto.svid = token
        proto.hint = "internal"
        var response = Workload_JWTSVIDResponse()
        response.svids = [proto]

        let svid = try WorkloadAPIConversion.makeJWTSVID(from: response)
        #expect(svid.spiffeID.uri == "spiffe://strato.local/ci/builder")
        #expect(svid.token == token)
        #expect(svid.expiresAt == expiry)
        #expect(svid.audience == ["spiffe://strato.local/control-plane"])
        #expect(svid.hint == "internal")
        #expect(svid.isExpired == (expiry <= Date()))
    }

    @Test("Rejects a response whose token subject contradicts the reported identity")
    func rejectsSubjectMismatch() {
        let token = TestJWT.make(
            claims: [
                "sub": "spiffe://strato.local/someone/else",
                "aud": ["spiffe://strato.local/control-plane"],
                "exp": Date().addingTimeInterval(300).timeIntervalSince1970,
            ])

        var proto = Workload_JWTSVID()
        proto.spiffeID = "spiffe://strato.local/ci/builder"
        proto.svid = token
        var response = Workload_JWTSVIDResponse()
        response.svids = [proto]

        #expect(throws: SPIFFEError.self) {
            _ = try WorkloadAPIConversion.makeJWTSVID(from: response)
        }
    }

    @Test("Empty JWTSVIDResponse raises noJWTSVIDAvailable")
    func emptyJWTResponseThrows() {
        #expect(throws: SPIFFEError.self) {
            _ = try WorkloadAPIConversion.makeJWTSVID(from: Workload_JWTSVIDResponse())
        }
    }

    @Test("Converts a JWTBundlesResponse keyed by trust domain")
    func convertsJWTBundles() {
        let jwks = Data(#"{"keys":[]}"#.utf8)
        var response = Workload_JWTBundlesResponse()
        response.bundles = ["spiffe://strato.local": jwks]

        let bundles = WorkloadAPIConversion.makeJWTBundles(from: response)
        #expect(bundles.count == 1)
        #expect(bundles["spiffe://strato.local"]?.trustDomain == "strato.local")
        #expect(bundles["spiffe://strato.local"]?.jwksJSON == jwks)
    }

    @Test("Converts a ValidateJWTSVIDResponse, flattening its claims")
    func convertsValidationResponse() throws {
        var response = Workload_ValidateJWTSVIDResponse()
        response.spiffeID = "spiffe://strato.local/ci/builder"
        var claims = Google_Protobuf_Struct()
        claims.fields = [
            "sub": Google_Protobuf_Value(stringLiteral: "spiffe://strato.local/ci/builder"),
            "exp": Google_Protobuf_Value(floatLiteral: 1_800_000_000),
        ]
        response.claims = claims

        let validated = try WorkloadAPIConversion.makeValidatedJWTSVID(
            from: response, audience: "spiffe://strato.local/control-plane")
        #expect(validated.spiffeID.uri == "spiffe://strato.local/ci/builder")
        #expect(validated.audience == "spiffe://strato.local/control-plane")
        #expect(validated.claims["sub"] == "spiffe://strato.local/ci/builder")
    }

    // MARK: - Against a fake Workload API

    @Test("Fetches a JWT-SVID over a Unix domain socket", .timeLimit(.minutes(1)))
    func fetchesJWTSVID() async throws {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let token = TestJWT.make(
            claims: [
                "sub": "spiffe://strato.local/ci/builder",
                "aud": ["spiffe://strato.local/control-plane"],
                "exp": expiry.timeIntervalSince1970,
            ])

        try await withFakeJWTWorkloadAPI(token: token, spiffeID: "spiffe://strato.local/ci/builder") { socketPath in
            let client = WorkloadAPISPIFFEClient(socketPath: socketPath, logger: Self.testLogger)
            let svid = try await client.fetchJWTSVID(
                audience: ["spiffe://strato.local/control-plane"], spiffeID: nil)

            #expect(svid.spiffeID.uri == "spiffe://strato.local/ci/builder")
            #expect(svid.token == token)
            #expect(svid.expiresAt == expiry)
            await client.close()
        }
    }

    @Test("Fetches JWT bundles over a Unix domain socket", .timeLimit(.minutes(1)))
    func fetchesJWTBundles() async throws {
        try await withFakeJWTWorkloadAPI(token: TestJWT.make(claims: ["sub": "x"]), spiffeID: "spiffe://strato.local/x")
        { socketPath in
            let client = WorkloadAPISPIFFEClient(socketPath: socketPath, logger: Self.testLogger)
            let bundles = try await client.fetchJWTBundles()

            #expect(bundles["spiffe://strato.local"]?.trustDomain == "strato.local")
            await client.close()
        }
    }

    @Test("Validates a JWT-SVID through the Workload API", .timeLimit(.minutes(1)))
    func validatesJWTSVID() async throws {
        let token = TestJWT.make(claims: ["sub": "spiffe://strato.local/ci/builder"])

        try await withFakeJWTWorkloadAPI(token: token, spiffeID: "spiffe://strato.local/ci/builder") { socketPath in
            let client = WorkloadAPISPIFFEClient(socketPath: socketPath, logger: Self.testLogger)
            let validated = try await client.validateJWTSVID(
                token: token, audience: "spiffe://strato.local/control-plane")

            #expect(validated.spiffeID.uri == "spiffe://strato.local/ci/builder")
            await client.close()
        }
    }

    @Test("An audience-less request is refused before it reaches SPIRE")
    func refusesEmptyAudience() async {
        let client = WorkloadAPISPIFFEClient(socketPath: "/nonexistent.sock", logger: Self.testLogger)
        await #expect(throws: SPIFFEError.self) {
            _ = try await client.fetchJWTSVID(audience: [], spiffeID: nil)
        }
    }

    // MARK: - File-based source

    @Test("File-based SVIDs refuse every JWT operation")
    func fileClientRefusesJWTOperations() async throws {
        let client = FileSPIFFEClient(
            certificatePath: "/nonexistent/cert.pem",
            privateKeyPath: "/nonexistent/key.pem",
            trustBundlePath: "/nonexistent/bundle.pem",
            spiffeID: SPIFFEIdentity(trustDomain: "strato.local", path: "/ci/builder"),
            logger: Self.testLogger
        )

        await #expect(throws: SPIFFEError.self) {
            _ = try await client.fetchJWTSVID(audience: ["aud"], spiffeID: nil)
        }
        await #expect(throws: SPIFFEError.self) {
            _ = try await client.fetchJWTBundles()
        }
        await #expect(throws: SPIFFEError.self) {
            _ = try await client.validateJWTSVID(token: "a.b.c", audience: "aud")
        }
    }

    // MARK: - Fake server plumbing

    private func withFakeJWTWorkloadAPI(
        token: String,
        spiffeID: String,
        _ body: @Sendable @escaping (String) async throws -> Void
    ) async throws {
        // Keep the path short: UDS paths have a ~104 byte limit
        let socketPath = "/tmp/strato-jwt-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let transport = HTTP2ServerTransport.Posix(
            address: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let service = FakeJWTWorkloadAPIService(token: token, spiffeID: spiffeID)

        try await withGRPCServer(transport: transport, services: [service]) { _ in
            _ = try await transport.listeningAddress
            try await body(socketPath)
        }
    }
}

// MARK: - Fake JWT Workload API service

/// Minimal SpiffeWorkloadAPI implementation covering the JWT-SVID profile.
private struct FakeJWTWorkloadAPIService: RegistrableRPCService {
    let token: String
    let spiffeID: String

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        let token = self.token
        let spiffeID = self.spiffeID

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
                method: "FetchJWTSVID"
            ),
            deserializer: ProtobufDeserializer<Workload_JWTSVIDRequest>(),
            serializer: ProtobufSerializer<Workload_JWTSVIDResponse>()
        ) { request, _ in
            try Self.requireSecurityHeader(request.metadata)
            let response: Workload_JWTSVIDResponse = {
                var svid = Workload_JWTSVID()
                svid.spiffeID = spiffeID
                svid.svid = token
                var response = Workload_JWTSVIDResponse()
                response.svids = [svid]
                return response
            }()
            return StreamingServerResponse { writer in
                try await writer.write(response)
                return [:]
            }
        }

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
                method: "FetchJWTBundles"
            ),
            deserializer: ProtobufDeserializer<Workload_JWTBundlesRequest>(),
            serializer: ProtobufSerializer<Workload_JWTBundlesResponse>()
        ) { request, _ in
            try Self.requireSecurityHeader(request.metadata)
            let response: Workload_JWTBundlesResponse = {
                var response = Workload_JWTBundlesResponse()
                response.bundles = ["spiffe://strato.local": Data(#"{"keys":[]}"#.utf8)]
                return response
            }()
            return StreamingServerResponse { writer in
                try await writer.write(response)
                return [:]
            }
        }

        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "SpiffeWorkloadAPI"),
                method: "ValidateJWTSVID"
            ),
            deserializer: ProtobufDeserializer<Workload_ValidateJWTSVIDRequest>(),
            serializer: ProtobufSerializer<Workload_ValidateJWTSVIDResponse>()
        ) { request, _ in
            try Self.requireSecurityHeader(request.metadata)
            let response: Workload_ValidateJWTSVIDResponse = {
                var response = Workload_ValidateJWTSVIDResponse()
                response.spiffeID = spiffeID
                return response
            }()
            return StreamingServerResponse { writer in
                try await writer.write(response)
                return [:]
            }
        }
    }

    /// Per the SPIFFE spec, servers must reject calls lacking this header.
    private static func requireSecurityHeader(_ metadata: Metadata) throws {
        guard metadata["workload.spiffe.io"].contains("true") else {
            throw RPCError(code: .invalidArgument, message: "security header missing")
        }
    }
}

// MARK: - Test JWT construction

/// Builds compact-serialized JWTs with an arbitrary claims set. The signature
/// segment is filler: nothing agent-side verifies it (the local SPIRE agent is
/// the one vouching), and the control plane's verifier is tested against real
/// signatures separately.
enum TestJWT {
    static func make(claims: [String: Any], header: [String: Any] = ["alg": "ES256", "kid": "test-key"]) -> String {
        [
            segment(header),
            segment(claims),
            "c2lnbmF0dXJl",
        ].joined(separator: ".")
    }

    private static func segment(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
