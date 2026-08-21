import ControlPlanePostgres
import Foundation
import Vapor

/// Hierarchy validation and repair.
///
/// The org tree is stored twice: as relational links (`Project.organizational_unit_id`
/// → `OrganizationalUnit.parent_ou_id` → organization) and as the materialized
/// `path` string each folder and project carries. The links are the source of
/// truth — authorization resolves ancestry through them — so validation means
/// re-deriving every path from the links and reporting the rows that disagree.
///
/// This is what makes a partial path rewrite discoverable: the folder-move
/// endpoint used to rewrite descendant *folders* only, leaving projects beneath a
/// moved subtree naming an ancestor they no longer have, and nothing surfaced it
/// (issue #871). Breadcrumbs, search results and the `path` on every project
/// response read that field.
///
/// Both entry points scan every organization — they back system-admin-only
/// endpoints and drift is not org-scoped — so they read the folder and project
/// tables whole, once, and derive everything else in memory. That is the cost
/// ceiling to know about: every folder and every project in the installation is
/// materialized in one process, and a repair does it twice (once to find, once
/// to report what remains). Chunking per organization would only move the loop,
/// so it stays whole until an installation is large enough for that to hurt.
struct HierarchyMaintenanceService {
    static func findHierarchyIssues(on db: PostgresStoreContext) async throws -> [HierarchyIssue] {
        try await scan(on: db).issues
    }

    static func performHierarchyRepair(repairRequest: HierarchyRepairRequest, on db: PostgresStoreContext) async throws
        -> HierarchyRepairResponse
    {
        let scan = try await scan(on: db)

        // Path rebuilds are the only repair implemented; the other options
        // describe issue classes nothing detects yet, so they select nothing.
        let selected = scan.issues.filter { issue in
            guard issue.autoRepairable, issue.type == IssueType.brokenPath else { return false }
            guard repairRequest.repairOptions.rebuildPaths else { return false }
            if repairRequest.repairAll { return true }
            return repairRequest.specificIssues?.contains(issue.id) ?? false
        }

        let repaired = try await db.transaction { transaction -> [HierarchyRepairResponse.RepairedIssue] in
            var repaired: [HierarchyRepairResponse.RepairedIssue] = []
            for issue in selected {
                if let fix = scan.folderFixes[issue.id] {
                    let previous = "\(fix.folder.path) (depth \(fix.folder.depth))"
                    try await fix.folder.replacingPath(fix.path, depth: fix.depth).save(on: transaction)
                    repaired.append(
                        .init(
                            issueId: issue.id,
                            issueType: issue.type,
                            action: "rebuilt_path",
                            details: "Folder '\(issue.entityName)' path rebuilt from \(previous) "
                                + "to \(fix.path) (depth \(fix.depth))"
                        ))
                } else if let fix = scan.projectFixes[issue.id] {
                    let previous = fix.project.path
                    try await fix.project.replacingPath(fix.path).save(on: transaction)
                    repaired.append(
                        .init(
                            issueId: issue.id,
                            issueType: issue.type,
                            action: "rebuilt_path",
                            details: "Project '\(issue.entityName)' path rebuilt from \(previous) to \(fix.path)"
                        ))
                }
            }
            return repaired
        }

        // A deliberate second full pass, not a subtraction of what was repaired:
        // the report describes the tree as it now stands, which is the only form
        // a caller can act on. It costs a second scan of both tables — including
        // during the boot-time hierarchy repair.
        let remaining = try await findHierarchyIssues(on: db)

        var summary = "Repaired \(repaired.count) of \(scan.issues.count) issues; \(remaining.count) remain."
        if !repairRequest.repairOptions.rebuildPaths && scan.issues.contains(where: { $0.autoRepairable }) {
            summary += " Repairable path issues were found but `rebuildPaths` was not requested."
        }

        return HierarchyRepairResponse(
            // The tree is healthy, not merely "every repair we were asked for
            // applied" — the latter is true of a request that asked for nothing
            // and of a tree whose only remaining issue is one nothing can repair,
            // which is exactly when a caller polling this must not see green.
            success: remaining.isEmpty,
            repairedIssues: repaired,
            remainingIssues: remaining,
            summary: summary
        )
    }

    // MARK: - Scan

    private enum IssueType {
        static let brokenPath = "broken_path"
        static let circularReference = "circular_reference"
        static let orphanedResource = "orphaned_resource"
    }

    private enum Severity {
        static let critical = "critical"
        static let warning = "warning"
    }

    /// What a folder's materialized path *should* be, derived from its parent
    /// chain — or why it cannot be derived at all.
    private enum Expectation {
        case path(String, depth: Int)
        /// The parent chain loops, so it never reaches an organization.
        case cycle
        /// The parent chain hits a folder id with no row behind it.
        case severed
    }

    private struct Scan {
        var issues: [HierarchyIssue] = []
        var folderFixes: [UUID: (folder: OrganizationalUnit, path: String, depth: Int)] = [:]
        var projectFixes: [UUID: (project: Project, path: String)] = [:]
    }

    private static func scan(on db: PostgresStoreContext) async throws -> Scan {
        let folders = try await OrganizationalUnit.all(on: db)
        let projects = try await Project.all(on: db)

        let foldersByID = Dictionary(
            folders.compactMap { folder in folder.id.map { ($0, folder) } },
            uniquingKeysWith: { first, _ in first })

        // Memoized over the parent chain: a folder's expectation is the same
        // whichever descendant asked for it, and a chain that loops is a cycle
        // for every folder on it.
        //
        // The asymmetry in what gets cached is load-bearing, not an oversight:
        // the `.cycle` returned from the `seen` hit is a statement about the
        // chain currently being walked, so it is *not* cached, while the
        // `.cycle` each frame propagates upward is a property of that folder, so
        // it is. Caching the first would poison the entry for a folder that only
        // appears mid-walk.
        var expectations: [UUID: Expectation] = [:]
        func expectation(for folderID: UUID, seen: Set<UUID>) -> Expectation {
            if let cached = expectations[folderID] { return cached }
            guard let folder = foldersByID[folderID] else { return .severed }
            if seen.contains(folderID) { return .cycle }

            let result: Expectation
            if let parentID = folder.parentOUID {
                switch expectation(for: parentID, seen: seen.union([folderID])) {
                case .path(let parentPath, let parentDepth):
                    result = .path(
                        OrganizationalUnit.path(under: parentPath, folderID: folderID),
                        depth: parentDepth + 1)
                case .cycle:
                    result = .cycle
                case .severed:
                    result = .severed
                }
            } else {
                let organizationPath = OrganizationalUnit.organizationPath(folder.organizationID)
                result = .path(OrganizationalUnit.path(under: organizationPath, folderID: folderID), depth: 0)
            }

            expectations[folderID] = result
            return result
        }

        var scan = Scan()

        for folder in folders {
            guard let folderID = folder.id else { continue }
            switch expectation(for: folderID, seen: []) {
            case .path(let expected, let expectedDepth):
                guard folder.path != expected || folder.depth != expectedDepth else { continue }
                scan.folderFixes[folderID] = (folder, expected, expectedDepth)
                scan.issues.append(
                    HierarchyIssue(
                        id: folderID,
                        type: IssueType.brokenPath,
                        severity: Severity.warning,
                        entityType: "ou",
                        entityId: folderID,
                        entityName: folder.name,
                        description: "Folder '\(folder.name)' stores path \(folder.path) (depth \(folder.depth)) "
                            + "but its parent chain gives \(expected) (depth \(expectedDepth)).",
                        suggestedFix: rebuildPathFix,
                        autoRepairable: true
                    ))
            case .cycle:
                scan.issues.append(
                    HierarchyIssue(
                        id: folderID,
                        type: IssueType.circularReference,
                        severity: Severity.critical,
                        entityType: "ou",
                        entityId: folderID,
                        entityName: folder.name,
                        description: "Folder '\(folder.name)' has a parent chain that enters a cycle, so it "
                            + "never reaches an organization.",
                        suggestedFix: "Reparent one folder in the cycle so the chain terminates at the organization.",
                        autoRepairable: false
                    ))
            case .severed:
                // Unreachable while the schema holds: `parent_ou_id` is a
                // foreign key with `onDelete: .cascade`, so deleting a parent
                // takes its children with it rather than severing them, and the
                // scan loads every folder. Kept as defense against that
                // constraint being dropped — a severed chain is fail-open for
                // guardrails (see `iam.md`), so it should be reported loudly
                // rather than discovered later.
                //
                // Only the folder whose own parent is missing is reported: every
                // folder below it is severed as a consequence, and naming them
                // all buries the one break an operator has to fix.
                guard let parentID = folder.parentOUID, foldersByID[parentID] == nil else { continue }
                scan.issues.append(
                    HierarchyIssue(
                        id: folderID,
                        type: IssueType.orphanedResource,
                        severity: Severity.critical,
                        entityType: "ou",
                        entityId: folderID,
                        entityName: folder.name,
                        description: "Folder '\(folder.name)' names parent folder \(parentID), which does not exist.",
                        suggestedFix: "Reparent the folder onto an existing folder or the organization root.",
                        autoRepairable: false
                    ))
            }
        }

        for project in projects {
            guard let projectID = project.id else { continue }

            let parentPath: String
            if let folderID = project.organizationalUnitID {
                // Unreachable for the same reason as the folder case above:
                // `organizational_unit_id` cascades. Defense against a dropped
                // constraint, not a live shape.
                guard foldersByID[folderID] != nil else {
                    scan.issues.append(
                        HierarchyIssue(
                            id: projectID,
                            type: IssueType.orphanedResource,
                            severity: Severity.critical,
                            entityType: "project",
                            entityId: projectID,
                            entityName: project.name,
                            description: "Project '\(project.name)' names folder \(folderID), which does not exist.",
                            suggestedFix: "Move the project onto an existing folder or the organization root.",
                            autoRepairable: false
                        ))
                    continue
                }
                // A folder whose own path cannot be derived was reported in its
                // own right; the project's path is not independently checkable.
                guard case .path(let folderPath, _) = expectation(for: folderID, seen: []) else { continue }
                parentPath = folderPath
            } else if let organizationID = project.organizationID {
                parentPath = OrganizationalUnit.organizationPath(organizationID)
            } else {
                // This one is live: both columns are nullable and the check
                // constraint that would forbid the pair was never added, so only
                // `Project.validate()` stands between the API and such a row.
                scan.issues.append(
                    HierarchyIssue(
                        id: projectID,
                        type: IssueType.orphanedResource,
                        severity: Severity.critical,
                        entityType: "project",
                        entityId: projectID,
                        entityName: project.name,
                        description: "Project '\(project.name)' belongs to neither a folder nor an organization.",
                        suggestedFix: "Attach the project to a folder or an organization.",
                        autoRepairable: false
                    ))
                continue
            }

            let expected = Project.path(under: parentPath, projectID: projectID)
            guard project.path != expected else { continue }
            scan.projectFixes[projectID] = (project, expected)
            scan.issues.append(
                HierarchyIssue(
                    id: projectID,
                    type: IssueType.brokenPath,
                    severity: Severity.warning,
                    entityType: "project",
                    entityId: projectID,
                    entityName: project.name,
                    description: "Project '\(project.name)' stores path \(project.path) but its parent gives "
                        + "\(expected).",
                    suggestedFix: rebuildPathFix,
                    autoRepairable: true
                ))
        }

        // Stable order, so two calls over an unchanged tree agree and a diff of
        // two reports means something.
        scan.issues.sort { lhs, rhs in
            let lhsRank = severityRank(lhs.severity)
            let rhsRank = severityRank(rhs.severity)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.entityType != rhs.entityType { return lhs.entityType < rhs.entityType }
            return lhs.entityId.uuidString < rhs.entityId.uuidString
        }
        return scan
    }

    private static let rebuildPathFix =
        "Run POST /api/hierarchy/repair with `repairOptions.rebuildPaths` to rewrite the stored path."

    private static func severityRank(_ severity: String) -> Int {
        switch severity {
        case Severity.critical: return 0
        case Severity.warning: return 1
        default: return 2
        }
    }
}
