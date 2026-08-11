import Testing

@testable import App

@Suite("Guest identity issuance configuration")
struct GuestIdentityIssuanceConfigTests {
    @Test(
        "Audience parsing trims blanks and collapses duplicates",
        arguments: [
            (nil, Set<String>()),
            ("", Set<String>()),
            ("  , \n", Set<String>()),
            ("vault", Set(["vault"])),
            (" vault,registry,vault, ", Set(["vault", "registry"])),
        ])
    func audienceParsing(raw: String?, expected: Set<String>) throws {
        #expect(try GuestIdentityIssuanceConfig.audiences(rawValue: raw) == expected)
    }

    @Test("Audience parsing rejects values the issuer cannot mint")
    func audienceLengthLimit() throws {
        let accepted = String(repeating: "a", count: 255)
        let rejected = String(repeating: "a", count: 256)

        #expect(try GuestIdentityIssuanceConfig.audiences(rawValue: accepted) == [accepted])
        #expect(throws: GuestIdentityIssuanceConfigurationError.self) {
            try GuestIdentityIssuanceConfig.audiences(rawValue: rejected)
        }
    }

    @Test(
        "TTL parsing uses the fallback unless the value is positive",
        arguments: [nil, "", "words", "0", "-1"])
    func ttlFallback(raw: String?) {
        #expect(GuestIdentityIssuanceConfig.ttlSeconds(rawValue: raw, fallback: 300) == 300)
    }

    @Test("TTL parsing accepts a trimmed positive value")
    func ttlParsing() {
        #expect(GuestIdentityIssuanceConfig.ttlSeconds(rawValue: " 450 ", fallback: 300) == 450)
    }

    @Test("Requested TTL defaults, passes through, and clamps to the maximum")
    func resolvedTTL() {
        let config = GuestIdentityIssuanceConfig(
            allowedAudiences: ["vault"], defaultTTLSeconds: 300, maximumTTLSeconds: 600)
        #expect(config.resolvedTTL(requested: nil) == 300)
        #expect(config.resolvedTTL(requested: 450) == 450)
        #expect(config.resolvedTTL(requested: 3_600) == 600)
    }

    @Test("Every requested audience must be allowlisted")
    func permits() {
        let enabled = GuestIdentityIssuanceConfig(
            allowedAudiences: ["vault", "registry"],
            defaultTTLSeconds: 300,
            maximumTTLSeconds: 600)
        #expect(enabled.permits(audiences: ["vault"]))
        #expect(enabled.permits(audiences: ["registry", "vault"]))
        #expect(!enabled.permits(audiences: ["strato-api"]))
        #expect(!GuestIdentityIssuanceConfig.disabled.permits(audiences: ["vault"]))
    }
}
