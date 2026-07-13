import Foundation
import Vapor
import Fluent

/// Computes quota scope classification and compliance figures for the hierarchy
/// resource-summary endpoint. The per-quota math is a pure function of a quota and
/// its measured usage, so it can be unit-tested without a database. Actual VM usage
/// is delegated to `ResourceQuota.calculateActualUsage`.
struct QuotaComplianceService {
    /// Classifies which entity a quota is scoped to.
    static func quotaScope(for quota: ResourceQuota) -> String {
        if quota.$organization.id != nil {
            return "organization"
        } else if quota.$organizationalUnit.id != nil {
            return "organizational_unit"
        } else if quota.$project.id != nil {
            return "project"
        } else {
            return "unknown"
        }
    }

    /// Pure assembly of compliance info from a quota and its measured usage.
    static func complianceInfo(for quota: ResourceQuota, actualUsage: QuotaUsage) -> QuotaComplianceInfo {
        let cpuCompliance = QuotaComplianceDetail(
            used: actualUsage.vcpus,
            limit: quota.maxVCPUs,
            percentage: Double(actualUsage.vcpus) / Double(quota.maxVCPUs) * 100
        )

        let memoryLimitGB = quota.maxMemory.bytesToGB
        let memoryCompliance = QuotaComplianceDetail(
            used: Int(actualUsage.memoryGB),
            limit: Int(memoryLimitGB),
            percentage: actualUsage.memoryGB / memoryLimitGB * 100
        )

        let vmCompliance = QuotaComplianceDetail(
            used: actualUsage.vms,
            limit: quota.maxVMs,
            percentage: Double(actualUsage.vms) / Double(quota.maxVMs) * 100
        )

        return QuotaComplianceInfo(
            quotaId: quota.id!,
            quotaName: quota.name,
            scope: quotaScope(for: quota),
            environment: quota.environment,
            cpuCompliance: cpuCompliance,
            memoryCompliance: memoryCompliance,
            vmCompliance: vmCompliance,
            isEnabled: quota.isEnabled
        )
    }

    /// Fetches measured usage for each quota and assembles compliance info.
    static func complianceInfos(for quotas: [ResourceQuota], on db: Database) async throws -> [QuotaComplianceInfo] {
        var result: [QuotaComplianceInfo] = []
        for quota in quotas {
            let (actualUsage, _, _) = try await quota.calculateActualUsage(on: db)
            result.append(complianceInfo(for: quota, actualUsage: actualUsage))
        }
        return result
    }

    /// All quotas scoped to an organization (direct, via its OUs, and via its projects).
    static func organizationQuotas(organizationID: UUID, on db: Database) async throws -> [ResourceQuota] {
        guard let organization = try await Organization.find(organizationID, on: db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }
        let allProjects = try await organization.getAllProjects(on: db)
        let allOUs = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all()

        return try await ResourceQuota.query(on: db)
            .group(.or) { or in
                or.filter(\.$organization.$id == organizationID)
                if !allOUs.isEmpty {
                    or.filter(\.$organizationalUnit.$id ~~ allOUs.compactMap { $0.id })
                }
                if !allProjects.isEmpty {
                    or.filter(\.$project.$id ~~ allProjects.compactMap { $0.id })
                }
            }
            .all()
    }
}
