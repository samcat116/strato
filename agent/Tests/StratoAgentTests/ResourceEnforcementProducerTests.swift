import Foundation
import StratoAgentCore
import StratoShared
import Testing

@Suite("resource enforcement producer")
struct ResourceEnforcementProducerTests {
    private let key = ResourceEnforcementProducer.Key(kind: .vm, id: UUID())
    private func application(generation: Int64 = 7, key: ResourceEnforcementProducer.Key? = nil) throws
        -> ResourceEnforcementProducer.Application
    {
        let policy = WorkloadResourceClassPolicy.burstable
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID, siteID: UUID(), revision: 3, policy: policy)
        let guest: Int64 = 512 * 1024 * 1024
        let backend: WorkloadResourceClassBackend = key?.kind == .sandbox ? .jailedFirecrackerSandbox : .qemuVM
        return .init(
            key: key ?? self.key, generation: generation, resourceClass: snapshot, backend: backend,
            reservation: .init(
                cpus: 2,
                memory: .init(
                    guestBytes: guest,
                    backendOverheadBytes: backend == .qemuVM
                        ? WorkloadMemoryReservation.defaultQEMUOverheadBytes
                        : WorkloadMemoryReservation.firecrackerOverheadBytes),
                policy: policy), guestBytes: guest)
    }
    private func accounting(
        _ application: ResourceEnforcementProducer.Application, inventory: Bool = true,
        memoryDelta: Int64 = 0, cpuDelta: Int64 = 0
    ) -> HostCapacitySnapshot {
        let amount = HostReservation(
            memoryBytes: application.reservation.effectiveMemoryBytes + memoryDelta,
            cpuMicroUnits: application.reservation.cpuMicroUnits + cpuDelta)
        return .init(
            total: .init(cpus: 8, memoryBytes: 8 * 1024 * 1024 * 1024), reserved: amount,
            inventoryKnown: inventory, workloadReservations: [application.key.id.uuidString: amount])
    }
    private func evidence(
        _ application: ResourceEnforcementProducer.Application, owner: Bool? = true,
        mutate: (inout [String: String]) -> Void = { _ in }
    ) throws -> WorkloadResourceLimitsEvidence {
        let limits = try #require(
            try BurstableResourceLimits.plan(
                resourceClass: application.resourceClass,
                guestGrantBytes: application.guestBytes,
                backendOverheadBytes: application.reservation.backendOverheadBytes))
        let target = try limits.kernelMemoryBytes(pageSize: 4096)
        let path = "/sys/fs/cgroup/fixture/owned"
        var files = [
            path + "/memory.high": String(target.high), path + "/memory.max": String(target.maximum),
            path + "/cpu.weight": String(limits.cpuWeight), path + "/cpu.max": "max 100000",
        ]
        mutate(&files)
        return .sample(limits: limits, ownedPath: path, pageSize: 4096, ownershipVerified: owner) { files[$0] }
    }
    private func finish(
        _ producer: inout ResourceEnforcementProducer, _ application: ResourceEnforcementProducer.Application,
        evidence: WorkloadResourceLimitsEvidence?, inventory: Bool = true, memoryDelta: Int64 = 0, cpuDelta: Int64 = 0
    ) throws -> ResourceEnforcementSnapshot {
        let raw = accounting(application, inventory: inventory, memoryDelta: memoryDelta, cpuDelta: cpuDelta)
        let result = producer.finish(
            producer.capture(), before: raw, after: raw,
            ledgerRevisionBefore: 0, ledgerRevisionAfter: 0, inventoryStable: true,
            evidence: evidence.map { [application.key: $0] } ?? [:], sampledAt: Date(), pageSize: 4096)
        return try #require(result)
    }
    @Test("only exact, settled, running VM observations can authorize acknowledgement")
    func vmObservationEligibility() throws {
        let app = try application()
        let valid = ObservedVMState(vmId: key.id, status: .running, observedGeneration: app.generation)
        #expect(ResourceEnforcementProducer.canAcknowledge(valid, application: app))
        for status in VMStatus.allCases where status != .running {
            #expect(
                !ResourceEnforcementProducer.canAcknowledge(
                    ObservedVMState(vmId: key.id, status: status, observedGeneration: app.generation), application: app)
            )
        }
        let invalid = [
            ObservedVMState(vmId: UUID(), status: .running, observedGeneration: app.generation),
            ObservedVMState(vmId: key.id, status: .running, observedGeneration: app.generation - 1),
            ObservedVMState(
                vmId: key.id, status: .running, observedGeneration: app.generation, convergencePhase: "resizing"),
            ObservedVMState(vmId: key.id, status: .running, observedGeneration: app.generation, convergencePhase: ""),
            ObservedVMState(vmId: key.id, status: .running, observedGeneration: app.generation, lastError: "failure"),
            ObservedVMState(vmId: key.id, status: .running, observedGeneration: app.generation, lastError: ""),
            ObservedVMState(
                vmId: key.id, status: .running, observedGeneration: app.generation, failedGeneration: app.generation),
            ObservedVMState(
                vmId: key.id, status: .running, observedGeneration: app.generation, failedGeneration: app.generation - 1
            ),
            ObservedVMState(
                vmId: key.id, status: .running, observedGeneration: app.generation, failureClassification: .blocked),
        ]
        for record in invalid { #expect(!ResourceEnforcementProducer.canAcknowledge(record, application: app)) }
    }

    @Test("only exact, settled, running sandbox observations can authorize acknowledgement")
    func sandboxObservationEligibility() throws {
        let sandboxKey = ResourceEnforcementProducer.Key(kind: .sandbox, id: key.id)
        let app = try application(key: sandboxKey)
        let valid = ObservedSandboxState(sandboxId: key.id, status: .running, observedGeneration: app.generation)
        #expect(ResourceEnforcementProducer.canAcknowledge(valid, application: app))
        for status in SandboxStatus.allCases where status != .running {
            #expect(
                !ResourceEnforcementProducer.canAcknowledge(
                    ObservedSandboxState(sandboxId: key.id, status: status, observedGeneration: app.generation),
                    application: app))
        }
        let invalid = [
            ObservedSandboxState(sandboxId: UUID(), status: .running, observedGeneration: app.generation),
            ObservedSandboxState(sandboxId: key.id, status: .running, observedGeneration: app.generation + 1),
            ObservedSandboxState(
                sandboxId: key.id, status: .running, observedGeneration: app.generation, convergencePhase: "restoring"),
            ObservedSandboxState(
                sandboxId: key.id, status: .running, observedGeneration: app.generation, lastError: "failure"),
            ObservedSandboxState(
                sandboxId: key.id, status: .running, observedGeneration: app.generation,
                failedGeneration: app.generation),
            ObservedSandboxState(
                sandboxId: key.id, status: .running, observedGeneration: app.generation,
                failedGeneration: app.generation - 1),
            ObservedSandboxState(
                sandboxId: key.id, status: .running, observedGeneration: app.generation, failureClassification: .blocked
            ),
        ]
        for record in invalid { #expect(!ResourceEnforcementProducer.canAcknowledge(record, application: app)) }
        #expect(!ResourceEnforcementProducer.canAcknowledge(valid, application: try application()))
    }

    @Test("successful convergence binds the complete canonical footprint to the same net accounting snapshot")
    func positive() throws {
        var producer = ResourceEnforcementProducer()
        let application = try application()
        producer.begin(key, generation: application.generation)
        producer.succeeded(application)
        let snapshot = try finish(&producer, application, evidence: evidence(application))
        let ack = try #require(snapshot.acknowledgements.first)
        #expect(snapshot.inventoryComplete && snapshot.sequence == 0)
        #expect(ack.appliedGeneration == application.generation && ack.resourceClass == application.resourceClass)
        #expect(ack.accountedReservation == application.reservation && ack.runtimeGuestBytes == application.guestBytes)
        #expect(ack.appliedLimits == (try ack.desiredLimits.aligned(pageSizeBytes: ack.pageSizeBytes)))
        #expect(accounting(application).available.cpuMicroUnits == 8_000_000 - ack.accountedReservation.cpuMicroUnits)
        let roundTrip = try WireProtocol.makeDecoder().decode(
            ResourceEnforcementSnapshot.self, from: WireProtocol.makeEncoder().encode(snapshot))
        #expect(roundTrip == snapshot)
    }
    @Test("unknown, failed, malformed and partial controls never acknowledge a footprint")
    func negativeEvidence() throws {
        let application = try application()
        let path = "/sys/fs/cgroup/fixture/owned"
        let samples: [WorkloadResourceLimitsEvidence?] = [
            nil, try evidence(application, owner: nil), try evidence(application, owner: false),
            try evidence(application) { $0[path + "/memory.high"] = "max" },
            try evidence(application) { $0[path + "/memory.max"] = "bad" },
            try evidence(application) { $0[path + "/memory.max"] = "1" },
            try evidence(application) { $0.removeValue(forKey: path + "/cpu.weight") },
            try evidence(application) { $0[path + "/cpu.weight"] = "99" },
            try evidence(application) { $0[path + "/cpu.max"] = "1000 100000" },
        ]
        for sample in samples {
            var producer = ResourceEnforcementProducer()
            producer.begin(key, generation: application.generation)
            producer.succeeded(application)
            #expect(try finish(&producer, application, evidence: sample).acknowledgements.isEmpty)
        }
    }
    @Test("incomplete inventory and CPU or memory footprint mismatches retain claims")
    func accountingRefusals() throws {
        let application = try application()
        var producer = ResourceEnforcementProducer()
        producer.begin(key, generation: application.generation)
        producer.succeeded(application)
        let evidence = try evidence(application)
        let unknown = try finish(&producer, application, evidence: evidence, inventory: false)
        #expect(!unknown.inventoryComplete && unknown.acknowledgements.isEmpty)
        #expect(try finish(&producer, application, evidence: evidence, memoryDelta: 1).acknowledgements.isEmpty)
        #expect(try finish(&producer, application, evidence: evidence, cpuDelta: 1).acknowledgements.isEmpty)
    }
    @Test("accounting or application mutation across asynchronous readback discards the capture")
    func captureFences() throws {
        let application = try application()
        var producer = ResourceEnforcementProducer()
        producer.begin(key, generation: application.generation)
        producer.succeeded(application)
        let token = producer.capture()
        let raw = accounting(application)
        let samples = [key: try evidence(application)]
        for (after, revision, stable) in [
            (accounting(application, memoryDelta: 1), UInt64(0), true), (raw, 1, true), (raw, 0, false),
        ] {
            #expect(
                producer.finish(
                    token, before: raw, after: after, ledgerRevisionBefore: 0, ledgerRevisionAfter: revision,
                    inventoryStable: stable, evidence: samples, sampledAt: Date(), pageSize: 4096) == nil)
        }
        producer.begin(key, generation: application.generation + 1)
        #expect(
            producer.finish(
                token, before: raw, after: raw, ledgerRevisionBefore: 0, ledgerRevisionAfter: 0,
                inventoryStable: true, evidence: samples, sampledAt: Date(), pageSize: 4096) == nil)
        producer.succeeded(application)  // stale completion cannot certify the new target.
        #expect(try finish(&producer, application, evidence: samples[key]).acknowledgements.isEmpty)
    }
    @Test("report sequences advance; restart and failed retries require new successful convergence")
    func replayRestart() throws {
        let application = try application()
        var producer = ResourceEnforcementProducer()
        producer.begin(key, generation: application.generation)
        producer.succeeded(application)
        let sample = try evidence(application)
        let first = try finish(&producer, application, evidence: sample)
        let second = try finish(&producer, application, evidence: sample)
        #expect(first.agentBootID == second.agentBootID && second.sequence == first.sequence + 1)
        producer.begin(key, generation: application.generation)
        #expect(try finish(&producer, application, evidence: sample).acknowledgements.isEmpty)
        producer = ResourceEnforcementProducer()
        #expect(producer.agentBootID != first.agentBootID)
        producer.succeeded(application)  // manifests/readback alone are not adoption.
        let restarted = try finish(&producer, application, evidence: sample)
        #expect(restarted.sequence == 0 && restarted.acknowledgements.isEmpty)
        producer.begin(key, generation: application.generation)
        producer.succeeded(application)
        #expect(try finish(&producer, application, evidence: sample).acknowledgements.count == 1)
    }
}
