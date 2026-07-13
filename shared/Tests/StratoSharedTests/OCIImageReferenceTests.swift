import Foundation
import Testing

@testable import StratoShared

@Suite("OCI Image Reference Tests")
struct OCIImageReferenceTests {

    private let digest = "sha256:6c3c624b58dbbcd3c0dd82b4c53f04194d1247c6eebdaab7c610cf7d66709b3b"

    @Test("Fully qualified reference parses into its components")
    func fullyQualified() {
        let ref = OCIImageReference.parse("ghcr.io/acme/worker:v3")
        #expect(ref == OCIImageReference(registry: "ghcr.io", repository: "acme/worker", tag: "v3"))
    }

    @Test("Bare Docker Hub official image normalizes to library/ with latest tag")
    func bareOfficialImage() {
        let ref = OCIImageReference.parse("alpine")
        #expect(ref == OCIImageReference(registry: "docker.io", repository: "library/alpine", tag: "latest"))
    }

    @Test("Docker Hub user image defaults registry and tag")
    func hubUserImage() {
        let ref = OCIImageReference.parse("acme/worker")
        #expect(ref == OCIImageReference(registry: "docker.io", repository: "acme/worker", tag: "latest"))
    }

    @Test("Docker Hub aliases collapse to docker.io")
    func hubAliases() {
        #expect(OCIImageReference.parse("index.docker.io/library/alpine:3.20")?.registry == "docker.io")
        #expect(OCIImageReference.parse("registry-1.docker.io/library/alpine")?.registry == "docker.io")
    }

    @Test("Registry with port keeps the port and steals no tag")
    func registryWithPort() {
        let ref = OCIImageReference.parse("registry.example.com:5000/team/app:1.2.3")
        let expected = OCIImageReference(
            registry: "registry.example.com:5000", repository: "team/app", tag: "1.2.3")
        #expect(ref == expected)
    }

    @Test("localhost counts as a registry host despite having no dot")
    func localhostRegistry() {
        let ref = OCIImageReference.parse("localhost:5000/app")
        #expect(ref == OCIImageReference(registry: "localhost:5000", repository: "app", tag: "latest"))
    }

    @Test("Digest-pinned reference carries the digest")
    func digestPinned() {
        let ref = OCIImageReference.parse("ghcr.io/acme/worker@\(digest)")
        #expect(ref?.digest == digest)
        #expect(ref?.manifestReference == digest)
    }

    @Test("Tag and digest together keep both, digest wins for the manifest request")
    func tagAndDigest() {
        let ref = OCIImageReference.parse("ghcr.io/acme/worker:v3@\(digest)")
        #expect(ref?.tag == "v3")
        #expect(ref?.digest == digest)
        #expect(ref?.manifestReference == digest)
    }

    @Test("Malformed references parse to nil")
    func malformed() {
        #expect(OCIImageReference.parse("") == nil)
        #expect(OCIImageReference.parse("   ") == nil)
        #expect(OCIImageReference.parse("ghcr.io/") == nil)
        #expect(OCIImageReference.parse("ghcr.io/acme/worker@sha256:short") == nil)
        #expect(OCIImageReference.parse("ghcr.io/acme/worker:") == nil)
        #expect(OCIImageReference.parse("ghcr.io/acme/worker:bad tag") == nil)
    }

    @Test("Docker Hub API host differs from the reference host")
    func hubAPIBaseURL() {
        let ref = OCIImageReference.parse("alpine")
        #expect(ref?.apiBaseURL == "https://registry-1.docker.io")
    }

    @Test("Loopback registries get plain HTTP, everything else HTTPS")
    func apiSchemes() {
        #expect(OCIImageReference.parse("localhost:5000/app")?.apiBaseURL == "http://localhost:5000")
        #expect(OCIImageReference.parse("127.0.0.1:5000/app")?.apiBaseURL == "http://127.0.0.1:5000")
        #expect(OCIImageReference.parse("127.0.0.2:5000/app")?.apiBaseURL == "http://127.0.0.2:5000")
        #expect(OCIImageReference.parse("ghcr.io/acme/worker")?.apiBaseURL == "https://ghcr.io")
    }

    @Test("Loopback-lookalike hostnames never get the plain-HTTP allowance")
    func loopbackLookalikes() {
        #expect(OCIImageReference.parse("127.evil.com/app")?.apiBaseURL == "https://127.evil.com")
        let dottedLookalike = OCIImageReference.parse("127.0.0.1.example/app")
        #expect(dottedLookalike?.apiBaseURL == "https://127.0.0.1.example")
        #expect(!OCIImageReference.isLoopbackHost("127.evil.com"))
        #expect(!OCIImageReference.isLoopbackHost("127.0.0.1.example:5000"))
        #expect(!OCIImageReference.isLoopbackHost("128.0.0.1"))
        #expect(OCIImageReference.isLoopbackHost("127.1.2.3:8443"))
        #expect(OCIImageReference.isLoopbackHost("LOCALHOST"))
    }

    @Test("Digest validation accepts only sha256 with 64 lowercase hex chars")
    func digestValidation() {
        #expect(OCIImageReference.isValidDigest(digest))
        #expect(!OCIImageReference.isValidDigest("sha256:ABC"))
        #expect(!OCIImageReference.isValidDigest("sha512:" + String(repeating: "a", count: 128)))
        #expect(!OCIImageReference.isValidDigest(String(repeating: "a", count: 64)))
        let uppercased = "sha256:" + String(repeating: "A", count: 64)
        #expect(!OCIImageReference.isValidDigest(uppercased))
    }
}
