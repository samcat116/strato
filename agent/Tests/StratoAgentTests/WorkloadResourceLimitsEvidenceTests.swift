import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("workload limit evidence")
struct WorkloadResourceLimitsEvidenceTests {
    @Test("aligned matching files require independent ownership before acknowledgement")
    func acknowledgement() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 10_000, backendOverheadBytes: 0, memoryHighPercent: 99, cpuWeight: 37)
        let path = "/sys/fs/cgroup/firecracker/id"
        var files = ["memory.high": "8192", "memory.max": "12288", "cpu.weight": "37", "cpu.max": "max 100000"]
        func sample(_ owner: Bool?) -> WorkloadResourceLimitsEvidence {
            .sample(limits: limits, ownedPath: path, pageSize: 4096, ownershipVerified: owner) {
                files[String($0.dropFirst(path.count + 1))]
            }
        }
        #expect(sample(nil).desired.memoryHighBytes == 9900)
        #expect(sample(nil).alignedTarget?.memoryHighBytes == 8192)
        #expect(sample(nil).controlsMatchTarget.value == true)
        #expect(sample(nil).enforcementAcknowledged.availability == .unavailable)
        #expect(sample(nil).ownedCgroupPath == nil)
        #expect(sample(true).enforcementAcknowledged.value == true)
        #expect(sample(true).ownedCgroupPath == path)
        #expect(sample(false).enforcementAcknowledged.value == false)
        files["memory.max"] = "max"
        #expect(sample(true).memoryMaxUnlimited.value == true)
        #expect(sample(true).appliedMemoryMaxBytes.availability == .unavailable)
        #expect(sample(true).enforcementAcknowledged.value == false)
        files["memory.max"] = "12288"
        files.removeValue(forKey: "cpu.max")
        #expect(sample(true).cpuQuotaUnlimited.availability == .unavailable)
        #expect(sample(true).enforcementAcknowledged.availability == .unavailable)
        files["cpu.max"] = "1000 100000"
        #expect(sample(true).cpuQuotaUnlimited.value == false)
        #expect(sample(true).enforcementAcknowledged.value == false)
    }

    @Test("missing boundaries stay unknown and canonical integers survive evidence serialization")
    func unavailableAndNativeIntegers() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 9_007_199_254_741_024, backendOverheadBytes: 4096, memoryHighPercent: 80, cpuWeight: 100)
        let evidence = WorkloadResourceLimitsEvidence.sample(limits: limits, ownedPath: nil, pageSize: 4096)
        #expect(evidence.appliedMemoryMaxBytes.availability == .unavailable)
        #expect(evidence.enforcementAcknowledged.availability == .unavailable)
        let restored = try WireProtocol.makeDecoder().decode(
            WorkloadResourceLimitsEvidence.self, from: WireProtocol.makeEncoder().encode(evidence))
        #expect(restored == evidence)
        #expect(restored.desired.memoryMaxBytes == 9_007_199_254_745_120)
    }
}
