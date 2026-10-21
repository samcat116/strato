import StratoShared
import Testing

@Suite("OCI Auth Challenge Parsing")
struct OCIAuthChallengeTests {

    @Test("bearer challenge with quoted parameters")
    func bearerChallenge() {
        let parsed = OCIAuthChallenge.parse(
            "Bearer realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\"")
        #expect(parsed == .bearer(realm: "https://auth.docker.io/token", service: "registry.docker.io", scope: nil))
    }

    @Test("bearer challenge with scope and unquoted values")
    func bearerChallengeWithScope() {
        let parsed = OCIAuthChallenge.parse(
            "Bearer realm=https://auth.example.com/token,scope=\"repository:a/b:pull\",service=reg")
        #expect(
            parsed == .bearer(realm: "https://auth.example.com/token", service: "reg", scope: "repository:a/b:pull"))
    }

    @Test("parameter order, whitespace and case do not affect parsing")
    func reorderedParameters() {
        let parsed = OCIAuthChallenge.parse(
            #"  bEaReR SCOPE="repository:a/b:pull", SERVICE = "reg", REALM = "https://auth.example.com/token"  "#)
        #expect(
            parsed == .bearer(realm: "https://auth.example.com/token", service: "reg", scope: "repository:a/b:pull"))
    }

    @Test("realm alone is sufficient for bearer authentication")
    func realmOnly() {
        #expect(
            OCIAuthChallenge.parse("Bearer realm=https://auth.example.com/token")
                == .bearer(realm: "https://auth.example.com/token", service: nil, scope: nil))
    }

    @Test("quoted commas do not split parameters")
    func quotedCommas() {
        let parsed = OCIAuthChallenge.parse(
            "Bearer realm=\"https://auth.example.com/token\",scope=\"repository:a:pull,push\"")
        guard case .bearer(let realm, _, let scope) = parsed else {
            Issue.record("expected a bearer challenge")
            return
        }
        #expect(realm == "https://auth.example.com/token")
        #expect(scope == "repository:a:pull,push")
    }

    @Test("basic challenge")
    func basicChallenge() {
        #expect(OCIAuthChallenge.parse("Basic realm=\"registry\"") == .basic)
    }

    @Test("unrecognized schemes and realm-less bearers parse to nil")
    func unrecognized() {
        #expect(OCIAuthChallenge.parse("Digest realm=\"x\"") == nil)
        #expect(OCIAuthChallenge.parse("Negotiate") == nil)
        #expect(OCIAuthChallenge.parse("Bearer realm=\"\"") == nil)
        #expect(OCIAuthChallenge.parse("") == nil)
        #expect(OCIAuthChallenge.parse("Bearer service=\"x\"") == nil)
    }
}
