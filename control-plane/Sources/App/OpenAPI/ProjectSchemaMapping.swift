import Foundation
import Vapor

/// Conversions from the persistence models to the schemas generated from
/// `openapi.yaml`.
///
/// The generated schemas are the wire contract for every migrated surface, so
/// these initializers are the only place a `Project` becomes JSON. They
/// deliberately mirror the shapes the hand-written DTOs produced (issue #583) —
/// UUIDs render as their lowercase string form, absent optionals are omitted.
extension Components.Schemas.ProjectSummary {
    init(project: Project, vmCount: Int?) throws {
        self.init(
            id: try project.requireID().uuidString,
            name: project.name,
            description: project.description,
            organizationId: project.$organization.id?.uuidString,
            organizationalUnitId: project.$organizationalUnit.id?.uuidString,
            path: project.path,
            defaultEnvironment: project.defaultEnvironment,
            environments: project.environments,
            createdAt: project.createdAt,
            vmCount: vmCount
        )
    }
}

extension Components.Schemas.ProjectDetail {
    init(project: Project, vmCount: Int?, quotas: [ResourceQuota]? = nil) throws {
        self.init(
            value1: try .init(project: project, vmCount: vmCount),
            value2: .init(quotas: quotas?.map { Components.Schemas.ResourceQuota(quota: $0) })
        )
    }
}

extension Components.Schemas.ResourceQuota {
    init(quota: ResourceQuota) {
        // Reuse the hand-written response DTO's derivation of the quota's scope
        // and utilization so quota JSON stays identical across the API.
        let response = ResourceQuotaResponse(from: quota)
        self.init(
            id: response.id?.uuidString,
            name: response.name,
            entityType: EntityTypePayload(rawValue: response.entityType) ?? .unknown,
            entityId: response.entityId.uuidString,
            environment: response.environment,
            isEnabled: response.isEnabled,
            limits: .init(
                maxVCPUs: response.limits.maxVCPUs,
                maxMemoryGB: response.limits.maxMemoryGB,
                maxStorageGB: response.limits.maxStorageGB,
                maxVMs: response.limits.maxVMs,
                maxSandboxes: response.limits.maxSandboxes,
                maxNetworks: response.limits.maxNetworks
            ),
            usage: .init(
                reservedVCPUs: response.usage.reservedVCPUs,
                reservedMemoryGB: response.usage.reservedMemoryGB,
                reservedStorageGB: response.usage.reservedStorageGB,
                vmCount: response.usage.vmCount,
                sandboxCount: response.usage.sandboxCount,
                networkCount: response.usage.networkCount
            ),
            utilization: .init(
                cpuPercent: response.utilization.cpuPercent,
                memoryPercent: response.utilization.memoryPercent,
                storagePercent: response.utilization.storagePercent,
                vmPercent: response.utilization.vmPercent,
                sandboxPercent: response.utilization.sandboxPercent
            ),
            createdAt: response.createdAt
        )
    }
}

extension Components.Schemas.ProjectStats {
    init(stats: ProjectStatsResponse) {
        self.init(
            totalVMs: stats.totalVMs,
            vmsByEnvironment: .init(additionalProperties: stats.vmsByEnvironment),
            resourceUsage: .init(
                totalVCPUs: stats.resourceUsage.totalVCPUs,
                totalMemoryGB: stats.resourceUsage.totalMemoryGB,
                totalStorageGB: stats.resourceUsage.totalStorageGB,
                totalVMs: stats.resourceUsage.totalVMs
            )
        )
    }
}
