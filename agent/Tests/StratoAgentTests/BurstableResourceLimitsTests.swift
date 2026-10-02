import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore
@testable import StratoAgentDomainXML

@Suite("burstable runtime limits")
struct BurstableResourceLimitsTests {
    @Test("admitted snapshot replay preserves planning and guaranteed snapshots require no rewrite")
    func admittedSnapshotReplay() throws {
        let siteID = UUID()
        let guest: Int64 = 1024 * 1024 * 1024
        let overhead: Int64 = 512 * 1024 * 1024
        let guaranteed = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.guaranteedID, siteID: siteID,
            revision: 1, policy: .guaranteed)
        #expect(
            try BurstableResourceLimits.plan(resourceClass: nil, guestGrantBytes: guest, backendOverheadBytes: overhead)
                == nil)
        #expect(
            try BurstableResourceLimits.plan(
                resourceClass: guaranteed, guestGrantBytes: guest, backendOverheadBytes: overhead) == nil)

        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID, siteID: siteID, revision: 3,
            policy: WorkloadResourceClassPolicy(kind: .burstable, cpuWeight: 37, memoryHighPercent: 70))
        let restored = try WireProtocol.makeDecoder().decode(
            WorkloadResourceClassSnapshot.self, from: WireProtocol.makeEncoder().encode(snapshot))
        let originalPlan = try #require(
            try BurstableResourceLimits.plan(
                resourceClass: snapshot, guestGrantBytes: guest, backendOverheadBytes: overhead))
        let adoptedPlan = try #require(
            try BurstableResourceLimits.plan(
                resourceClass: restored, guestGrantBytes: guest, backendOverheadBytes: overhead))
        #expect(originalPlan == adoptedPlan)
        #expect(originalPlan.cpuWeight == 37)
        #expect(originalPlan.memoryHighBytes == 1_288_490_188)
        #expect(
            originalPlan.memoryMaxBytes == QEMUMemoryCeiling.bytes(guestMemoryBytes: guest, overheadBytes: overhead))
    }

    @Test("guest pressure percentage does not discount backend allowance")
    func arithmetic() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 1024 * 1024 * 1024, backendOverheadBytes: 128 * 1024 * 1024,
            memoryHighPercent: 80, cpuWeight: 37)
        #expect(limits.memoryHighBytes == 993_211_187)
        #expect(limits.memoryMaxBytes == 1_207_959_552)
        #expect(
            try limits.jailerEntries(pageSize: 4096) == [
                "memory.high=993210368", "memory.max=1207959552", "cpu.weight=37",
            ])
        let libvirt = try limits.libvirtMemoryKibibytes(pageSize: 4096)
        #expect(libvirt.high == 969_932)
        #expect(libvirt.maximum == 1_179_648)
    }

    @Test("valid near-maximum grants do not overflow the percentage multiplication")
    func largeGrant() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: .max, backendOverheadBytes: 0, memoryHighPercent: 99, cpuWeight: 10000)
        #expect(limits.memoryHighBytes == 9_131_138_316_486_228_048)
        #expect(limits.memoryMaxBytes == .max)
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try BurstableResourceLimits(
                guestGrantBytes: .max, backendOverheadBytes: 1, memoryHighPercent: 99, cpuWeight: 1)
        }
    }

    @Test("invalid policies and unrepresentable thresholds refuse enforcement")
    func invalid() {
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try BurstableResourceLimits(
                guestGrantBytes: 0, backendOverheadBytes: 1, memoryHighPercent: 80, cpuWeight: 100)
        }
        #expect(throws: WorkloadResourceClassError.invalidPolicy) {
            try BurstableResourceLimits(
                guestGrantBytes: 1024, backendOverheadBytes: 0, memoryHighPercent: 100, cpuWeight: 100)
        }
        #expect(throws: WorkloadResourceClassError.invalidPolicy) {
            try BurstableResourceLimits(
                guestGrantBytes: 1024, backendOverheadBytes: 0, memoryHighPercent: 80, cpuWeight: 0)
        }
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try BurstableResourceLimits(
                guestGrantBytes: 1, backendOverheadBytes: 0, memoryHighPercent: 80, cpuWeight: 100)
        }
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try BurstableResourceLimits(
                guestGrantBytes: 1024, backendOverheadBytes: 0, memoryHighPercent: 80, cpuWeight: 100
            )
            .libvirtMemoryKibibytes(pageSize: 4096)
        }
    }

    @Test("page alignment preserves the pressure interval that KiB-only rounding can collapse")
    func pageQuantization() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 10_000, backendOverheadBytes: 0, memoryHighPercent: 99, cpuWeight: 100)
        let bytes = try limits.kernelMemoryBytes(pageSize: 4096)
        #expect(bytes.high == 8192)
        #expect(bytes.maximum == 12288)
        let libvirt = try limits.libvirtMemoryKibibytes(pageSize: 4096)
        #expect(libvirt.high * 1024 == UInt64(bytes.high))
        #expect(libvirt.maximum * 1024 == UInt64(bytes.maximum))

        let ordinary = try BurstableResourceLimits(
            guestGrantBytes: 1024 * 1024, backendOverheadBytes: 128 * 1024 * 1024,
            memoryHighPercent: 80, cpuWeight: 100)
        for pageSize: Int64 in [4096, 16384, 65536] {
            let effective = try ordinary.kernelMemoryBytes(pageSize: pageSize)
            #expect(effective.high > 0 && effective.high < effective.maximum)
            #expect(effective.high.isMultiple(of: pageSize) && effective.maximum.isMultiple(of: pageSize))
            #expect(ordinary.memoryHighBytes - effective.high < pageSize)
            #expect(effective.maximum - ordinary.memoryMaxBytes < pageSize)
        }
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try ordinary.kernelMemoryBytes(pageSize: 3072)
        }
        #expect(throws: WorkloadResourceClassError.invalidRuntimeLimit) {
            try BurstableResourceLimits(
                guestGrantBytes: .max, backendOverheadBytes: 0, memoryHighPercent: 99, cpuWeight: 100
            )
            .kernelMemoryBytes(pageSize: 4096)
        }
    }

    @Test("libvirt policy preserves unrelated tuning and converges idempotently")
    func xmlTuning() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 1024 * 1024, backendOverheadBytes: 128 * 1024 * 1024,
            memoryHighPercent: 80, cpuWeight: 37)
        let xml = """
            <domain><name>vm</name><memtune><swap_hard_limit unit='KiB'>200000</swap_hard_limit></memtune>
            <vcpu>2</vcpu><cputune><vcpupin vcpu='0' cpuset='1'/><quota>-1</quota></cputune></domain>
            """
        let updated = try #require(try DomainBurstableTuning.updating(in: xml, limits: limits, pageSize: 4096))
        #expect(updated.contains("<hard_limit unit='KiB'>132096</hard_limit>"))
        #expect(updated.contains("<soft_limit unit='KiB'>131888</soft_limit>"))
        #expect(updated.contains("<shares>37</shares>"))
        #expect(updated.contains("<swap_hard_limit unit='KiB'>200000</swap_hard_limit>"))
        let cputune = try #require(try DomainXMLNode.parse(updated).child(named: "cputune"))
        #expect(cputune.child(named: "vcpupin")?.attribute("vcpu") == "0")
        #expect(cputune.child(named: "vcpupin")?.attribute("cpuset") == "1")
        #expect(cputune.child(named: "quota")?.text == "-1")
        #expect(try DomainBurstableTuning.updating(in: updated, limits: limits, pageSize: 4096) == nil)
    }

    @Test("positive quotas and ambiguous domain definitions refuse shared tuning")
    func rejectConflictingXML() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 1024 * 1024, backendOverheadBytes: 0, memoryHighPercent: 80, cpuWeight: 100)
        for xml in [
            "<domain><cputune><global_quota>10000</global_quota></cputune></domain>",
            "<domain><cputune><emulator_quota>invalid</emulator_quota></cputune></domain>",
            "<domain><memtune/><memtune/></domain>",
            "<domain><cputune>invalid</cputune></domain>",
            "<other/>",
        ] {
            #expect(throws: (any Error).self) {
                try DomainBurstableTuning.updating(in: xml, limits: limits, pageSize: 4096)
            }
        }
    }
}
