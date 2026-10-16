import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore
@testable import StratoAgentDomainXML

@Suite("burstable lifecycle evidence")
struct BurstableLifecycleTests {
    private func limits(_ guest: Int64) throws -> BurstableResourceLimits {
        try BurstableResourceLimits(
            guestGrantBytes: guest, backendOverheadBytes: 4096, memoryHighPercent: 80, cpuWeight: 37)
    }

    @Test("restored sizing refuses CPU, RAM, unit rounding and overflow mismatches")
    func restoredGrant() throws {
        try BurstableGuestGrant.verify(cpuCount: 2, memoryMiB: 512, admittedCPUs: 2, admittedBytes: 512 * 1024 * 1024)
        for (cpu, memory, grant) in [
            (1, 512, Int64(512 * 1024 * 1024)), (2, 513, Int64(512 * 1024 * 1024)),
            (2, 512, Int64(512 * 1024 * 1024 + 1)), (2, Int.max, Int64.max),
        ] {
            #expect(throws: ConvergenceError.self) {
                try BurstableGuestGrant.verify(cpuCount: cpu, memoryMiB: memory, admittedCPUs: 2, admittedBytes: grant)
            }
        }
    }

    @Test("growth widens under existing pressure and shrink lowers containment after guest acknowledgement")
    func transitionOrder() async throws {
        for growing in [true, false] {
            let old = try limits(growing ? 16384 : 32768)
            let next = try limits(growing ? 32768 : 16384)
            var events: [String] = []
            try await BurstableRuntimeTransition.apply(
                current: old, target: next, pageSize: 4096,
                setHigh: { _ in events.append("high") },
                setMaximum: { _ in events.append("max") },
                setWeight: { _ in events.append("weight") },
                resizeGuest: { events.append("guest") },
                verify: { events.append($0 == old ? "verify-old" : "verify-new") })
            #expect(
                events
                    == (growing
                        ? ["verify-old", "max", "high", "weight", "verify-new", "guest", "verify-new"]
                        : ["verify-old", "guest", "high", "max", "weight", "verify-new"]))
        }
    }

    @Test("each failed acknowledgement stops later mutations and never removes containment")
    func failedTransition() async throws {
        struct Refused: Error {}
        for growing in [true, false] {
            let old = try limits(growing ? 16384 : 32768)
            let next = try limits(growing ? 32768 : 16384)
            let expected =
                growing
                ? ["verify", "max", "high", "weight", "verify", "guest", "verify"]
                : ["verify", "guest", "high", "max", "weight", "verify"]
            for stop in expected.indices {
                var events: [String] = []
                func record(_ event: String) throws {
                    events.append(event)
                    if events.count == stop + 1 { throw Refused() }
                }
                await #expect(throws: Refused.self) {
                    try await BurstableRuntimeTransition.apply(
                        current: old, target: next, pageSize: 4096,
                        setHigh: { _ in try record("high") }, setMaximum: { _ in try record("max") },
                        setWeight: { _ in try record("weight") }, resizeGuest: { try record("guest") },
                        verify: { _ in try record("verify") })
                }
                #expect(events == Array(expected.prefix(stop + 1)))
            }
        }
    }

    @Test("interrupted grow and shrink converge from every acknowledged controller phase")
    func interruptedTransitionRetries() async throws {
        struct LostAcknowledgement: Error {}
        for growing in [true, false] {
            let current = try limits(growing ? 16384 : 32768)
            let target = try limits(growing ? 32768 : 16384)
            let old = try current.kernelMemoryBytes(pageSize: 4096)
            let next = try target.kernelMemoryBytes(pageSize: 4096)
            for failAt in 0..<(growing ? 7 : 6) {
                var high = old.high
                var maximum = old.maximum
                var weight = current.cpuWeight
                var guest = growing ? Int64(16384) : Int64(32768)
                let targetGuest = growing ? Int64(32768) : Int64(16384)
                var callback = 0
                var fail = true
                func acknowledge() throws {
                    defer { callback += 1 }
                    if fail && callback == failAt { throw LostAcknowledgement() }
                }
                func readback() throws -> BurstableCgroupReadback {
                    try #require(
                        BurstableCgroupReadback.sample(ownedPath: "/sys/fs/cgroup/owned/id") { path in
                            switch URL(fileURLWithPath: path).lastPathComponent {
                            case "memory.high": return String(high)
                            case "memory.max": return String(maximum)
                            case "cpu.weight": return String(weight)
                            case "cpu.max": return "max 100000"
                            default: return nil
                            }
                        })
                }
                func apply() async throws {
                    try await BurstableRuntimeTransition.apply(
                        current: current, target: target, pageSize: 4096,
                        setHigh: {
                            high = $0; try acknowledge()
                        },
                        setMaximum: {
                            maximum = $0; #expect(maximum >= guest + 4096); try acknowledge()
                        },
                        setWeight: {
                            weight = $0; try acknowledge()
                        },
                        resizeGuest: {
                            #expect(maximum >= targetGuest + 4096); guest = targetGuest; try acknowledge()
                        },
                        verify: { expected in
                            #expect(try readback().matches(expected, pageSize: 4096))
                            try acknowledge()
                        },
                        verifyExisting: { old, next in
                            #expect(try readback().matchesTransition(from: old, to: next, pageSize: 4096))
                            try acknowledge()
                        })
                }
                await #expect(throws: LostAcknowledgement.self) { try await apply() }
                #expect(high > 0 && maximum > high)
                fail = false
                try await apply()
                #expect(
                    high == next.high && maximum == next.maximum && guest == targetGuest && weight == target.cpuWeight)
            }
        }
    }

    @Test("adoption requires exact process membership and complete controller delegation")
    func ownership() throws {
        let root = "/sys/fs/cgroup/firecracker/id"
        let limits = try limits(16384)
        let bytes = try limits.kernelMemoryBytes(pageSize: 4096)
        var files = [
            root + "/memory.high": String(bytes.high), root + "/memory.max": String(bytes.maximum),
            root + "/cpu.weight": "37", root + "/cpu.max": "max 100000", root + "/cgroup.procs": "123\n",
            "/proc/123/cgroup": "0::/firecracker/id\n",
            "/sys/fs/cgroup/cgroup.controllers": "cpu memory io", "/sys/fs/cgroup/cgroup.subtree_control": "cpu memory",
        ]
        try BurstableCgroupEnforcement.requireDelegatedControllers { files[$0] }
        func verify() throws {
            try BurstableCgroupEnforcement.verify(
                processID: 123, ownedPath: root, expectedPath: root, limits: limits, pageSize: 4096
            ) { files[$0] }
        }
        try verify()
        files["/proc/123/cgroup"] = "0::/firecracker/other\n"
        #expect(throws: ConvergenceError.self) { try verify() }
        files["/proc/123/cgroup"] = "0::/firecracker/id/child\n"
        #expect(throws: ConvergenceError.self) { try verify() }
        files["/proc/123/cgroup"] = "0::/firecracker/id\n"
        files[root + "/cgroup.procs"] = "124"
        #expect(throws: ConvergenceError.self) { try verify() }
        for delegated in ["cpu", "memory", "", "io"] {
            files["/sys/fs/cgroup/cgroup.subtree_control"] = delegated
            #expect(throws: ConvergenceError.self) {
                try BurstableCgroupEnforcement.requireDelegatedControllers { files[$0] }
            }
        }
    }

    @Test("QEMU reads the authoritative root rather than an emulator leaf or another incarnation")
    func qemuIdentity() throws {
        let id = UUID().uuidString
        let root = "/sys/fs/cgroup/owned/\(id)"
        let plan = try limits(16384)
        let values = try plan.kernelMemoryBytes(pageSize: 4096)
        let stat = "123 (qemu system) S " + Array(repeating: "0", count: 18).joined(separator: " ") + " 777"
        var files = [
            "/pid": "123", "/proc/123/stat": stat, "/proc/123/cmdline": "qemu\0-uuid\0\(id)\0",
            "/proc/123/cgroup": "0::/owned/\(id)/emulator\n", root + "/cgroup.procs": "",
            root + "/emulator/cgroup.procs": "123",
            root + "/memory.high": String(values.high), root + "/memory.max": String(values.maximum),
            root + "/cpu.weight": "37", root + "/cpu.max": "max 100000",
        ]
        func verify() throws {
            try BurstableQEMUOwnership.verify(
                vmID: id, ownedPath: root, limits: plan, pageSize: 4096, pidFilePath: "/pid"
            ) {
                files[$0]
            }
        }
        try verify()
        files["/proc/123/cmdline"] = "qemu\0-uuid\0\(UUID().uuidString)\0"
        #expect(throws: ConvergenceError.self) { try verify() }
        files["/proc/123/cmdline"] = "qemu\0-uuid\0\(id)\0"
        var statReads = 0
        #expect(throws: ConvergenceError.self) {
            try BurstableQEMUOwnership.verify(
                vmID: id, ownedPath: root, limits: plan, pageSize: 4096, pidFilePath: "/pid"
            ) {
                if $0 == "/proc/123/stat" {
                    statReads += 1
                    return statReads == 1 ? stat : stat.replacingOccurrences(of: "777", with: "778")
                }
                return files[$0]
            }
        }
    }

    @Test("canonical snapshot survives persistent domain and checkpoint replay without touching other metadata")
    func persistedMetadata() throws {
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID, siteID: UUID(), revision: 9,
            policy: WorkloadResourceClassPolicy(kind: .burstable, cpuWeight: 37, memoryHighPercent: 80))
        let plan = try limits(16384)
        let source = "<domain><metadata><owner xmlns='urn:another'>keep</owner></metadata><vcpu>1</vcpu></domain>"
        let xml = try #require(
            try DomainBurstableTuning.updating(
                in: source, limits: plan, pageSize: 4096, resourceClass: snapshot, guestGrantBytes: 16384))
        #expect(xml.contains("<owner xmlns='urn:another'>keep</owner>"))
        #expect(try DomainBurstableTuning.resourceClass(in: xml) == snapshot)
        #expect(try DomainBurstableTuning.acknowledgedGuestGrant(in: xml) == 16384)
        #expect(
            try DomainBurstableTuning.updating(in: xml, limits: plan, pageSize: 4096, resourceClass: snapshot) == nil)
        let restored = try DomainBurstableTuning.snapshotDomainXML(in: "<domainsnapshot>\(xml)</domainsnapshot>")
        #expect(try DomainBurstableTuning.resourceClass(in: restored) == snapshot)
        #expect(throws: Error.self) {
            try DomainBurstableTuning.resourceClass(
                in: xml.replacingOccurrences(of: "urn:strato:runtime:resource-class:1", with: "urn:wrong"))
        }
    }
}
