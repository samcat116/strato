import Foundation
import Testing

@testable import StratoShared

@Suite("Guest identity minting wire contract")
struct GuestIdentityMintingTests {
    @Test("Request round-trips with and without an explicit TTL")
    func requestRoundTrip() throws {
        for request in [
            GuestJWTSVIDRequest(audiences: ["vault", "registry"], ttlSeconds: 300),
            GuestJWTSVIDRequest(audiences: ["vault"]),
        ] {
            #expect(try roundTrip(request) == request)
            #expect(try encodedKeys(request).contains("audiences"))
        }
    }

    @Test("Response round-trips using the shared wire date strategy")
    func responseRoundTrip() throws {
        let response = GuestJWTSVIDResponse(
            token: "header.payload.signature",
            spiffeId: "spiffe://strato.local/vm/aaaaaaaa-1111-2222-3333-444444444444",
            audiences: ["vault"],
            expiresAt: Fixtures.laterDate,
            issuedAt: Fixtures.timestamp
        )

        #expect(try roundTrip(response) == response)
        #expect(
            try encodedKeys(response)
                == ["token", "spiffeId", "audiences", "expiresAt", "issuedAt"])
    }
}
