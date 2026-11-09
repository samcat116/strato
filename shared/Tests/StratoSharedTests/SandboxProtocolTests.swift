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

        #expect(decoded._jsonSandboxes.count == 1)
        let sandbox = try #require(decoded._jsonSandboxes.first)
        #expect(sandbox._jsonSandboxId == sandboxId)
        #expect(sandbox._jsonDesiredStatus == .running)
        #expect(sandbox._jsonGeneration == 3)
        #expect(sandbox._jsonSpec._jsonImage == "ghcr.io/acme/worker:v3")
        #expect(sandbox._jsonSpec._jsonImageDigest?.hasPrefix("sha256:") == true)
        #expect(sandbox._jsonSpec._jsonCpus == 2)
        #expect(sandbox._jsonSpec._jsonMemoryBytes == 1 << 30)
        #expect(sandbox._jsonSpec._jsonEntrypoint == ["/usr/bin/worker"])
        #expect(sandbox._jsonSpec._jsonCmd == ["--queue", "default"])
        #expect(sandbox._jsonSpec._jsonEnv == ["LOG_LEVEL": "debug", "QUEUE_URL": "amqp://mq"])
        #expect(sandbox._jsonSpec._jsonWorkingDir == "/srv")
        #expect(sandbox._jsonSpec._jsonNetwork?._jsonNetwork == "default")
        #expect(sandbox._jsonSpec._jsonNetwork?._jsonIpAddress == "192.168.1.20")
        #expect(sandbox._jsonRegistryCredential?._jsonRegistry == "ghcr.io")
        #expect(sandbox._jsonRegistryCredential?._jsonUsername == "pull-bot")
        #expect(sandbox._jsonRegistryCredential?._jsonPassword == "short-lived-token")
        #expect(sandbox._jsonRegistryCredential?._jsonExpiresAt == Fixtures.laterDate)
        #expect(sandbox._jsonRegistryCredential?._jsonBearer == true)
    }

    @Test("RegistryCredential requires its authentication mode")
    func registryCredentialRequiresBearer() throws {
        let legacy = #"{"registry":"ghcr.io","username":"pull-bot","password":"pw"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RegistryCredential.self, from: Data(legacy.utf8))
        }
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

        #expect(decoded._jsonSpec._jsonImage == "docker.io/library/alpine:3.20")
        #expect(decoded._jsonSpec._jsonImageDigest == nil)
        #expect(decoded._jsonSpec._jsonEntrypoint == nil)
        #expect(decoded._jsonSpec._jsonCmd == nil)
        #expect(decoded._jsonSpec._jsonEnv.isEmpty)
        #expect(decoded._jsonSpec._jsonWorkingDir == nil)
        #expect(decoded._jsonSpec._jsonNetwork == nil)
        #expect(decoded._jsonRegistryCredential == nil)
        #expect(decoded._jsonDesiredStatus == .stopped)
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
            generation: 1)

        let decoded = try roundTrip(state)
        #expect(decoded._jsonSpec._jsonRestoreFrom == restore)
    }

    @Test("Captured facts advertise fork layout and decode legacy omission")
    func snapshotForkLayoutCompatibility() throws {
        let facts = ObservedSnapshotFacts(
            sizeBytes: 10,
            storagePath: "/snapshots/1",
            architecture: .x86_64,
            firecrackerVersion: "1.13.1",
            guestControlProtocolVersion: SandboxGuestControlProtocol.currentVersion,
            forkLayoutVersion: SandboxSnapshotForkLayout.currentVersion)
        let decoded = try roundTrip(facts)
        #expect(decoded._jsonForkLayoutVersion == SandboxSnapshotForkLayout.currentVersion)

        // Every field is optional and absence means "unknown", never "zero":
        // a footprint the agent could not measure must not silently become a
        // free one in quota accounting.
        let legacy = """
            {"sizeBytes":10,"memorySizeBytes":4,"vmstateSizeBytes":2,"rootfsSizeBytes":4,
             "storagePath":"/snapshots/1","firecrackerVersion":"1.13.1","architecture":"x86_64"}
            """
        let sparse = try decodeJSON(ObservedSnapshotFacts.self, from: legacy)
        #expect(sparse._jsonForkLayoutVersion == nil)
        #expect(sparse._jsonCpuTemplate == nil)
        #expect(sparse._jsonSizeBytes == 10)
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

    @Test("The current desired schema rejects a missing sandbox inventory")
    func desiredSandboxesAreRequired() {
        let malformed = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[],"networks":[],
             "networksAuthoritative":true,"tombstones":[],"volumes":[],"snapshots":[],
             "cephCredentialRevocations":[]}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(DesiredStateMessage.self, from: malformed)
        }
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
                    failedGeneration: 2,
                    failureClassification: .transient
                ),
            ],
            resources: Fixtures.resources
        )
        let decoded = try throughEnvelope(report)

        #expect(decoded._jsonSandboxes.count == 2)
        #expect(decoded._jsonSandboxes[0]._jsonSandboxId == Fixtures.uuidA)
        #expect(decoded._jsonSandboxes[0]._jsonStatus == .exited)
        #expect(decoded._jsonSandboxes[0]._jsonObservedGeneration == 5)
        #expect(decoded._jsonSandboxes[0]._jsonExitCode == 137)
        #expect(decoded._jsonSandboxes[1]._jsonStatus == .starting)
        #expect(decoded._jsonSandboxes[1]._jsonConvergencePhase == "pulling image")
        #expect(decoded._jsonSandboxes[1]._jsonLastError == "previous attempt: registry unreachable")
        #expect(decoded._jsonSandboxes[1]._jsonFailedGeneration == 2)
        #expect(decoded._jsonSandboxes[1]._jsonFailureClassification == .transient)
        #expect(decoded._jsonSandboxes[1]._jsonExitCode == nil)
    }

    @Test("The current observed schema rejects a missing sandbox inventory")
    func observedSandboxesAreRequired() {
        let malformed = """
            {"requestId":"r","timestamp":0,"agentId":"agent-1","vms":[],
             "resources":{"totalCPU":8,"availableCPU":4,"totalMemory":16,"availableMemory":8,
                          "totalDisk":100,"availableDisk":50},"unrecognized":[]}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(ObservedStateReport.self, from: malformed)
        }
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
        for status in SandboxStatus.knownCases {
            #expect(!DesiredSandboxStatus.absent.isSatisfied(by: status))
        }
    }

    @Test("starting and stopping are transitional")
    func transitionalStatuses() {
        #expect(SandboxStatus.starting.isTransitional)
        #expect(SandboxStatus.stopping.isTransitional)
        #expect(!SandboxStatus.running.isTransitional)
        #expect(!SandboxStatus.unknown.isTransitional)
    }
}
