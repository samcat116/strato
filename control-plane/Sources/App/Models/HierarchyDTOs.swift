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

// MARK: - Environment Management DTOs

struct EnvironmentPromotionRequest: Content {
    let vmId: UUID
    let sourceEnvironment: String
    let targetEnvironment: String
    let createCopy: Bool // If true, create a copy instead of moving
    let copyName: String?
    let notes: String?
}

struct EnvironmentPromotionResponse: Content {
    let success: Bool
    let vmId: UUID
    let copiedVmId: UUID? // If createCopy was true
    let sourceEnvironment: String
    let targetEnvironment: String
    let promotedAt: Date
    let requiresApproval: Bool
    let approvalId: UUID?
}

struct EnvironmentConfigurationRequest: Content {
    let projectId: UUID
    let environments: [EnvironmentConfiguration]
    
    struct EnvironmentConfiguration: Content {
        let name: String
        let displayName: String
        let description: String
        let isProduction: Bool
        let requiresApproval: Bool
        let settings: EnvironmentSettingsData
    }
    
    struct EnvironmentSettingsData: Content {
        let autoScalingEnabled: Bool
        let maxInstances: Int
        let minInstances: Int
        let backupEnabled: Bool
        let backupSchedule: String?
        let monitoringEnabled: Bool
        let alertingEnabled: Bool
        let maintenanceWindow: MaintenanceWindowData?
        
        struct MaintenanceWindowData: Content {
            let dayOfWeek: Int
            let startHour: Int
            let durationHours: Int
        }
    }
}

// MARK: - Quota Management DTOs

struct QuotaInheritanceRequest: Content {
    let parentQuotaId: UUID
    let childEntities: [QuotaChild]
    let inheritanceRules: InheritanceRules
    
    struct QuotaChild: Content {
        let entityType: String // "ou", "project"
        let entityId: UUID
        let percentage: Double? // Percentage of parent quota to inherit
    }
    
    struct InheritanceRules: Content {
        let inheritCPU: Bool
        let inheritMemory: Bool
        let inheritStorage: Bool
        let inheritVMs: Bool
        let allowOverrides: Bool
        let enforceHierarchy: Bool
    }
}

struct QuotaInheritanceResponse: Content {
    let success: Bool
    let createdQuotas: [UUID]
    let updatedQuotas: [UUID]
    let errors: [QuotaInheritanceError]
    
    struct QuotaInheritanceError: Content {
        let entityId: UUID
        let entityType: String
        let error: String
    }
}

struct QuotaViolationResponse: Content {
    let hasViolations: Bool
    let violations: [QuotaViolation]
    let warnings: [QuotaWarning]
    
    struct QuotaViolation: Content {
        let quotaId: UUID
        let quotaName: String
        let entityId: UUID
        let entityType: String
        let violationType: String // "cpu", "memory", "storage", "vm_count"
        let currentUsage: Double
        let limit: Double
        let severity: String // "critical", "warning"
    }
    
    struct QuotaWarning: Content {
        let quotaId: UUID
        let quotaName: String
        let message: String
        let threshold: Double // Percentage threshold that triggered warning
    }
}

// MARK: - Audit and Tracking DTOs

struct HierarchyAuditLog: Content {
    let id: UUID
    let timestamp: Date
    let userId: UUID
    let userEmail: String
    let action: String // "create", "update", "delete", "move", "merge"
    let entityType: String
    let entityId: UUID
    let entityName: String
    let oldValues: [String: String]?
    let newValues: [String: String]?
    let ipAddress: String?
    let userAgent: String?
}

struct HierarchyChangeRequest: Content {
    let changes: [HierarchyChange]
    let reason: String
    let requestedBy: UUID
    let approvalRequired: Bool
    
    struct HierarchyChange: Content {
        let type: String // "move", "rename", "transfer", "delete"
        let entityType: String
        let entityId: UUID
        let oldParentId: UUID?
        let newParentId: UUID?
        let oldName: String?
        let newName: String?
        let metadata: [String: String]?
    }
}

struct HierarchyChangeResponse: Content {
    let requestId: UUID
    let status: String // "approved", "pending", "rejected"
    let appliedChanges: [AppliedChange]
    let failedChanges: [FailedChange]
    let requiresApproval: Bool
    let approvalRequestId: UUID?
    
    struct AppliedChange: Content {
        let changeId: UUID
        let entityId: UUID
        let appliedAt: Date
        let result: String
    }
    
    struct FailedChange: Content {
        let changeId: UUID
        let entityId: UUID
        let error: String
        let suggestion: String?
    }
}

// MARK: - Reporting DTOs

struct HierarchyReportRequest: Content {
    let organizationId: UUID
    let reportType: String // "structure", "resources", "quotas", "compliance"
    let format: String // "json", "csv", "pdf"
    let includeSubOUs: Bool
    let dateRange: DateRange?
    let filters: ReportFilters?
    
    struct DateRange: Content {
        let from: Date
        let to: Date
    }
    
    struct ReportFilters: Content {
        let environments: [String]?
        let projectTypes: [String]?
        let resourceTypes: [String]?
        let quotaTypes: [String]?
    }
}

struct HierarchyReportResponse: Content {
    let reportId: UUID
    let status: String // "generating", "completed", "failed"
    let downloadUrl: String?
    let generatedAt: Date?
    let expiresAt: Date?
    let metadata: ReportMetadata
    
    struct ReportMetadata: Content {
        let organizationId: UUID
        let organizationName: String
        let reportType: String
        let recordCount: Int
        let fileSize: Int64?
        let format: String
    }
}