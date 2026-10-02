import Foundation
import Testing
@testable import StratoShared

@Suite("Workload resource class contract")
struct WorkloadResourceClassTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, 0, 0.99, 64.01])
    func invalidCPURatio(_ ratio: Double) {
        #expect(throws: WorkloadResourceClassError.invalidPolicy) {
            try WorkloadResourceClassPolicy(kind: .burstable, cpuAllocationRatio: ratio, memoryHighPercent: 80)
        }
    }

    @Test(arguments: [0.0, 0.99, 16.01, Double.nan, .infinity])
    func invalidMemoryRatio(_ ratio: Double) {
        #expect(throws: WorkloadResourceClassError.invalidPolicy) {
            try WorkloadResourceClassPolicy(kind: .burstable, memoryAllocationRatio: ratio, memoryHighPercent: 80)
        }
    }

    @Test func boundsAndImmutableGuaranteed() throws {
        for weight in [0, 10001] {
            #expect(throws: WorkloadResourceClassError.invalidPolicy) {
                try WorkloadResourceClassPolicy(kind: .burstable, cpuWeight: weight, memoryHighPercent: 80)
            }
        }
        for percent in [0, 100] {
            #expect(throws: WorkloadResourceClassError.invalidPolicy) {
                try WorkloadResourceClassPolicy(kind: .burstable, memoryHighPercent: percent)
            }
        }
        #expect(throws: WorkloadResourceClassError.invalidPolicy) {
            try WorkloadResourceClassPolicy(kind: .guaranteed, cpuAllocationRatio: 2)
        }
        let maximum = try WorkloadResourceClassPolicy(
            kind: .burstable, cpuAllocationRatio: 64,
            memoryAllocationRatio: 16, cpuWeight: 10000, memoryHighPercent: 99)
        #expect(maximum.cpuWeight == 10000)
    }

    @Test func fractionalCPUAndUndiscountedOverhead() throws {
        let policy = try WorkloadResourceClassPolicy(
            kind: .burstable, cpuAllocationRatio: 4,
            memoryAllocationRatio: 2, memoryHighPercent: 80)
        #expect((0..<4).reduce(Int64(0)) { total, _ in total + policy.cpuMicroUnits(cpus: 1) } == 1_000_000)
        let memory = policy.memoryReservation(.init(guestBytes: 1025, backendOverheadBytes: 128))
        #expect(memory.guestBytes == 513)
        #expect(memory.backendOverheadBytes == 128)
        #expect(memory.effectiveBytes == 641)
        #expect(
            WorkloadResourceClassPolicy.guaranteed.memoryReservation(.init(guestBytes: .max, backendOverheadBytes: 1))
                .effectiveBytes == .max)
    }

    @Test func runtimeGrantDenominatorAndRounding() throws {
        let limits = try WorkloadResourceClassPolicy.burstable.runtimeLimits(guestBytes: 101, backendOverheadBytes: 9)
        #expect(limits.memoryHighBytes == 89)
        #expect(limits.memoryMaxBytes == 110)
        #expect(limits.cpuWeight == 100)
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try WorkloadResourceClassPolicy.burstable.runtimeLimits(guestBytes: .max, backendOverheadBytes: 1)
        }
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try WorkloadResourceClassPolicy.burstable.runtimeLimits(guestBytes: 1, backendOverheadBytes: 0)
        }
    }

    @Test func mixedRevisionGrowthPreservesExistingCommitment() throws {
        let original = try WorkloadResourceClassPolicy(
            kind: .burstable, cpuAllocationRatio: 4,
            memoryAllocationRatio: 2, memoryHighPercent: 80)
        let edited = try WorkloadResourceClassPolicy(
            kind: .burstable, cpuAllocationRatio: 2,
            memoryAllocationRatio: 4, memoryHighPercent: 70)
        let admitted = WorkloadAdmittedReservation(
            cpus: 1, memory: .init(guestBytes: 1024, backendOverheadBytes: 128), policy: original)
        let unchanged = admitted.growing(
            cpus: 1, memory: .init(guestBytes: 1024, backendOverheadBytes: 128), policy: edited)
        #expect(unchanged == admitted)
        let grown = admitted.growing(
            cpus: 2, memory: .init(guestBytes: 2048, backendOverheadBytes: 128), policy: edited)
        #expect(grown.cpuMicroUnits == 750_000)
        #expect(grown.discountedGuestBytes == 768)
        #expect(grown.effectiveMemoryBytes == 896)
        #expect(
            try WireProtocol.makeDecoder().decode(
                WorkloadAdmittedReservation.self, from: WireProtocol.makeEncoder().encode(grown)) == grown)
    }

    @Test func snapshotAndLegacySpecs() throws {
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID,
            siteID: UUID(), revision: 2, policy: .burstable)
        let spec = VMSpec(cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil), resourceClass: snapshot)
        let data = try WireProtocol.makeEncoder().encode(spec)
        let decoded = try WireProtocol.makeDecoder().decode(VMSpec.self, from: data)
        #expect(decoded.resourceClass == snapshot)
        let sandbox = SandboxSpec(image: "example.test/worker:v1", cpus: 1, memoryBytes: 1024, resourceClass: snapshot)
        #expect(
            try WireProtocol.makeDecoder().decode(SandboxSpec.self, from: WireProtocol.makeEncoder().encode(sandbox))
                .resourceClass == snapshot)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "resourceClass")
        #expect(
            try WireProtocol.makeDecoder().decode(VMSpec.self, from: JSONSerialization.data(withJSONObject: json))
                .resourceClass == nil)
        var classJSON = try #require(
            try JSONSerialization.jsonObject(with: WireProtocol.makeEncoder().encode(snapshot)) as? [String: Any])
        #expect(classJSON["kind"] as? String == "burstable")
        #expect(classJSON["policy"] == nil)
        classJSON["kind"] = "unknown"
        json["resourceClass"] = classJSON
        #expect(throws: (any Error).self) {
            try WireProtocol.makeDecoder().decode(VMSpec.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func freshAvailablePressureRequired() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(WorkloadResourceClassPolicy.guaranteed.admissionRefusal(telemetry: nil, now: now) == nil)
        #expect(WorkloadResourceClassPolicy.burstable.admissionRefusal(telemetry: nil, now: now) != nil)
        #expect(
            WorkloadResourceClassPolicy.burstable.admissionRefusal(
                telemetry: telemetry(now, cpu: 0, memory: 0), now: now) == nil)
        #expect(
            WorkloadResourceClassPolicy.burstable.admissionRefusal(
                telemetry: telemetry(now, cpu: 11, memory: 0), now: now)?.contains("CPU PSI") == true)
        #expect(
            WorkloadResourceClassPolicy.burstable.admissionRefusal(
                telemetry: telemetry(now, cpu: 0, memory: 6), now: now)?.contains("memory PSI") == true)
        #expect(
            WorkloadResourceClassPolicy.burstable.admissionRefusal(
                telemetry: telemetry(now.addingTimeInterval(-61), cpu: 0, memory: 0), now: now) != nil)
        #expect(
            WorkloadResourceClassPolicy.burstable.admissionRefusal(
                telemetry: telemetry(now.addingTimeInterval(1), cpu: 0, memory: 0), now: now) != nil)
        #expect(
            WorkloadResourceClassPolicy.burstable.admissionRefusal(
                telemetry: telemetry(now, cpu: nil, memory: 0), now: now) != nil)
    }

    private func telemetry(_ date: Date, cpu: Double?, memory: Double?) -> HostResourceTelemetry {
        func pressure(_ value: Double?) -> PressureStallTelemetry {
            guard let value else { return .unavailable }
            return .available(
                some: PressureStallSample(average10: value, average60: value, average300: value, totalMicroseconds: 0),
                full: nil)
        }
        return HostResourceTelemetry(
            sampledAt: date, health: .healthy, cpuPressure: pressure(cpu),
            memoryPressure: pressure(memory), ioPressure: .unavailable, swapTotalBytes: .unavailable,
            swapUsedBytes: .unavailable, zswapStoredBytes: .unavailable, zswapPoolBytes: .unavailable,
            zramUsedBytes: .unavailable, majorFaultsTotal: .unavailable, reclaimScannedPagesTotal: .unavailable,
            reclaimReclaimedPagesTotal: .unavailable, oomKillsTotal: .unavailable, mglruEnabled: .unavailable)
    }
}

@Suite("Resource class page-normalized enforcement")
struct WorkloadResourceClassPageTests {
    @Test func thresholdsDoNotCollapseAfterKernelPageParsing() throws {
        let policy = try WorkloadResourceClassPolicy(kind: .burstable, memoryHighPercent: 99)
        let raw = try policy.runtimeLimits(guestBytes: 10000, backendOverheadBytes: 0)
        let aligned = try raw.aligned(pageSizeBytes: 4096)
        #expect(raw.memoryHighBytes == 9900)
        #expect(raw.memoryMaxBytes == 10000)
        #expect(aligned.memoryHighBytes == 8192)
        #expect(aligned.memoryMaxBytes == 12288)
        #expect(aligned.memoryHighBytes / 1024 == 8)
        #expect(aligned.memoryMaxBytes / 1024 == 12)
    }

    @Test func invalidAndOverflowingAlignmentFailsClosed() throws {
        let raw = try WorkloadResourceClassPolicy.burstable.runtimeLimits(guestBytes: 10000, backendOverheadBytes: 0)
        for size: Int64 in [0, -1, 512, 4095, 65536] {
            #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) { try raw.aligned(pageSizeBytes: size) }
        }
        let extreme = try WorkloadResourceClassPolicy.burstable.runtimeLimits(guestBytes: .max, backendOverheadBytes: 0)
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) { try extreme.aligned(pageSizeBytes: 4096) }
    }

    @Test func partialBackendEvidenceIsInsufficient() {
        let partial = WorkloadResourceClassEnforcement(
            backend: .qemuVM, controllersDelegated: true,
            stableOwnership: true, preExecutionEnforcement: true, effectiveReadback: false)
        #expect(partial.supportsBurstable == false)
        #expect(
            WorkloadResourceClassEnforcement(
                backend: .jailedFirecrackerSandbox, controllersDelegated: true,
                stableOwnership: true, preExecutionEnforcement: true, effectiveReadback: true
            ).supportsBurstable)
    }
}
