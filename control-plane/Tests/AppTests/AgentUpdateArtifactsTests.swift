import StratoShared
import Testing

@testable import App

@Suite("Agent Update Artifact Resolution")
struct AgentUpdateArtifactsTests {

    // MARK: - Release tags

    @Test("bare semver versions gain the v prefix tags carry")
    func bareVersionGainsPrefix() {
        #expect(AgentUpdateArtifacts.releaseTag(for: "1.2.3") == "v1.2.3")
    }

    @Test("already-tagged versions pass through")
    func taggedVersionPassesThrough() {
        #expect(AgentUpdateArtifacts.releaseTag(for: "v1.2.3") == "v1.2.3")
    }

    @Test("non-semver values pass through untouched")
    func nonSemverPassesThrough() {
        #expect(AgentUpdateArtifacts.releaseTag(for: "main") == "main")
    }

    // MARK: - Asset URLs

    @Test("asset URL follows the install.sh naming convention per OS/arch")
    func assetURLConvention() {
        let url = AgentUpdateArtifacts.assetURL(
            targetVersion: "1.2.3",
            operatingSystem: .linux,
            architecture: .x86_64,
            baseURL: "https://github.com/samcat116/strato/releases/download"
        )
        #expect(
            url == "https://github.com/samcat116/strato/releases/download/v1.2.3/strato-linux-x86_64.tar.gz")

        let arm = AgentUpdateArtifacts.assetURL(
            targetVersion: "v2.0.0",
            operatingSystem: .macos,
            architecture: .arm64,
            baseURL: "https://mirror.internal/strato/"
        )
        // Trailing slash on the base collapses; the tag is not re-prefixed.
        #expect(arm == "https://mirror.internal/strato/v2.0.0/strato-macos-arm64.tar.gz")
    }

    @Test("main-branch targets have no release assets and resolve to nil")
    func mainBuildsResolveToNil() {
        // Both the baked form ("main") and the published-tag form
        // ("main-<sha>") collapse to main and must refuse URL resolution.
        let baked = AgentUpdateArtifacts.assetURL(
            targetVersion: "main", operatingSystem: .linux, architecture: .x86_64)
        #expect(baked == nil)
        let tagged = AgentUpdateArtifacts.assetURL(
            targetVersion: "main-abc123def", operatingSystem: .linux, architecture: .x86_64)
        #expect(tagged == nil)
    }

    // MARK: - Checksum sidecar parsing

    @Test("parses the sha256sum sidecar format")
    func parsesSidecarFormat() {
        let digest = String(repeating: "ab", count: 32)
        #expect(AgentUpdateArtifacts.parseChecksum("\(digest)  strato-linux-x86_64.tar.gz\n") == digest)
        // A bare digest with no filename is fine too.
        #expect(AgentUpdateArtifacts.parseChecksum("  \(digest)\n") == digest)
        // Uppercase digests normalize to lowercase for comparison.
        #expect(AgentUpdateArtifacts.parseChecksum(digest.uppercased()) == digest)
    }

    @Test("rejects bodies that don't lead with a sha256 digest")
    func rejectsNonDigests() {
        #expect(AgentUpdateArtifacts.parseChecksum("") == nil)
        #expect(AgentUpdateArtifacts.parseChecksum("<html>Not Found</html>") == nil)
        // Too short (a sha1), and non-hex characters.
        #expect(AgentUpdateArtifacts.parseChecksum(String(repeating: "ab", count: 20)) == nil)
        #expect(AgentUpdateArtifacts.parseChecksum(String(repeating: "zz", count: 32)) == nil)
    }
}
