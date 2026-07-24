import Foundation
import Vapor

/// Assembles the detailed usage response for a resource quota: declared limits,
/// current reservations, measured usage, utilization percentages, and a breakdown
/// of the scoped VMs by environment and status. The assembly is a pure function of
/// a quota and its measured figures; `QuotaUsageAggregator` supplies the inputs.
struct QuotaUsageService {
    static func usageResponse(
        for quota: ResourceQuota, actualUsage: QuotaUsage, breakdown: QuotaVMBreakdown
    ) -> QuotaUsageResponse {
        QuotaUsageResponse(
            quotaId: quota.id!,
            quotaName: quota.name,
            limits: QuotaLimits(
                maxVCPUs: quota.maxVCPUs,
                maxMemoryGB: quota.maxMemory.bytesToGB,
                maxStorageGB: quota.maxStorage.bytesToGB,
                maxVMs: quota.maxVMs,
                maxSandboxes: quota.maxSandboxes,
                maxNetworks: quota.maxNetworks
            ),
            reserved: QuotaUsage(
                vcpus: quota.reservedVCPUs,
                memoryGB: quota.reservedMemory.bytesToGB,
                storageGB: quota.reservedStorage.bytesToGB,
                vms: quota.vmCount,
                sandboxes: quota.sandboxCount,
                networks: quota.networkCount
            ),
            actual: actualUsage,
            utilization: QuotaUtilization(
                cpuPercent: quota.cpuUtilizationPercent,
                memoryPercent: quota.memoryUtilizationPercent,
                storagePercent: quota.storageUtilizationPercent,
                vmPercent: quota.vmUtilizationPercent,
                sandboxPercent: quota.sandboxUtilizationPercent
            ),
            vmsByEnvironment: breakdown.byEnvironment,
            vmsByStatus: breakdown.byStatus,
            isEnabled: quota.isEnabled,
            environment: quota.environment
        )
    }
}
