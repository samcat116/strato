import Testing
import Foundation
import StratoShared
@testable import App

@Suite("URL signing — per-artifact")
struct URLSigningServiceArtifactTests {
    private let key = "test-signing-key-of-sufficient-length-1234567890"
    private let imageId = UUID()
    private let projectId = UUID()
    private let agent = "agent-1"

    /// Parses `expires` and `sig` out of a signed URL.
    private func params(_ url: String) -> (expires: Int, sig: String) {
        let comps = URLComponents(string: url)!
        let items = comps.queryItems ?? []
        let expires = Int(items.first { $0.name == "expires" }!.value!)!
        let sig = items.first { $0.name == "sig" }!.value!
        return (expires, sig)
    }

    private func path() -> String {
        "/api/projects/\(projectId)/images/\(imageId)/download"
    }

    @Test("A per-artifact signature verifies only for that artifact kind")
    func artifactSignatureIsScoped() {
        let url = URLSigningService.signImageDownloadURL(
            imageId: imageId, projectId: projectId, agentName: agent,
            baseURL: "http://cp", signingKey: key, artifactKind: .kernel)
        let (expires, sig) = params(url)

        // Correct kind verifies.
        #expect(URLSigningService.verifySignature(
            path: path(), imageId: imageId, projectId: projectId, agentName: agent,
            expires: expires, signature: sig, signingKey: key, artifactKind: .kernel))

        // A different kind must not verify against a kernel-scoped signature.
        #expect(!URLSigningService.verifySignature(
            path: path(), imageId: imageId, projectId: projectId, agentName: agent,
            expires: expires, signature: sig, signingKey: key, artifactKind: .rootfs))

        // Neither does the legacy (no-artifact) form.
        #expect(!URLSigningService.verifySignature(
            path: path(), imageId: imageId, projectId: projectId, agentName: agent,
            expires: expires, signature: sig, signingKey: key, artifactKind: nil))
    }

    @Test("A legacy (no-artifact) signature round-trips and excludes artifact forms")
    func legacySignatureRoundTrips() {
        let url = URLSigningService.signImageDownloadURL(
            imageId: imageId, projectId: projectId, agentName: agent,
            baseURL: "http://cp", signingKey: key)
        let (expires, sig) = params(url)

        #expect(!url.contains("artifact="))

        #expect(URLSigningService.verifySignature(
            path: path(), imageId: imageId, projectId: projectId, agentName: agent,
            expires: expires, signature: sig, signingKey: key))

        #expect(!URLSigningService.verifySignature(
            path: path(), imageId: imageId, projectId: projectId, agentName: agent,
            expires: expires, signature: sig, signingKey: key, artifactKind: .kernel))
    }
}
