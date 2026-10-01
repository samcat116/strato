import Crypto
import Foundation
import Testing

@testable import App

@Suite("Credential token compatibility")
struct SecureTokenTests {
    @Test("Stored credential hashes remain lowercase SHA-256 hex", arguments: ["", "abc", "enroll_v1_☁️"])
    func storedHashes(value: String) {
        let expected = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(APIKey.hashAPIKey(value) == expected)
        #expect(SCIMToken.hashToken(value) == expected)
        #expect(DeviceAuthorization.hashCode(value) == expected)
        #expect(CLISession.hashToken(value) == expected)
        #expect(AccountClaimToken.hashToken(value) == expected)
        #expect(AgentEnrollment.hashBootstrapToken(value) == expected)
        #expect(expected.count == 64)
        if value == "abc" {
            #expect(expected == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
    }

    @Test("Base64 punctuation stripping, substitution and truncation retain their formats")
    func encodings() {
        // Produces both '+' and '/' as well as padding, exercising every transformation.
        let bytes = Data([0xfb, 0xff])
        #expect(SecureToken.encode(bytes) == "8")
        #expect(SecureToken.encode(bytes, encoding: .urlSafe) == "-_8")
        #expect(SecureToken.encode(bytes, length: 2, encoding: .urlSafe) == "-_")
        let full = Data(repeating: 0x41, count: 32)
        #expect(SecureToken.encode(full, length: 48).count == 43)
        #expect(SecureToken.encode(full, length: 32).count == 32)
    }

    @Test("Credentials keep their prefixes and alphabets")
    func credentialFormats() {
        let alphanumeric = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for token in [APIKey.generateAPIKey(), CLISession.generateAccessToken(), CLISession.generateRefreshToken()] {
            let parts = token.split(separator: "_", omittingEmptySubsequences: false)
            #expect(parts.count == 3)
            #expect(["sk", "st", "rt"].contains(String(parts[0])))
            #expect(parts[1].count == 16)
            #expect(parts[2].count <= 32)
            #expect(parts[1].allSatisfy { alphanumeric.contains($0) })
            #expect(parts[2].allSatisfy { alphanumeric.contains($0) })
        }
        for (token, prefix, limit) in [
            (SCIMToken.generateToken(), "scim_", 48),
            (AccountClaimToken.generateToken(), "claim_", 48),
            (DeviceAuthorization.generateDeviceCode(), "dc_", 40),
        ] {
            #expect(token.hasPrefix(prefix))
            let body = token.dropFirst(prefix.count)
            #expect(body.count <= limit)
            #expect(body.allSatisfy { alphanumeric.contains($0) })
        }
        let enrollment = AgentEnrollment.generateBootstrapToken()
        #expect(enrollment.hasPrefix("enroll_v1_"))
        let body = enrollment.dropFirst("enroll_v1_".count)
        #expect(body.count == 43)
        #expect(body.allSatisfy { alphanumeric.contains($0) || $0 == "-" || $0 == "_" })
    }
}
