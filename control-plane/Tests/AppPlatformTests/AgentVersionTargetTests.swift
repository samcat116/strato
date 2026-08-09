import Testing

@testable import App

@Suite("Agent version targets")
struct AgentVersionTargetTests {
    @Test("A dev target normalizes to nil, everything else passes through")
    func targetVersionNormalization() {
        #expect(AgentVersionTarget.normalize("dev") == nil)
        #expect(AgentVersionTarget.normalize("v1.2.3") == "v1.2.3")
        #expect(AgentVersionTarget.normalize("main") == "main")
    }

    @Test("A different agent version has an update available")
    func updateAvailableComparison() {
        #expect(AgentVersionTarget.updateAvailable(agentVersion: "v1.2.2", target: "v1.2.3"))
        #expect(AgentVersionTarget.updateAvailable(agentVersion: "1.0.0", target: "v1.2.3"))
        #expect(AgentVersionTarget.updateAvailable(agentVersion: "dev", target: "v1.2.3"))
        #expect(!AgentVersionTarget.updateAvailable(agentVersion: "v1.2.3", target: "v1.2.3"))
    }

    @Test("Aliases of the same build never flag an update")
    func updateAvailableAliasNormalization() {
        // Release tag: agents bake the v-prefixed ref, Helm feeds the bare
        // semver image tag back as the control plane's version.
        #expect(!AgentVersionTarget.updateAvailable(agentVersion: "v1.2.3", target: "1.2.3"))
        #expect(!AgentVersionTarget.updateAvailable(agentVersion: "1.2.3", target: "v1.2.3"))
        // Main branch: images are baked as "main" but published as main-<sha>.
        #expect(!AgentVersionTarget.updateAvailable(agentVersion: "main", target: "main-abc123def"))
        #expect(!AgentVersionTarget.updateAvailable(agentVersion: "main-abc123def", target: "main-0123456789"))
        // Non-aliases that merely resemble the alias shapes still compare.
        #expect(AgentVersionTarget.updateAvailable(agentVersion: "main-branch", target: "main"))
        #expect(AgentVersionTarget.updateAvailable(agentVersion: "vela", target: "ela"))
        #expect(AgentVersionTarget.updateAvailable(agentVersion: "v1.2.2", target: "1.2.3"))
    }

    @Test("No meaningful target means no update is available")
    func updateAvailableWithoutTarget() {
        #expect(!AgentVersionTarget.updateAvailable(agentVersion: "1.0.0", target: nil))
        #expect(!AgentVersionTarget.updateAvailable(agentVersion: "dev", target: nil))
    }
}
