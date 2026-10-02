import Foundation
import Testing

@testable import StratoAgentCore
@testable import StratoAgentDomainXML

@Suite("burstable runtime limits")
struct BurstableResourceLimitsTests {
    @Test("guest pressure percentage does not discount backend allowance")
    func arithmetic() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: 1024 * 1024 * 1024, backendOverheadBytes: 128 * 1024 * 1024,
            memoryHighPercent: 80, cpuWeight: 37)
        #expect(limits.memoryHighBytes == 993_211_187)
        #expect(limits.memoryMaxBytes == 1_207_959_552)
        #expect(limits.jailerEntries == ["memory.high=993211187", "memory.max=1207959552", "cpu.weight=37"])
        let libvirt = try limits.libvirtMemoryKibibytes()
        #expect(libvirt.high == 969_932)
        #expect(libvirt.maximum == 1_179_648)
    }

    @Test("valid near-maximum grants do not overflow the percentage multiplication")
    func largeGrant() throws {
        let limits = try BurstableResourceLimits(
            guestGrantBytes: .max, backendOverheadBytes: 0, memoryHighPercent: 99, cpuWeight: 10000)
        #expect(limits.memoryHighBytes == 9_131_138_316_486_228_048)
        #expect(limits.memoryMaxBytes == .max)
        #expect(throws: BurstableResourceLimits.InvalidLimits.overflow) {
            try BurstableResourceLimits(
                guestGrantBytes: .max, backendOverheadBytes: 1, memoryHighPercent: 99, cpuWeight: 1)
        }
    }

    @Test("invalid policies and unrepresentable thresholds refuse enforcement")
    func invalid() {
        #expect(throws: BurstableResourceLimits.InvalidLimits.guestGrant) {
            try BurstableResourceLimits(
                guestGrantBytes: 0, backendOverheadBytes: 1, memoryHighPercent: 80, cpuWeight: 100)
        }
        #expect(throws: BurstableResourceLimits.InvalidLimits.memoryHighPercent) {
            try BurstableResourceLimits(
                guestGrantBytes: 1024, backendOverheadBytes: 0, memoryHighPercent: 100, cpuWeight: 100)
        }
        #expect(throws: BurstableResourceLimits.InvalidLimits.cpuWeight) {
            try BurstableResourceLimits(
                guestGrantBytes: 1024, backendOverheadBytes: 0, memoryHighPercent: 80, cpuWeight: 0)
        }
        #expect(throws: BurstableResourceLimits.InvalidLimits.pressureThreshold) {
            try BurstableResourceLimits(
                guestGrantBytes: 1, backendOverheadBytes: 0, memoryHighPercent: 80, cpuWeight: 100)
        }
        #expect(throws: BurstableResourceLimits.InvalidLimits.libvirtGranularity) {
            try BurstableResourceLimits(
                guestGrantBytes: 1024, backendOverheadBytes: 0, memoryHighPercent: 80, cpuWeight: 100
            )
            .libvirtMemoryKibibytes()
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
        let updated = try #require(try DomainBurstableTuning.updating(in: xml, limits: limits))
        #expect(updated.contains("<hard_limit unit='KiB'>132096</hard_limit>"))
        #expect(updated.contains("<soft_limit unit='KiB'>131891</soft_limit>"))
        #expect(updated.contains("<shares>37</shares>"))
        #expect(updated.contains("<swap_hard_limit unit='KiB'>200000</swap_hard_limit>"))
        let cputune = try #require(try DomainXMLNode.parse(updated).child(named: "cputune"))
        #expect(cputune.child(named: "vcpupin")?.attribute("vcpu") == "0")
        #expect(cputune.child(named: "vcpupin")?.attribute("cpuset") == "1")
        #expect(cputune.child(named: "quota")?.text == "-1")
        #expect(try DomainBurstableTuning.updating(in: updated, limits: limits) == nil)
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
            #expect(throws: (any Error).self) { try DomainBurstableTuning.updating(in: xml, limits: limits) }
        }
    }
}
