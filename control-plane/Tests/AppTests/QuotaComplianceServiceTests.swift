import Testing
import Foundation
@testable import App

@Suite("QuotaComplianceService Tests")
struct QuotaComplianceServiceTests {

    private func gib(_ count: Int64) -> Int64 { count * 1024 * 1024 * 1024 }

    // MARK: - Scope classification

    @Test("quotaScope classifies organization, OU, project, and unknown scopes")
    func testQuotaScope() {
        let orgQuota = ResourceQuota(
            name: "org", organizationID: UUID(),
            maxVCPUs: 1, maxMemory: gib(1), maxStorage: gib(1), maxVMs: 1
        )
        #expect(QuotaComplianceService.quotaScope(for: orgQuota) == "organization")

        let ouQuota = ResourceQuota(
            name: "ou", organizationalUnitID: UUID(),
            maxVCPUs: 1, maxMemory: gib(1), maxStorage: gib(1), maxVMs: 1
        )
        #expect(QuotaComplianceService.quotaScope(for: ouQuota) == "organizational_unit")

        let projectQuota = ResourceQuota(
            name: "project", projectID: UUID(),
            maxVCPUs: 1, maxMemory: gib(1), maxStorage: gib(1), maxVMs: 1
        )
        #expect(QuotaComplianceService.quotaScope(for: projectQuota) == "project")

        let orphan = ResourceQuota(
            name: "orphan",
            maxVCPUs: 1, maxMemory: gib(1), maxStorage: gib(1), maxVMs: 1
        )
        #expect(QuotaComplianceService.quotaScope(for: orphan) == "unknown")
    }

    // MARK: - Compliance math (pure)

    @Test("complianceInfo computes usage, limits, and percentages")
    func testComplianceInfoMath() {
        let quota = ResourceQuota(
            id: UUID(),
            name: "quota",
            organizationID: UUID(),
            maxVCPUs: 10,
            maxMemory: gib(8),
            maxStorage: gib(100),
            maxVMs: 5,
            environment: "prod"
        )

        let usage = QuotaUsage(vcpus: 5, memoryGB: 4.0, storageGB: 25.0, vms: 2, networks: 0)
        let info = QuotaComplianceService.complianceInfo(for: quota, actualUsage: usage)

        #expect(info.scope == "organization")
        #expect(info.environment == "prod")
        #expect(info.isEnabled == true)

        // CPU: 5 of 10 -> 50%
        #expect(info.cpuCompliance.used == 5)
        #expect(info.cpuCompliance.limit == 10)
        #expect(info.cpuCompliance.percentage == 50.0)

        // Memory: 4 GB of 8 GB -> 50%
        #expect(info.memoryCompliance.used == 4)
        #expect(info.memoryCompliance.limit == 8)
        #expect(info.memoryCompliance.percentage == 50.0)

        // VMs: 2 of 5 -> 40%
        #expect(info.vmCompliance.used == 2)
        #expect(info.vmCompliance.limit == 5)
        #expect(info.vmCompliance.percentage == 40.0)
    }

    @Test("complianceInfo reports zero usage as zero percentages")
    func testComplianceInfoZeroUsage() {
        let quota = ResourceQuota(
            id: UUID(), name: "quota", projectID: UUID(),
            maxVCPUs: 4, maxMemory: gib(16), maxStorage: gib(50), maxVMs: 3
        )
        let usage = QuotaUsage(vcpus: 0, memoryGB: 0, storageGB: 0, vms: 0, networks: 0)
        let info = QuotaComplianceService.complianceInfo(for: quota, actualUsage: usage)

        #expect(info.scope == "project")
        #expect(info.cpuCompliance.percentage == 0.0)
        #expect(info.memoryCompliance.percentage == 0.0)
        #expect(info.vmCompliance.percentage == 0.0)
        #expect(info.memoryCompliance.limit == 16)
    }
}
