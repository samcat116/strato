import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("burstable enforcement gate and readback")
struct BurstableRuntimeGateTests {
    private func snapshot(_ kind: WorkloadResourceClassKind) throws -> WorkloadResourceClassSnapshot {
        try WorkloadResourceClassSnapshot(
            classID: kind == .guaranteed
                ? WorkloadResourceClassSnapshot.guaranteedID : WorkloadResourceClassSnapshot.burstableID,
            siteID: UUID(), revision: 1, policy: kind == .guaranteed ? .guaranteed : .burstable)
    }

    @Test("every required capability is necessary and legacy guaranteed work remains supported")
    func capabilityGate() throws {
        try BurstableRuntimeGate.requireSupport(resourceClass: nil)
        try BurstableRuntimeGate.requireSupport(resourceClass: snapshot(.guaranteed))
        let burstable = try snapshot(.burstable)
        #expect(throws: ConvergenceError.self) {
            try BurstableRuntimeGate.requireSupport(resourceClass: burstable)
        }
        for mask in 0..<16 {
            let enforcement = WorkloadResourceClassEnforcement(
                backend: .jailedFirecrackerSandbox, controllersDelegated: mask & 1 != 0,
                stableOwnership: mask & 2 != 0, preExecutionEnforcement: mask & 4 != 0,
                effectiveReadback: mask & 8 != 0)
            if mask == 15 {
                try BurstableRuntimeGate.requireSupport(resourceClass: burstable, enforcement: enforcement)
            } else {
                do {
                    try BurstableRuntimeGate.requireSupport(resourceClass: burstable, enforcement: enforcement)
                    Issue.record("partial enforcement was accepted: \(mask)")
                } catch let error as ConvergenceError {
                    #expect(error.failureClassification == .blocked)
                }
            }
        }
    }

    @Test("readback requires exact aligned targets and unlimited CPU")
    func readback() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 10_000, backendOverheadBytes: 0, memoryHighPercent: 99, cpuWeight: 37)
        let root = "/sys/fs/cgroup/firecracker/owned-id"
        let valid = ["memory.high": "8192\n", "memory.max": "12288\n", "cpu.weight": "37\n", "cpu.max": "max 100000\n"]
        func sample(_ files: [String: String]) throws -> BurstableCgroupReadback {
            try #require(
                BurstableCgroupReadback.sample(ownedPath: root) { path in
                    guard path.hasPrefix(root + "/") else { Issue.record("read escaped owned boundary"); return nil }
                    return files[String(path.dropFirst(root.count + 1))]
                })
        }
        #expect(try sample(valid).matches(limits, pageSize: 4096))
        for control in valid.keys {
            var missing = valid
            missing.removeValue(forKey: control)
            #expect(try !sample(missing).matches(limits, pageSize: 4096))
        }
        for (control, value) in [
            ("memory.high", "max"), ("memory.max", "max"), ("memory.high", "0"),
            ("memory.max", "8192"), ("memory.max", "18446744073709551615"),
            ("cpu.weight", "10001"), ("cpu.max", "10000 100000"),
            ("cpu.max", "max"), ("cpu.max", "max invalid"), ("cpu.max", "max 0"),
        ] {
            var invalid = valid
            invalid[control] = value
            #expect(try !sample(invalid).matches(limits, pageSize: 4096))
        }
    }

    @Test("shared root and traversal cannot be mistaken for an owned boundary")
    func paths() {
        for path in [
            "/sys/fs/cgroup", "/sys/fs/cgroup/../other", "/sys/fs/cgroup/./vm",
            "/sys/fs/cgroup//vm", "/sys/fs/cgroup/vm/", "/sys/fs/cgroup-other/vm", "relative/vm",
        ] {
            let result = BurstableCgroupReadback.sample(ownedPath: path) { _ in
                Issue.record("invalid path triggered a controller read")
                return nil
            }
            #expect(result == nil)
        }
    }
}
