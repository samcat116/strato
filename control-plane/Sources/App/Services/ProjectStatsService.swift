import Foundation
import Vapor

/// Aggregates VM counts and resource totals for a project. The aggregation is a
/// pure function of the project and its VMs, so it is unit-testable without a
/// database; the controller is responsible for loading the VMs.
struct ProjectStatsService {
    static func stats(for project: Project, vms: [VM]) -> ProjectStatsResponse {
        // Seed every declared environment so empty environments report zero.
        var vmsByEnvironment: [String: Int] = [:]
        for environment in project.environments {
            vmsByEnvironment[environment] = 0
        }

        var totalVCPUs = 0
        var totalMemory: Int64 = 0
        var totalStorage: Int64 = 0

        for vm in vms {
            vmsByEnvironment[vm.environment, default: 0] += 1
            totalVCPUs += vm.cpu
            totalMemory += vm.memory
            totalStorage += vm.disk
        }

        let resourceUsage = ResourceUsageResponse(
            totalVCPUs: totalVCPUs,
            totalMemoryGB: totalMemory.bytesToGB,
            totalStorageGB: totalStorage.bytesToGB,
            totalVMs: vms.count
        )

        return ProjectStatsResponse(
            totalVMs: vms.count,
            vmsByEnvironment: vmsByEnvironment,
            resourceUsage: resourceUsage
        )
    }
}
