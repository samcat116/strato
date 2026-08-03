import Foundation
import Testing
import WebAuthn

@testable import App

/// Covers the parts of the stored passkey record that are derived from a
/// ceremony rather than chosen by us: the transports the client reports, the
/// device type implied by backup eligibility, and the `excludeCredentials` list
/// that has to be merged into the creation options by hand.
@Suite("Passkey Credential Record")
struct PasskeyCredentialRecordTests {

    // MARK: - Transports

    @Test("Client-reported transports are kept in order, deduplicated")
    func transportsArePreservedInOrder() {
        let sanitized = WebAuthnService.sanitizedTransports(["hybrid", "internal", "hybrid"])
        #expect(sanitized == ["hybrid", "internal"])
    }

    @Test("Unregistered transport values are dropped")
    func unknownTransportsAreDropped() {
        let sanitized = WebAuthnService.sanitizedTransports(["usb", "telepathy", "", "nfc"])
        #expect(sanitized == ["usb", "nfc"])
    }

    @Test("A client that omits getTransports stores no transports")
    func missingTransportsBecomeEmpty() {
        #expect(WebAuthnService.sanitizedTransports(nil).isEmpty)
    }

    // MARK: - Device type

    @Test("Device type follows backup eligibility and matches the assertion vocabulary")
    func deviceTypeMatchesLibraryVocabulary() {
        let multi = WebAuthnService.deviceType(backupEligible: true)
        let single = WebAuthnService.deviceType(backupEligible: false)
        #expect(multi == VerifiedAuthentication.CredentialDeviceType.multiDevice.rawValue)
        #expect(single == VerifiedAuthentication.CredentialDeviceType.singleDevice.rawValue)
        // The login path writes the library's raw value straight into the same
        // column, so the two vocabularies must not drift apart.
        #expect(multi != single)
    }

    // MARK: - excludeCredentials

    private func creationOptions() -> PublicKeyCredentialCreationOptions {
        PublicKeyCredentialCreationOptions(
            challenge: Array("test-challenge".utf8),
            user: PublicKeyCredentialUserEntity(
                id: Array(UUID().uuidString.utf8),
                name: "someone",
                displayName: "Someone"
            ),
            relyingParty: .init(id: "localhost", name: "Strato"),
            publicKeyCredentialParameters: .supported,
            timeout: .seconds(60),
            attestation: .none
        )
    }

    private func encodedOptions(_ response: RegistrationBeginResponse) throws -> [String: Any] {
        let data = try JSONEncoder().encode(response)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let options = root?["options"] as? [String: Any]
        return try #require(options)
    }

    /// The library's options type has no `excludeCredentials` field, so the list
    /// is encoded into the same JSON object as the library's own keys. If that
    /// merge ever stops working the browser silently loses the exclude list —
    /// which fails open (duplicate enrollments), so it needs a test.
    @Test("excludeCredentials is emitted alongside the library's own option keys")
    func excludeCredentialsIsMergedIntoOptions() throws {
        let descriptor = PublicKeyCredentialDescriptor(
            type: .publicKey,
            id: Array("credential-id-bytes".utf8),
            transports: [.hybrid, .internal]
        )
        let response = RegistrationBeginResponse(
            options: creationOptions(),
            excludeCredentials: [descriptor]
        )

        let options = try encodedOptions(response)

        // The library's keys survive the merge...
        #expect(options["challenge"] != nil)
        #expect(options["rp"] != nil)
        #expect(options["user"] != nil)
        #expect(options["pubKeyCredParams"] != nil)

        // ...and ours is present, base64url encoded, with its transport hints.
        let excluded = try #require(options["excludeCredentials"] as? [[String: Any]])
        #expect(excluded.count == 1)
        let entry = try #require(excluded.first)
        #expect(entry["type"] as? String == "public-key")
        #expect(entry["id"] as? String == Array("credential-id-bytes".utf8).base64URLEncodedString().asString())
        #expect(entry["transports"] as? [String] == ["hybrid", "internal"])
    }

    @Test("A first enrollment sends an empty excludeCredentials list")
    func excludeCredentialsIsEmptyForFirstPasskey() throws {
        let response = RegistrationBeginResponse(options: creationOptions())
        let options = try encodedOptions(response)
        let excluded = try #require(options["excludeCredentials"] as? [[String: Any]])
        #expect(excluded.isEmpty)
    }
}
