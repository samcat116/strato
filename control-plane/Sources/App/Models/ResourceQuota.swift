import Fluent
import Vapor
import Foundation

final class ResourceQuota: Model, @unchecked Sendable {
    static let schema = "resource_quotas"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    // Quota can apply to Organization, OU, or Project level
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    @OptionalParent(key: "organizational_unit_id")
    var organizationalUnit: OrganizationalUnit?

    @OptionalParent(key: "project_id")
    var project: Project?

    // CPU limits
    @Field(key: "max_vcpus")
    var maxVCPUs: Int

    @Field(key: "reserved_vcpus")
    var reservedVCPUs: Int

    // Memory limits (in bytes)
    @Field(key: "max_memory")
    var maxMemory: Int64

    @Field(key: "reserved_memory")
    var reservedMemory: Int64

    // Storage limits (in bytes)
    @Field(key: "max_storage")
    var maxStorage: Int64

    @Field(key: "reserved_storage")
    var reservedStorage: Int64

    // VM count limits
    @Field(key: "max_vms")
    var maxVMs: Int

    @Field(key: "vm_count")
    var vmCount: Int

    // Network limits
    @Field(key: "max_networks")
    var maxNetworks: Int

    @Field(key: "network_count")
    var networkCount: Int

    // Whether this quota is enabled
    @Field(key: "is_enabled")
    var isEnabled: Bool

    // Optional environment-specific quota (null means applies to all environments)
    @OptionalField(key: "environment")
    var environment: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil,
        projectID: UUID? = nil,
        maxVCPUs: Int,
        maxMemory: Int64,
        maxStorage: Int64,
        maxVMs: Int,
        maxNetworks: Int = 10,
        environment: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.$organization.id = organizationID
        self.$organizationalUnit.id = organizationalUnitID
        self.$project.id = projectID
        self.maxVCPUs = maxVCPUs
        self.reservedVCPUs = 0
        self.maxMemory = maxMemory
        self.reservedMemory = 0
        self.maxStorage = maxStorage
        self.reservedStorage = 0
        self.maxVMs = maxVMs
        self.vmCount = 0
        self.maxNetworks = maxNetworks
        self.networkCount = 0
        self.environment = environment
        self.isEnabled = isEnabled
    }
}

extension ResourceQuota: Content {}

// MARK: - Computed Properties

extension ResourceQuota {
    var availableVCPUs: Int {
        return maxVCPUs - reservedVCPUs
    }

    var availableMemory: Int64 {
        return maxMemory - reservedMemory
    }

    var availableStorage: Int64 {
        return maxStorage - reservedStorage
    }

    var availableVMs: Int {
        return maxVMs - vmCount
    }

    var availableNetworks: Int {
        return maxNetworks - networkCount
    }

    var cpuUtilizationPercent: Double {
        guard maxVCPUs > 0 else { return 0 }
        return Double(reservedVCPUs) / Double(maxVCPUs) * 100
    }

    var memoryUtilizationPercent: Double {
        guard maxMemory > 0 else { return 0 }
        return Double(reservedMemory) / Double(maxMemory) * 100
    }

    var storageUtilizationPercent: Double {
        guard maxStorage > 0 else { return 0 }
        return Double(reservedStorage) / Double(maxStorage) * 100
    }

    var vmUtilizationPercent: Double {
        guard maxVMs > 0 else { return 0 }
        return Double(vmCount) / Double(maxVMs) * 100
    }
}

// MARK: - Helper Methods

extension ResourceQuota {
    /// Check if a VM creation would exceed quota limits
    func canAccommodateVM(vcpus: Int, memory: Int64, storage: Int64) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }

        if reservedVCPUs + vcpus > maxVCPUs {
            return (false, "Insufficient vCPU quota: \(availableVCPUs) available, \(vcpus) requested")
        }

        if reservedMemory + memory > maxMemory {
            let availableGB = Double(availableMemory) / 1024 / 1024 / 1024
            let requestedGB = Double(memory) / 1024 / 1024 / 1024
            return (false, "Insufficient memory quota: \(String(format: "%.2f", availableGB))GB available, \(String(format: "%.2f", requestedGB))GB requested")
        }

        if reservedStorage + storage > maxStorage {
            let availableGB = Double(availableStorage) / 1024 / 1024 / 1024
            let requestedGB = Double(storage) / 1024 / 1024 / 1024
            return (false, "Insufficient storage quota: \(String(format: "%.2f", availableGB))GB available, \(String(format: "%.2f", requestedGB))GB requested")
        }

        if vmCount >= maxVMs {
            return (false, "VM limit reached: \(maxVMs) VMs allowed")
        }

        return (true, nil)
    }

    /// Reserve resources for a VM
    func reserveResources(vcpus: Int, memory: Int64, storage: Int64) throws {
        let check = canAccommodateVM(vcpus: vcpus, memory: memory, storage: storage)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        reservedVCPUs += vcpus
        reservedMemory += memory
        reservedStorage += storage
        vmCount += 1
    }

    /// Release resources when a VM is deleted
    func releaseResources(vcpus: Int, memory: Int64, storage: Int64) {
        reservedVCPUs = max(0, reservedVCPUs - vcpus)
        reservedMemory = max(0, reservedMemory - memory)
        reservedStorage = max(0, reservedStorage - storage)
        vmCount = max(0, vmCount - 1)
    }

    /// Update reserved resources when a VM is resized
    func updateReservation(
        oldVCPUs: Int, oldMemory: Int64, oldStorage: Int64,
        newVCPUs: Int, newMemory: Int64, newStorage: Int64
    ) throws {
        // Calculate deltas
        let vcpuDelta = newVCPUs - oldVCPUs
        let memoryDelta = newMemory - oldMemory
        let storageDelta = newStorage - oldStorage

        // Check if increase is allowed
        if vcpuDelta > 0 || memoryDelta > 0 || storageDelta > 0 {
            let check = canAccommodateVM(
                vcpus: max(0, vcpuDelta),
                memory: max(0, memoryDelta),
                storage: max(0, storageDelta)
            )
            if !check.allowed {
                throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded for resize")
            }
        }

        // Update reservations
        reservedVCPUs += vcpuDelta
        reservedMemory += memoryDelta
        reservedStorage += storageDelta
    }
}

// MARK: - Validations

extension ResourceQuota {
    func validate() throws {
        // Ensure quota belongs to exactly one entity
        let parentCount = [
            $organization.id != nil,
            $organizationalUnit.id != nil,
            $project.id != nil
        ].filter { $0 }.count

        if parentCount != 1 {
            throw Abort(.badRequest, reason: "Resource quota must belong to exactly one entity (organization, OU, or project)")
        }

        // Validate limits are positive
        if maxVCPUs <= 0 || maxMemory <= 0 || maxStorage <= 0 || maxVMs <= 0 {
            throw Abort(.badRequest, reason: "All resource limits must be positive")
        }

        // Validate reserved doesn't exceed max
        if reservedVCPUs > maxVCPUs || reservedMemory > maxMemory ||
           reservedStorage > maxStorage || vmCount > maxVMs {
            throw Abort(.badRequest, reason: "Reserved resources cannot exceed maximum limits")
        }
    }
}

// MARK: - DTOs

struct CreateResourceQuotaRequest: Content {
    let name: String
    let maxVCPUs: Int
    let maxMemoryGB: Double
    let maxStorageGB: Double
    let maxVMs: Int
    let maxNetworks: Int?
    let environment: String?
    let isEnabled: Bool?
}

struct UpdateResourceQuotaRequest: Content {
    let name: String?
    let maxVCPUs: Int?
    let maxMemoryGB: Double?
    let maxStorageGB: Double?
    let maxVMs: Int?
    let maxNetworks: Int?
    let isEnabled: Bool?
}

struct ResourceQuotaResponse: Content {
    let id: UUID?
    let name: String
    let entityType: String // "organization", "ou", or "project"
    let entityId: UUID
    let environment: String?
    let isEnabled: Bool
    let limits: ResourceLimits
    let usage: ResourceUsage
    let utilization: ResourceUtilization
    let createdAt: Date?

    struct ResourceLimits: Content {
        let maxVCPUs: Int
        let maxMemoryGB: Double
        let maxStorageGB: Double
        let maxVMs: Int
        let maxNetworks: Int
    }

    struct ResourceUsage: Content {
        let reservedVCPUs: Int
        let reservedMemoryGB: Double
        let reservedStorageGB: Double
        let vmCount: Int
        let networkCount: Int
    }

    struct ResourceUtilization: Content {
        let cpuPercent: Double
        let memoryPercent: Double
        let storagePercent: Double
        let vmPercent: Double
    }

    init(from quota: ResourceQuota) {
        self.id = quota.id
        self.name = quota.name

        // Determine entity type and ID
        if let orgId = quota.$organization.id {
            self.entityType = "organization"
            self.entityId = orgId
        } else if let ouId = quota.$organizationalUnit.id {
            self.entityType = "ou"
            self.entityId = ouId
        } else if let projId = quota.$project.id {
            self.entityType = "project"
            self.entityId = projId
        } else {
            // This should never happen due to validation
            self.entityType = "unknown"
            self.entityId = UUID()
        }

        self.environment = quota.environment
        self.isEnabled = quota.isEnabled

        self.limits = ResourceLimits(
            maxVCPUs: quota.maxVCPUs,
            maxMemoryGB: Double(quota.maxMemory) / 1024 / 1024 / 1024,
            maxStorageGB: Double(quota.maxStorage) / 1024 / 1024 / 1024,
            maxVMs: quota.maxVMs,
            maxNetworks: quota.maxNetworks
        )

        self.usage = ResourceUsage(
            reservedVCPUs: quota.reservedVCPUs,
            reservedMemoryGB: Double(quota.reservedMemory) / 1024 / 1024 / 1024,
            reservedStorageGB: Double(quota.reservedStorage) / 1024 / 1024 / 1024,
            vmCount: quota.vmCount,
            networkCount: quota.networkCount
        )

        self.utilization = ResourceUtilization(
            cpuPercent: quota.cpuUtilizationPercent,
            memoryPercent: quota.memoryUtilizationPercent,
            storagePercent: quota.storageUtilizationPercent,
            vmPercent: quota.vmUtilizationPercent
        )

        self.createdAt = quota.createdAt
    }
}

struct ResourceUsageResponse: Content {
    let totalVCPUs: Int
    let totalMemoryGB: Double
    let totalStorageGB: Double
    let totalVMs: Int
}
