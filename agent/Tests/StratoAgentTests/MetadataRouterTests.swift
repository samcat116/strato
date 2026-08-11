import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Metadata Router Tests")
struct MetadataRouterTests {

    private static func headers(_ pairs: (String, String)...) -> MetadataHeaders {
        MetadataHeaders(pairs.map { (name: $0.0, value: $0.1) })
    }

    private static func route(
        _ method: String, _ target: String, _ pairs: (String, String)...
    ) -> MetadataRoute {
        MetadataRouter.route(
            method: method, target: target, headers: MetadataHeaders(pairs.map { (name: $0.0, value: $0.1) }))
    }

    private static func status(of route: MetadataRoute) -> Int? {
        if case .rejected(let response) = route { return response.status }
        return nil
    }

    // MARK: - The mint

    @Test("A PUT with a valid TTL header routes to a mint")
    func mintAccepted() {
        #expect(
            Self.route("PUT", "/latest/api/token", (MetadataHeaderName.tokenTTL, "60")) == .mintToken(ttlSeconds: 60))
        // The bounds themselves are accepted, not merely the interior.
        #expect(Self.route("PUT", "/latest/api/token", (MetadataHeaderName.tokenTTL, "1")) == .mintToken(ttlSeconds: 1))
        #expect(
            Self.route("PUT", "/latest/api/token", (MetadataHeaderName.tokenTTL, "21600"))
                == .mintToken(ttlSeconds: 21600))
    }

    @Test("A mint without the TTL header is refused")
    func mintNeedsTTLHeader() {
        // The header's *presence* is the SSRF barrier: a PUT carrying a
        // mandatory custom header is not reachable from a naive request-forging
        // primitive inside a guest.
        #expect(Self.status(of: Self.route("PUT", "/latest/api/token")) == 400)
    }

    @Test(
        "A malformed or out-of-range TTL is refused",
        arguments: ["0", "21601", "-1", "+60", "60 ", "sixty", "", "٦٠", "999999999"])
    func mintRejectsBadTTL(_ ttl: String) {
        #expect(Self.status(of: Self.route("PUT", "/latest/api/token", (MetadataHeaderName.tokenTTL, ttl))) == 400)
    }

    @Test("A repeated TTL header is refused rather than resolved")
    func mintRejectsDuplicateTTL() {
        let route = Self.route(
            "PUT", "/latest/api/token", (MetadataHeaderName.tokenTTL, "60"), (MetadataHeaderName.tokenTTL, "21600"))
        #expect(Self.status(of: route) == 400)
    }

    // MARK: - The issue's second demanded test

    @Test("The token endpoint answers GET with 405, never a token")
    func tokenEndpointRefusesGET() {
        for pairs in [[], [(MetadataHeaderName.tokenTTL, "60")]] {
            let route = MetadataRouter.route(
                method: "GET", target: "/latest/api/token",
                headers: MetadataHeaders(pairs.map { (name: $0.0, value: $0.1) }))
            guard case .rejected(let response) = route else {
                Issue.record("GET on the token endpoint must be rejected outright")
                return
            }
            #expect(response.status == 405)
            #expect(response.header("allow") == "PUT")
            // Nothing in the response may be usable as a credential.
            #expect(!response.body.isEmpty)
            #expect(response.body == "the token endpoint accepts PUT only")
        }
    }

    @Test("Every other method on the token endpoint is refused too")
    func tokenEndpointRefusesOtherMethods() {
        for method in ["POST", "DELETE", "HEAD", "OPTIONS", "PATCH"] {
            let route = Self.route(method, "/latest/api/token", (MetadataHeaderName.tokenTTL, "60"))
            #expect(Self.status(of: route) == 405, "\(method) must not mint")
        }
    }

    // MARK: - Documents

    @Test("Known document paths route, with or without a trailing slash")
    func documentPaths() {
        #expect(Self.route("GET", "/latest") == .document(.root))
        #expect(Self.route("GET", "/latest/") == .document(.root))
        #expect(Self.route("GET", "/latest/meta-data") == .document(.noCloudMetaData))
        #expect(Self.route("GET", "/latest/meta-data/") == .document(.ec2MetaData(.index)))
        #expect(Self.route("GET", "/latest/user-data") == .document(.userData))
        #expect(Self.route("GET", "/latest/user-data/") == .document(.userData))
        #expect(Self.route("GET", "/latest/network-config") == .document(.networkConfig))
        #expect(Self.route("GET", "/latest/network-config/") == .document(.networkConfig))
        #expect(Self.route("GET", "/latest/meta-data/instance-id") == .document(.ec2MetaData(.instanceID)))
        #expect(Self.route("GET", "/latest/meta-data/instance-id/") == .document(.ec2MetaData(.instanceID)))
        #expect(Self.route("GET", "/latest/meta-data/hostname") == .document(.ec2MetaData(.hostname)))
        #expect(Self.route("GET", "/latest/meta-data/hostname/") == .document(.ec2MetaData(.hostname)))
        #expect(Self.route("GET", "/latest/meta-data/local-hostname") == .document(.ec2MetaData(.localHostname)))
        #expect(
            Self.route("GET", "/latest/meta-data/network/interfaces/macs/52:54:00:12:34:56/local-ipv4s")
                == .document(
                    .ec2MetaData(
                        .networkInterfaceLeaf(macAddress: "52:54:00:12:34:56", leaf: .localIPv4s))))
        #expect(
            Self.route("GET", "/latest/meta-data/public-keys/0/openssh-key")
                == .document(.ec2MetaData(.publicKeyOpenSSH(index: 0))))
        #expect(
            Self.route("GET", "/latest/dynamic/instance-identity/document")
                == .document(.ec2Dynamic(.instanceIdentityDocument)))
        #expect(
            Self.route("GET", "/latest/dynamic/instance-identity/")
                == .document(.ec2Dynamic(.instanceIdentity)))
    }

    @Test("An unserved path is not rejected at the router, so its 404 can wait for authentication")
    func unknownPathDefersTo404() {
        // If the router rejected here, anything that could reach the address
        // could map the tree without ever holding a session.
        #expect(Self.route("GET", "/latest/meta-data/ami-id") == .unknownDocument)
        #expect(Self.route("GET", "/latest/meta-data/public-keys/00/openssh-key") == .unknownDocument)
        #expect(Self.route("GET", "/latest/dynamic/instance-identity/signature") == .unknownDocument)
        #expect(Self.route("GET", "/latest/vendor-data/") == .unknownDocument)
        #expect(Self.route("GET", "/latest/meta-data/instance-id//") == .unknownDocument)
        #expect(Self.route("GET", "/") == .unknownDocument)
    }

    @Test("Writes to anything but the token endpoint are refused")
    func documentsAreReadOnly() {
        for method in ["PUT", "POST", "DELETE"] {
            let route = Self.route(method, "/latest/meta-data/instance-id")
            #expect(Self.status(of: route) == 405, "\(method) must not reach a document")
        }
    }

    @Test("A repeated credential header is refused rather than resolved")
    func duplicateTokenHeaderRefused() {
        let route = Self.route(
            "GET", "/latest/meta-data/instance-id", (MetadataHeaderName.token, "a"), (MetadataHeaderName.token, "b"))
        #expect(Self.status(of: route) == 400)
    }

    // MARK: - Targets

    @Test(
        "A malformed request target is refused",
        arguments: [
            "latest/meta-data",  // not origin-form
            "http://169.254.169.254/latest/meta-data",
            "/latest/../../etc/passwd",
            "/latest/meta-data/%2e%2e",
            "/latest/meta-data?x=1",
            "/latest/meta-data#frag",
            "/latest/meta data",
        ])
    func malformedTargets(_ target: String) {
        #expect(Self.status(of: Self.route("GET", target)) == 400)
    }

    @Test("An overlong request target is refused before anything looks at it")
    func overlongTarget() {
        let target = "/latest/" + String(repeating: "a", count: MetadataLimits.maxTargetBytes)
        #expect(Self.status(of: Self.route("GET", target)) == 400)
    }

    @Test("Header lookup is case-insensitive in the name and exact in the value")
    func headerCasing() {
        #expect(
            Self.route("PUT", "/latest/api/token", ("X-AWS-EC2-Metadata-Token-TTL-Seconds", "60"))
                == .mintToken(ttlSeconds: 60))

        // Both sides of the match, not just the incoming header: looking up a
        // mixed-case *name* has to work too, or the case-insensitivity is an
        // accident of every call site passing a lowercase literal.
        let headers = Self.headers(("x-aws-ec2-metadata-token", "abc"))
        #expect(headers.lookup("X-AWS-EC2-Metadata-Token") == .one("abc"))
        #expect(headers.lookup(MetadataHeaderName.token) == .one("abc"))
        // Values are untouched.
        #expect(Self.headers(("x-test", "MixedCase")).lookup("X-Test") == .one("MixedCase"))
    }

    @Test("Every response carries no-store, including the failures")
    func responsesAreNeverCached() {
        guard case .rejected(let response) = Self.route("GET", "/latest/api/token") else {
            Issue.record("expected a rejection")
            return
        }
        // A token in a guest's HTTP cache outlives the process that fetched it.
        #expect(response.header("cache-control") == "no-store")
        #expect(response.header("content-type") == "text/plain")
        #expect(response.header("x-content-type-options") == "nosniff")
    }
}
