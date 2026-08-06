import Foundation
import StratoShared
import Testing

@testable import App

/// The ETag the long-poll serves is a digest of the assembled payload rather
/// than a per-replica counter (STR-146). These pin the two properties that
/// makes it safe to compare across replicas: identical desired state digests
/// identically however many times it is assembled and wherever, and anything
/// that is genuinely different digests differently.
@Suite("Desired state digest")
struct DesiredStateDigestTests {

    private static let vmID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let otherVMID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private static let sandboxID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func vm(
        id: UUID = DesiredStateDigestTests.vmID,
        generation: Int64 = 1,
        status: DesiredVMStatus = .running
    ) -> DesiredVMState {
        DesiredVMState(
            vmId: id,
            hypervisorType: .qemu,
            spec: VMSpec(cpus: 2, memoryBytes: 1 << 31, diskBytes: 1 << 34, boot: .disk(firmware: nil)),
            desiredStatus: status,
            generation: generation)
    }

    private func message(
        vms: [DesiredVMState],
        sandboxes: [DesiredSandboxState] = [],
        desiredAgentUpdate: DesiredAgentUpdate? = nil
    ) -> DesiredStateMessage {
        DesiredStateMessage(
            vms: vms, sandboxes: sandboxes, desiredAgentUpdate: desiredAgentUpdate)
    }

    // MARK: Stability

    /// Every assembly mints fresh correlation ids and a fresh timestamp. If
    /// those reached the digest no two assemblies would ever agree, the ETag
    /// would never hit, and every poll would return a full payload — the
    /// design's failure mode of "correct but useless".
    @Test("Correlation ids and the assembly timestamp do not change the digest")
    func correlationNoiseExcluded() throws {
        let first = message(vms: [vm()])
        let second = DesiredStateMessage(
            requestId: UUID().uuidString,
            timestamp: Date(timeIntervalSince1970: 999_999),
            syncId: UUID().uuidString,
            vms: [vm()])

        #expect(try DesiredStateDigest.digest(of: first) == DesiredStateDigest.digest(of: second))
    }

    /// A re-minted registry token is a change in credential *material*, not in
    /// desired state. Including it would mean an agent running any sandbox
    /// never sees a 304 once its cached token turns over.
    @Test("A re-minted registry token does not change the digest")
    func registryTokenMaterialExcluded() throws {
        func sandbox(password: String, expiresAt: Date?) -> DesiredSandboxState {
            DesiredSandboxState(
                sandboxId: Self.sandboxID,
                spec: SandboxSpec(image: "ghcr.io/acme/worker:v1", cpus: 1, memoryBytes: 1 << 30),
                desiredStatus: .running,
                generation: 1,
                registryCredential: RegistryCredential(
                    registry: "ghcr.io", username: "token", password: password,
                    expiresAt: expiresAt, bearer: true))
        }

        let before = message(
            vms: [], sandboxes: [sandbox(password: "token-a", expiresAt: Date(timeIntervalSince1970: 100))])
        let after = message(
            vms: [], sandboxes: [sandbox(password: "token-b", expiresAt: Date(timeIntervalSince1970: 900))])

        #expect(try DesiredStateDigest.digest(of: before) == DesiredStateDigest.digest(of: after))
    }

    /// The artifact link is re-resolved on every assembly and may be presigned,
    /// so it churns on its own. `sha256` stays in the digest and pins the
    /// artifact's identity far better than a URL could.
    @Test("A re-resolved agent-update artifact URL does not change the digest")
    func agentUpdateURLExcluded() throws {
        func update(url: String) -> DesiredAgentUpdate {
            DesiredAgentUpdate(
                targetVersion: "1.2.3", artifactURL: url, sha256: "abc123", artifactKind: .binary)
        }

        let before = message(vms: [], desiredAgentUpdate: update(url: "https://cp/a?sig=one"))
        let after = message(vms: [], desiredAgentUpdate: update(url: "https://cp/a?sig=two"))

        #expect(try DesiredStateDigest.digest(of: before) == DesiredStateDigest.digest(of: after))
    }

    // MARK: Sensitivity

    @Test("A generation bump changes the digest")
    func generationBumpChangesDigest() throws {
        #expect(
            try DesiredStateDigest.digest(of: message(vms: [vm(generation: 1)]))
                != DesiredStateDigest.digest(of: message(vms: [vm(generation: 2)])))
    }

    @Test("A desired-status change changes the digest")
    func statusChangeChangesDigest() throws {
        #expect(
            try DesiredStateDigest.digest(of: message(vms: [vm(status: .running)]))
                != DesiredStateDigest.digest(of: message(vms: [vm(status: .shutdown)])))
    }

    @Test("Adding a workload changes the digest")
    func addedWorkloadChangesDigest() throws {
        let one = message(vms: [vm()])
        let two = message(vms: [vm(), vm(id: Self.otherVMID)])

        #expect(try DesiredStateDigest.digest(of: one) != DesiredStateDigest.digest(of: two))
    }

    /// The credential's *identity* is still load-bearing even though its
    /// material is not: repointing a sandbox at a different registry or user
    /// has to reach the agent.
    @Test("A different registry identity changes the digest")
    func registryIdentityIncluded() throws {
        func sandbox(registry: String) -> DesiredSandboxState {
            DesiredSandboxState(
                sandboxId: Self.sandboxID,
                spec: SandboxSpec(image: "ghcr.io/acme/worker:v1", cpus: 1, memoryBytes: 1 << 30),
                desiredStatus: .running,
                generation: 1,
                registryCredential: RegistryCredential(
                    registry: registry, username: "token", password: "same", bearer: true))
        }

        #expect(
            try DesiredStateDigest.digest(of: message(vms: [], sandboxes: [sandbox(registry: "ghcr.io")]))
                != DesiredStateDigest.digest(
                    of: message(vms: [], sandboxes: [sandbox(registry: "docker.io")])))
    }

    // MARK: Format

    @Test("The ETag is a quoted opaque token")
    func etagIsQuoted() throws {
        let etag = try DesiredStateDigest.etag(for: message(vms: [vm()]))
        #expect(etag.hasPrefix("\""))
        #expect(etag.hasSuffix("\""))
        #expect(etag.count == 66)  // 64 hex characters plus the quotes
    }
}
