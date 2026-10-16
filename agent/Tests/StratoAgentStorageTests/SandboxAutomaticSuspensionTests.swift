import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Automatic suspension durable guest fence")
struct SandboxAutomaticSuspensionTests {
    struct Fixture {
        let directory: String
        let store: SandboxSuspensionStore
        let record: SandboxSuspensionRecord
        init(protocolVersion: Int = 5, networked: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            store = SandboxSuspensionStore(directory: directory)
            var value = SandboxSuspensionRecord(
                sandboxId: UUID(), snapshotId: UUID(), generation: 7, activityEpoch: 3, jailUID: 12001,
                spec: SandboxSpec(
                    image: "fixture", cpus: 1, memoryBytes: 256 * 1024 * 1024,
                    network: networked ? NetworkSpec(network: "fixture", networkId: UUID()) : nil))
            value.guestFence = SandboxSuspensionGuestFence(
                request: SandboxAutomaticSuspensionFence(
                    operationId: UUID(), generation: 7,
                    activityRevision: 11, admissionToken: UUID(), guestProtocolVersion: protocolVersion),
                identityNonce: "fixture-identity")
            record = value
        }
        func cleanup() { try? FileManager.default.removeItem(atPath: directory) }
    }
    enum Injected: Error { case lostResponse, admissionRevoked }

    actor Transport: SandboxAutomaticSuspensionTransport {
        let store: SandboxSuspensionStore
        let token = UUID()
        var status: SandboxGuestFenceStatus = .absent
        var queries = 0
        var prepares = 0
        var releases = 0
        var losePrepareResponse = false
        var loseReleaseResponse = false
        var admissionValid = true
        var acknowledgeRelease = true
        init(store: SandboxSuspensionStore) { self.store = store }
        func configure(
            losePrepare: Bool = false, loseRelease: Bool = false, valid: Bool = true,
            acknowledge: Bool = true
        ) {
            losePrepareResponse = losePrepare
            loseReleaseResponse = loseRelease
            admissionValid = valid
            acknowledgeRelease = acknowledge
        }
        func prepare(_ context: SandboxSuspensionFenceContext) async throws -> UUID {
            let persisted = try store.load(sandboxId: context.sandboxId)
            #expect(persisted?.guestFence?.state == .preparePending)
            #expect(persisted?.snapshotId == context.checkpointId)
            #expect(persisted?.guestFence?.request == context.fence.request)
            prepares += 1
            status = .prepared(token)
            if losePrepareResponse { losePrepareResponse = false; throw Injected.lostResponse }
            return token
        }
        func query(_ context: SandboxSuspensionFenceContext) async throws -> SandboxGuestFenceStatus {
            queries += 1
            return status
        }
        func validateAdmission(_ context: SandboxSuspensionFenceContext) async throws {
            if !admissionValid { throw Injected.admissionRevoked }
        }
        func release(_ context: SandboxSuspensionFenceContext) async throws {
            #expect(try store.load(sandboxId: context.sandboxId)?.guestFence?.state == .releasePending)
            releases += 1
            if acknowledgeRelease { status = .released }
            if loseReleaseResponse { loseReleaseResponse = false; throw Injected.lostResponse }
        }
        func counts() -> (Int, Int) { (prepares, releases) }
        func queryCount() -> Int { queries }
        func resetToCheckpoint() { status = .prepared(token) }
        func replaceToken() { status = .prepared(UUID()) }
    }

    @Test func lostPrepareResponseReopensByOperationWithoutSecondFreeze() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        await transport.configure(losePrepare: true)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        await #expect(throws: Injected.self) { try await lifecycle.prepare(fixture.record) }
        let pending = try #require(try fixture.store.load(sandboxId: fixture.record.sandboxId))
        #expect(pending.guestFence?.state == .preparePending)
        #expect(pending.guestFence?.guestToken == nil)
        let restarted = SandboxAutomaticSuspensionLifecycle(
            store: SandboxSuspensionStore(directory: fixture.directory), transport: transport)
        let prepared = try await restarted.prepare(pending)
        #expect(prepared.guestFence?.state == .prepared)
        #expect(await transport.counts().0 == 1)
        try await restarted.validateDestruction(prepared)
    }

    @Test func rollbackReleasesLostPrepareTokenBeforeJournalCanBeRemoved() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        await transport.configure(losePrepare: true)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        await #expect(throws: Injected.self) { try await lifecycle.prepare(fixture.record) }
        let pending = try #require(try fixture.store.load(sandboxId: fixture.record.sandboxId))
        let released = try await lifecycle.release(pending)
        #expect(released.guestFence?.state == .released)
        #expect(released.guestFence?.guestToken == nil)
        #expect(released.guestFence?.blocksWorkloadAdmission == false)
    }

    @Test func lostReleaseResponseRetainsAdmissionBlockAcrossRestart() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        let prepared = try await lifecycle.prepare(fixture.record)
        await transport.configure(loseRelease: true)
        await #expect(throws: Injected.self) { try await lifecycle.release(prepared) }
        let pending = try #require(try fixture.store.load(sandboxId: fixture.record.sandboxId))
        #expect(pending.guestFence?.state == .releasePending)
        #expect(pending.guestFence?.blocksWorkloadAdmission == true)
        let restarted = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        let released = try await restarted.release(pending)
        #expect(released.guestFence?.state == .released)
        #expect(await transport.counts().1 == 2)
    }

    @Test func unacknowledgedReleaseCannotClearDurableBlock() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        let prepared = try await lifecycle.prepare(fixture.record)
        await transport.configure(acknowledge: false)
        await #expect(throws: SandboxSuspensionGuard.GateError.stale) { try await lifecycle.release(prepared) }
        #expect(try fixture.store.load(sandboxId: fixture.record.sandboxId)?.guestFence?.state == .releasePending)
    }

    @Test func revokedAdmissionAndReplacedGuestTokenRefuseDestruction() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        let prepared = try await lifecycle.prepare(fixture.record)
        await transport.configure(valid: false)
        await #expect(throws: Injected.self) { try await lifecycle.validateDestruction(prepared) }
        await transport.configure()
        await transport.replaceToken()
        await #expect(throws: SandboxSuspensionGuard.GateError.stale) { try await lifecycle.prepare(prepared) }
    }

    @Test func restoredCheckpointRequiresReleaseEvenAfterEarlierHostAcknowledgement() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        let prepared = try await lifecycle.prepare(fixture.record)
        let released = try await lifecycle.release(prepared)
        _ = try await lifecycle.release(released)
        #expect(await transport.counts().1 == 1)
        await transport.resetToCheckpoint()
        _ = try await lifecycle.release(released, restoredCopy: true)
        #expect(await transport.counts().1 == 2)
    }

    @Test func failedJournalWriteCannotFreezeGuest() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let badPath = fixture.directory + "/not-a-directory"
        try Data([0]).write(to: URL(fileURLWithPath: badPath))
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(
            store: SandboxSuspensionStore(directory: badPath), transport: transport)
        await #expect(throws: (any Error).self) { try await lifecycle.prepare(fixture.record) }
        #expect(await transport.counts().0 == 0)
    }

    @Test func v4AutomaticFenceRefusedWithoutTransportSideEffects() async throws {
        let fixture = try Fixture(protocolVersion: 4); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        await #expect(throws: SandboxSuspensionGuard.GateError.stale) { try await lifecycle.prepare(fixture.record) }
        #expect(await transport.counts().0 == 0)
        #expect(try fixture.store.load(sandboxId: fixture.record.sandboxId) == nil)
    }

    @Test func networkedGuestCannotPrepareBeforeIngressFencingExists() async throws {
        let fixture = try Fixture(networked: true); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        await #expect(throws: SandboxSuspensionGuard.GateError.stale) { try await lifecycle.prepare(fixture.record) }
        #expect(await transport.counts().0 == 0)
    }

    @Test func finalFenceCheckNeverQueriesPausedGuest() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let transport = Transport(store: fixture.store)
        let lifecycle = SandboxAutomaticSuspensionLifecycle(store: fixture.store, transport: transport)
        let prepared = try await lifecycle.prepare(fixture.record)
        let before = await transport.queryCount()
        try await lifecycle.validateDestruction(prepared)
        #expect(await transport.queryCount() == before)
    }

    @Test func legacyManualJournalDecodesWithoutFence() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var manual = fixture.record
        manual.guestFence = nil
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manual)) as? [String: Any])
        #expect(object["guestFence"] == nil)
        try fixture.store.save(manual)
        #expect(try fixture.store.load(sandboxId: manual.sandboxId)?.guestFence == nil)
    }
}
