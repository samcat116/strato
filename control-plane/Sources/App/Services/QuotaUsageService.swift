import Foundation
import ControlPlanePostgres
import Vapor

/// Assembles the detailed usage response for a resource quota: declared limits,
/// current reservations, measured usage, utilization percentages, and a breakdown
/// of the scoped VMs by environment and status. The assembly is a pure function of
/// a quota and its measured figures; `QuotaUsageAggregator` supplies the inputs.
struct QuotaUsageService {
    static func usageResponse(
        for quota: ResourceQuotaSnapshot,
        measured: ResourceQuotaUsageSnapshot
    ) -> QuotaUsageResponse {
        let usage = measured.usage
        return QuotaUsageResponse(
            quotaId: quota.id,
            quotaName: quota.name,
            limits: QuotaLimits(
                maxVCPUs: quota.maxVCPUs,
                maxMemoryGB: quota.maxMemory.bytesToGB,
                maxStorageGB: quota.maxStorage.bytesToGB,
                maxVMs: quota.maxVMs,
                maxSandboxes: quota.maxSandboxes,
                maxVolumes: quota.maxVolumes,
                maxNetworks: quota.maxNetworks,
                maxLoadBalancers: quota.maxLoadBalancers
            ),
            reserved: QuotaUsage(
                vcpus: quota.reservedVCPUs,
                memoryGB: quota.reservedMemory.bytesToGB,
                storageGB: quota.reservedStorage.bytesToGB,
                vms: quota.vmCount,
                sandboxes: quota.sandboxCount,
                volumes: quota.volumeCount,
                networks: quota.networkCount,
                loadBalancers: quota.loadBalancerCount
            ),
            actual: QuotaUsage(
                vcpus: usage.vcpus,
                memoryGB: usage.memoryBytes.bytesToGB,
                storageGB: usage.storageBytes.bytesToGB,
                vms: usage.vmCount,
                sandboxes: usage.sandboxCount,
                volumes: usage.volumeCount,
                networks: usage.networkCount,
                loadBalancers: usage.loadBalancerCount
            ),
            utilization: QuotaUtilization(
                cpuPercent: percent(quota.reservedVCPUs, quota.maxVCPUs),
                memoryPercent: percent(quota.reservedMemory, quota.maxMemory),
                storagePercent: percent(quota.reservedStorage, quota.maxStorage),
                vmPercent: percent(quota.vmCount, quota.maxVMs),
                sandboxPercent: percent(quota.sandboxCount, quota.maxSandboxes),
                volumePercent: quota.maxVolumes.map { percent(quota.volumeCount, $0) },
                loadBalancerPercent: percent(quota.loadBalancerCount, quota.maxLoadBalancers)
            ),
            vmsByEnvironment: measured.vmsByEnvironment,
            vmsByStatus: measured.vmsByStatus,
            isEnabled: quota.isEnabled,
            environment: quota.environment
        )
    }

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
                maxVolumes: quota.maxVolumes,
                maxNetworks: quota.maxNetworks,
                maxLoadBalancers: quota.maxLoadBalancers
            ),
            reserved: QuotaUsage(
                vcpus: quota.reservedVCPUs,
                memoryGB: quota.reservedMemory.bytesToGB,
                storageGB: quota.reservedStorage.bytesToGB,
                vms: quota.vmCount,
                sandboxes: quota.sandboxCount,
                volumes: quota.volumeCount,
                networks: quota.networkCount,
                loadBalancers: quota.loadBalancerCount
            ),
            actual: actualUsage,
            utilization: QuotaUtilization(
                cpuPercent: quota.cpuUtilizationPercent,
                memoryPercent: quota.memoryUtilizationPercent,
                storagePercent: quota.storageUtilizationPercent,
                vmPercent: quota.vmUtilizationPercent,
                sandboxPercent: quota.sandboxUtilizationPercent,
                volumePercent: quota.volumeUtilizationPercent,
                loadBalancerPercent: quota.loadBalancerUtilizationPercent
            ),
            vmsByEnvironment: breakdown.byEnvironment,
            vmsByStatus: breakdown.byStatus,
            isEnabled: quota.isEnabled,
            environment: quota.environment
        )
    }

    private static func percent<T: BinaryInteger>(_ used: T, _ maximum: T) -> Double {
        maximum > 0 ? Double(Int64(used)) / Double(Int64(maximum)) * 100 : 0
    }
}
