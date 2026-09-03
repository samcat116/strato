import Foundation
import Testing

@testable import StratoShared

@Suite("Base64URL")
struct Base64URLTests {
    @Test("encodes URL-safe text without padding and round-trips")
    func roundTrip() throws {
        let bytes = Data([0xfb, 0xff, 0x00, 0x01])
        let encoded = Base64URL.encode(bytes)

        #expect(encoded == "-_8AAQ")
        #expect(Base64URL.decode(encoded) == bytes)
    }

    @Test("accepts padded input and rejects malformed input")
    func inputValidation() {
        #expect(Base64URL.decode("SGVsbG8=") == Data("Hello".utf8))
        #expect(Base64URL.decode("***") == nil)
    }
}
