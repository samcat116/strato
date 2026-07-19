import Foundation
import Testing

@testable import StratoShared

@Suite("Sandbox Protocol Tests")
struct SandboxProtocolTests {

    private func makeFullSpec() -> SandboxSpec {
        SandboxSpec(
            image: "ghcr.io/acme/worker:v3",
            imageDigest: "sha256:6c3c624b58dbbcd3c0dd82b4c53f04194d1247c6eebdaab7c610cf7d66709b3b",
            cpus: 2,
            memoryBytes: 1 << 30,
            entrypoint: ["/usr/bin/worker"],
            cmd: ["--queue", "default"],
            env: ["LOG_LEVEL": "debug", "QUEUE_URL": "amqp://mq"],
            workingDir: "/srv",
            network: NetworkSpec(
                network: "default",
                networkId: Fixtures.uuidB,
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.20",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1"
            )
        )
    }

    @Test("DesiredStateMessage carries sandboxes through the envelope")
    func desiredSandboxRoundTrip() throws {
        let sandboxId = UUID()
        let message = DesiredStateMessage(
            syncId: "sync-sbx",
            vms: [],
            sandboxes: [
                DesiredSandboxState(
                    sandboxId: sandboxId,
                    spec: makeFullSpec(),
                    desiredStatus: .running,
                    generation: 3,
                    registryCredential: RegistryCredential(
                        registry: "ghcr.io",
                        username: "pull-bot",
                        password: "short-lived-token",
                        expiresAt: Fixtures.laterDate,
                        bearer: true
                    )
                )
            ]
        )
        let decoded = try throughEnvelope(message)

        #expect(decoded.sandboxes.count == 1)
        let sandbox = try #require(decoded.sandboxes.first)
        #expect(sandbox.sandboxId == sandboxId)
        #expect(sandbox.desiredStatus == .running)
        #expect(sandbox.generation == 3)
        #expect(sandbox.spec.image == "ghcr.io/acme/worker:v3")
        #expect(sandbox.spec.imageDigest?.hasPrefix("sha256:") == true)
        #expect(sandbox.spec.cpus == 2)
        #expect(sandbox.spec.memoryBytes == 1 << 30)
        #expect(sandbox.spec.entrypoint == ["/usr/bin/worker"])
        #expect(sandbox.spec.cmd == ["--queue", "default"])
        #expect(sandbox.spec.env == ["LOG_LEVEL": "debug", "QUEUE_URL": "amqp://mq"])
        #expect(sandbox.spec.workingDir == "/srv")
        #expect(sandbox.spec.network?.network == "default")
        #expect(sandbox.spec.network?.ipAddress == "192.168.1.20")
        #expect(sandbox.registryCredential?.registry == "ghcr.io")
        #expect(sandbox.registryCredential?.username == "pull-bot")
        #expect(sandbox.registryCredential?.password == "short-lived-token")
        #expect(sandbox.registryCredential?.expiresAt == Fixtures.laterDate)
        #expect(sandbox.registryCredential?.bearer == true)
    }

    @Test("RegistryCredential without a bearer key decodes (pre-token control planes)")
    func registryCredentialBearerBackCompat() throws {
        let legacy = #"{"registry":"ghcr.io","username":"pull-bot","password":"pw"}"#
        let decoded = try JSONDecoder().decode(RegistryCredential.self, from: Data(legacy.utf8))
        #expect(decoded.bearer == nil)
        #expect(decoded.expiresAt == nil)
        #expect(decoded.password == "pw")
    }

    @Test("Minimal SandboxSpec round-trips: overrides nil, no network, no credential")
    func minimalSpecRoundTrip() throws {
        let state = DesiredSandboxState(
            sandboxId: Fixtures.uuidA,
            spec: SandboxSpec(image: "docker.io/library/alpine:3.20", cpus: 1, memoryBytes: 256 << 20),
            desiredStatus: .stopped,
            generation: 1
        )
        let decoded = try roundTrip(state)

        #expect(decoded.spec.image == "docker.io/library/alpine:3.20")
        #expect(decoded.spec.imageDigest == nil)
        #expect(decoded.spec.entrypoint == nil)
        #expect(decoded.spec.cmd == nil)
        #expect(decoded.spec.env.isEmpty)
        #expect(decoded.spec.workingDir == nil)
        #expect(decoded.spec.network == nil)
        #expect(decoded.registryCredential == nil)
        #expect(decoded.desiredStatus == .stopped)
    }

    @Test("Fork restore reference round-trips in spec and desired state")
    func restoreReferenceRoundTrip() throws {
        let restore = SandboxSnapshotRef(
            snapshotId: Fixtures.uuidA,
            sourceSandboxId: Fixtures.uuidB)
        let state = DesiredSandboxState(
            sandboxId: UUID(),
            spec: SandboxSpec(
                image: "ghcr.io/acme/worker:v3",
                cpus: 2,
                memoryBytes: 1 << 30,
                restoreFrom: restore),
            desiredStatus: .running,
            generation: 1,
            restoreFrom: restore)

        let decoded = try roundTrip(state)
        #expect(decoded.restoreFrom == restore)
        #expect(decoded.spec.restoreFrom == restore)
    }

    @Test("Sandbox fields actually reach the wire")
    func sandboxKeysEncoded() throws {
        let message = DesiredStateMessage(syncId: "s", vms: [])
        let keys = try encodedKeys(message)
        #expect(keys.contains("sandboxes"))

        let report = ObservedStateReport(agentId: "a", vms: [], resources: Fixtures.resources)
        let reportKeys = try encodedKeys(report)
        #expect(reportKeys.contains("sandboxes"))
    }

    @Test("DesiredStateMessage from a pre-sandbox control plane decodes sandboxes to []")
    func desiredSandboxesBackwardCompatible() throws {
        // A pre-v5 control plane emits no `sandboxes` key at all; the agent must
        // tolerate its absence rather than fail the whole sync — and must gate
        // teardown on supportsSandboxSync, not on this decoded-empty list.
        let legacy = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[]}
            """
        let decoded = try decodeJSON(DesiredStateMessage.self, from: legacy)
        #expect(decoded.sandboxes.isEmpty)
        #expect(decoded.syncId == "s")
    }

    @Test("ObservedStateReport carries sandbox observations through the envelope")
    func observedSandboxRoundTrip() throws {
        let report = ObservedStateReport(
            agentId: "agent-1",
            vms: [],
            sandboxes: [
                ObservedSandboxState(
                    sandboxId: Fixtures.uuidA,
                    status: .exited,
                    observedGeneration: 5,
                    exitCode: 137
                ),
                ObservedSandboxState(
                    sandboxId: Fixtures.uuidB,
                    status: .starting,
                    observedGeneration: 0,
                    convergencePhase: "pulling image",
                    lastError: "previous attempt: registry unreachable",
                    failedGeneration: 2
                ),
            ],
            resources: Fixtures.resources
        )
        let decoded = try throughEnvelope(report)

        #expect(decoded.sandboxes.count == 2)
        #expect(decoded.sandboxes[0].sandboxId == Fixtures.uuidA)
        #expect(decoded.sandboxes[0].status == .exited)
        #expect(decoded.sandboxes[0].observedGeneration == 5)
        #expect(decoded.sandboxes[0].exitCode == 137)
        #expect(decoded.sandboxes[1].status == .starting)
        #expect(decoded.sandboxes[1].convergencePhase == "pulling image")
        #expect(decoded.sandboxes[1].lastError == "previous attempt: registry unreachable")
        #expect(decoded.sandboxes[1].failedGeneration == 2)
        #expect(decoded.sandboxes[1].exitCode == nil)
    }

    @Test("ObservedStateReport from a pre-sandbox agent decodes sandboxes to []")
    func observedSandboxesBackwardCompatible() throws {
        let legacy = """
            {"requestId":"r","timestamp":0,"agentId":"agent-1","vms":[],
             "resources":{"totalCPU":8,"availableCPU":4,"totalMemory":16,"availableMemory":8,
                          "totalDisk":100,"availableDisk":50}}
            """
        let decoded = try decodeJSON(ObservedStateReport.self, from: legacy)
        #expect(decoded.sandboxes.isEmpty)
        #expect(decoded.agentId == "agent-1")
    }

    @Test("DesiredSandboxStatus decoding is strict: unknown values fail the sync")
    func desiredStatusStrictDecoding() throws {
        // Misinterpreting a desired status could stop or delete a running
        // workload, so — like DesiredVMStatus — there is no tolerant fallback.
        #expect(throws: (any Error).self) {
            _ = try decodeJSON(DesiredSandboxStatus.self, from: "\"Hibernated\"")
        }
    }

    @Test("SandboxStatus decoding is tolerant: unknown values become .unknown")
    func observedStatusTolerantDecoding() throws {
        let decoded = try decodeJSON(SandboxStatus.self, from: "\"Snapshotting\"")
        #expect(decoded == .unknown)
    }

    @Test("Desired sandbox status satisfaction mapping")
    func desiredStatusSatisfaction() {
        #expect(DesiredSandboxStatus.running.isSatisfied(by: .running))
        #expect(!DesiredSandboxStatus.running.isSatisfied(by: .stopped))
        #expect(!DesiredSandboxStatus.running.isSatisfied(by: .starting))
        // A workload that ran to completion fulfilled "running" — no restart
        // policy in phase 1, so the reconciler must not relaunch it forever.
        #expect(DesiredSandboxStatus.running.isSatisfied(by: .exited))
        #expect(DesiredSandboxStatus.stopped.isSatisfied(by: .stopped))
        #expect(DesiredSandboxStatus.stopped.isSatisfied(by: .exited))
        #expect(!DesiredSandboxStatus.stopped.isSatisfied(by: .running))
        // Absence is confirmed by omission from the observed set, never by a status.
        for status in SandboxStatus.allCases {
            #expect(!DesiredSandboxStatus.absent.isSatisfied(by: status))
        }
    }

    @Test("Only starting/stopping are transitional")
    func transitionalStatuses() {
        for status in SandboxStatus.allCases {
            let expected = status == .starting || status == .stopping
            #expect(status.isTransitional == expected)
        }
    }

    @Test("Sandbox-sync support is keyed on protocol version 5")
    func sandboxSyncVersionGate() {
        // A v4 control plane omits `sandboxes`; the agent must not treat the
        // decoded-empty list as an authoritative teardown of all sandboxes.
        #expect(!WireProtocol.supportsSandboxSync(4))
        #expect(WireProtocol.supportsSandboxSync(5))
        #expect(WireProtocol.supportsSandboxSync(WireProtocol.currentVersion))
    }
}
