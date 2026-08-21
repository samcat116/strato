import Foundation
import Vapor

// MARK: - Validation DTOs

struct HierarchyValidationResponse: Content {
    let isValid: Bool
    let issues: [HierarchyIssue]
    let summary: HierarchyValidationSummary
}

struct HierarchyIssue: Content {
    /// The id of the entity the issue is about. An entity carries at most one
    /// issue, so this is stable across calls — which is what makes
    /// `HierarchyRepairRequest.specificIssues` usable against a report from an
    /// earlier `GET /api/hierarchy/validate`.
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

/// Every field is optional and defaults to off, so an operator can ask for one
/// repair (`{"repairAll": true, "repairOptions": {"rebuildPaths": true}}`)
/// without restating the whole option set. Swift's synthesized `Decodable` does
/// not fall back to property defaults for missing keys, hence the hand-written
/// initializers.
struct HierarchyRepairRequest: Content {
    let repairAll: Bool
    let specificIssues: [UUID]?
    let repairOptions: RepairOptions

    init(repairAll: Bool = false, specificIssues: [UUID]? = nil, repairOptions: RepairOptions = RepairOptions()) {
        self.repairAll = repairAll
        self.specificIssues = specificIssues
        self.repairOptions = repairOptions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.repairAll = try container.decodeIfPresent(Bool.self, forKey: .repairAll) ?? false
        self.specificIssues = try container.decodeIfPresent([UUID].self, forKey: .specificIssues)
        self.repairOptions =
            try container.decodeIfPresent(RepairOptions.self, forKey: .repairOptions) ?? RepairOptions()
    }

    struct RepairOptions: Content {
        let fixCircularReferences: Bool
        let rebuildPaths: Bool
        let removeOrphanedResources: Bool
        let adjustQuotas: Bool
        let createMissingDefaults: Bool

        init(
            fixCircularReferences: Bool = false,
            rebuildPaths: Bool = false,
            removeOrphanedResources: Bool = false,
            adjustQuotas: Bool = false,
            createMissingDefaults: Bool = false
        ) {
            self.fixCircularReferences = fixCircularReferences
            self.rebuildPaths = rebuildPaths
            self.removeOrphanedResources = removeOrphanedResources
            self.adjustQuotas = adjustQuotas
            self.createMissingDefaults = createMissingDefaults
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.fixCircularReferences =
                try container.decodeIfPresent(Bool.self, forKey: .fixCircularReferences) ?? false
            self.rebuildPaths = try container.decodeIfPresent(Bool.self, forKey: .rebuildPaths) ?? false
            self.removeOrphanedResources =
                try container.decodeIfPresent(Bool.self, forKey: .removeOrphanedResources) ?? false
            self.adjustQuotas = try container.decodeIfPresent(Bool.self, forKey: .adjustQuotas) ?? false
            self.createMissingDefaults =
                try container.decodeIfPresent(Bool.self, forKey: .createMissingDefaults) ?? false
        }
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
        self.projectId = vm.projectID
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
