import Foundation
import Vapor

// MARK: - Bulk Operations DTOs

struct MergeOrganizationsRequest: Content {
    let sourceOrganizationId: UUID
    let conflictResolution: ConflictResolution
    let preserveQuotas: Bool
    let mergeUsers: Bool
    let newName: String?

    struct ConflictResolution: Content {
        let ouNameConflicts: String  // "rename", "merge", or "abort"
        let projectNameConflicts: String  // "rename", "merge", or "abort"
        let quotaConflicts: String  // "sum", "max", "keep_target", or "abort"
        let namingStrategy: String  // "prefix_source", "suffix_source", or "manual"
        let prefix: String?
        let suffix: String?
    }
}

struct MergeOrganizationsResponse: Content {
    let success: Bool
    let targetOrganizationId: UUID
    let mergedResourceCounts: MergedResourceCounts
    let conflicts: [MergeConflict]
    let warnings: [String]
    let summary: String

    struct MergedResourceCounts: Content {
        let organizationalUnits: Int
        let projects: Int
        let vms: Int
        let quotas: Int
        let users: Int
    }

    struct MergeConflict: Content {
        let type: String  // "ou_name", "project_name", "quota_name"
        let sourceName: String
        let targetName: String
        let resolution: String
        let newName: String?
    }
}

struct BulkTransferRequest: Content {
    let transfers: [ResourceTransfer]
    let validateOnly: Bool

    struct ResourceTransfer: Content {
        let resourceType: String  // "ou", "project", "vm"
        let resourceId: UUID
        let destinationType: String  // "organization", "ou", "project"
        let destinationId: UUID
        let newName: String?
    }
}

struct BulkTransferResponse: Content {
    let success: Bool
    let transferredCount: Int
    let failedTransfers: [TransferFailure]
    let warnings: [String]
    let summary: String

    struct TransferFailure: Content {
        let resourceId: UUID
        let resourceType: String
        let reason: String
        let suggestion: String?
    }
}

// MARK: - Validation DTOs

struct HierarchyValidationResponse: Content {
    let isValid: Bool
    let issues: [HierarchyIssue]
    let summary: HierarchyValidationSummary
}

struct HierarchyIssue: Content {
    let id: UUID
    let type: String  // "circular_reference", "broken_path", "orphaned_resource", "quota_violation"
    let severity: String  // "critical", "warning", "info"
    let entityType: String  // "ou", "project", "vm", "quota"
    let entityId: UUID
    let entityName: String
    let description: String
    let suggestedFix: String?
    let autoRepairable: Bool
}

struct HierarchyValidationSummary: Content {
    let totalIssues: Int
    let criticalIssues: Int
    let warningIssues: Int
    let infoIssues: Int
}

struct HierarchyRepairRequest: Content {
    let repairAll: Bool
    let specificIssues: [UUID]?
    let repairOptions: RepairOptions

    struct RepairOptions: Content {
        let fixCircularReferences: Bool
        let rebuildPaths: Bool
        let removeOrphanedResources: Bool
        let adjustQuotas: Bool
        let createMissingDefaults: Bool
    }
}

struct HierarchyRepairResponse: Content {
    let success: Bool
    let repairedIssues: [RepairedIssue]
    let remainingIssues: [HierarchyIssue]
    let summary: String

    struct RepairedIssue: Content {
        let issueId: UUID
        let issueType: String
        let action: String
        let details: String
    }
}

// MARK: - DTOs for Hierarchy Management

struct OrganizationHierarchyResponse: Content {
    let organization: OrganizationNode
    let stats: HierarchyStats
}

struct OrganizationNode: Content {
    let id: UUID
    let name: String
    let description: String
    let organizationalUnits: [OrganizationalUnitNode]
    let projects: [ProjectNode]
    let quotas: [ResourceQuotaResponse]
}

struct OrganizationalUnitNode: Content {
    let id: UUID
    let name: String
    let description: String
    let path: String
    let depth: Int
    let childOUs: [OrganizationalUnitNode]
    let projects: [ProjectNode]
    let quotas: [ResourceQuotaResponse]
}

struct ProjectNode: Content {
    let id: UUID
    let name: String
    let description: String
    let path: String
    let environments: [String]
    let defaultEnvironment: String
    let vms: [VMSummary]
    let quotas: [ResourceQuotaResponse]
}

struct VMSummary: Content {
    let id: UUID
    let name: String
    let environment: String
    let status: String
    let cpu: Int
    let memoryGB: Double
    let diskGB: Double
}

struct VMResponse: Content {
    let id: UUID
    let name: String
    let description: String
    let environment: String
    let status: String
    let cpu: Int
    let memory: Int64
    let disk: Int64
    let projectId: UUID

    init(from vm: VM) {
        self.id = vm.id!
        self.name = vm.name
        self.description = vm.description
        self.environment = vm.environment
        self.status = vm.status.rawValue
        self.cpu = vm.cpu
        self.memory = vm.memory
        self.disk = vm.disk
        self.projectId = vm.$project.id
    }
}

struct HierarchyStats: Content {
    let totalOUs: Int
    let totalProjects: Int
    let totalVMs: Int
    let totalQuotas: Int
    let maxDepth: Int
    let resourceUtilization: ResourceUsageResponse
}

struct OrganizationResourcesResponse: Content {
    let organizationId: UUID
    let organizationName: String
    let organizationalUnits: [OrganizationalUnitResponse]
    let projects: [ProjectResponse]
    let vms: [VMResponse]
    let quotas: [ResourceQuotaResponse]
    let summary: ResourceSummary
}

struct ResourceSummary: Content {
    let totalOUs: Int
    let totalProjects: Int
    let totalVMs: Int
    let totalQuotas: Int
    let vmsByEnvironment: [String: Int]
    let vmsByStatus: [String: Int]
    let vmsByProject: [String: Int]
}

struct ResourceSummaryResponse: Content {
    let organizationId: UUID
    let organizationName: String
    let resourceUsage: ResourceUsageResponse
    let quotaCompliance: [QuotaComplianceInfo]
    let hierarchyStats: HierarchyStats
}

struct QuotaComplianceInfo: Content {
    let quotaId: UUID
    let quotaName: String
    let scope: String
    let environment: String?
    let cpuCompliance: QuotaComplianceDetail
    let memoryCompliance: QuotaComplianceDetail
    let vmCompliance: QuotaComplianceDetail
    let isEnabled: Bool
}

struct QuotaComplianceDetail: Content {
    let used: Int
    let limit: Int
    let percentage: Double
}

struct HierarchySearchResponse: Content {
    let query: String
    let organizationId: UUID?
    let results: [HierarchySearchResult]
    let totalResults: Int
}

struct HierarchySearchResult: Content {
    let id: UUID
    let name: String
    let type: String
    let path: String
    let description: String
    let parentId: UUID?
    let parentType: String?
}

struct EntityPathResponse: Content {
    let entityId: UUID
    let entityType: String
    let organizationId: UUID
    let pathComponents: [PathComponent]
}

struct PathComponent: Content {
    let id: UUID
    let name: String
    let type: String
}

// Additional DTOs for bulk operations and validation would be defined here...
