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
        let ouNameConflicts: String // "rename", "merge", or "abort"
        let projectNameConflicts: String // "rename", "merge", or "abort"
        let quotaConflicts: String // "sum", "max", "keep_target", or "abort"
        let namingStrategy: String // "prefix_source", "suffix_source", or "manual"
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
        let type: String // "ou_name", "project_name", "quota_name"
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
        let resourceType: String // "ou", "project", "vm"
        let resourceId: UUID
        let destinationType: String // "organization", "ou", "project"
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
    let type: String // "circular_reference", "broken_path", "orphaned_resource", "quota_violation"
    let severity: String // "critical", "warning", "info"
    let entityType: String // "ou", "project", "vm", "quota"
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

