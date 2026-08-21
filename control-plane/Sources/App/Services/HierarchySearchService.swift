import ControlPlanePostgres
import Foundation
import Vapor

/// Case-insensitive search across OUs, projects, and VMs in the hierarchy.
/// Extracted from `HierarchyController`; handlers keep authentication and response
/// wrapping while the query building lives here.
struct HierarchySearchService {

    /// The results the caller may actually read.
    ///
    /// Both searches below narrow on organization membership, which grants
    /// `org:read` and nothing inside it — so a bare member matching on a name
    /// would be told the folder, project or VM exists (issue #870). Each row is
    /// decided on its own node, one batch per entity kind.
    ///
    /// The searches cap each entity kind at 10 rows *before* this runs, so a
    /// filtered search can return fewer than the cap while matches remain
    /// unseen. That is the cap's pre-existing shape — it bounds the query, it
    /// has never been a page — and narrowing it correctly means paging the
    /// search, not deciding more rows than were read.
    static func readable(_ results: [HierarchySearchResult], on req: Request) async throws
        -> [HierarchySearchResult]
    {
        let actions: [String: (action: String, nodeType: IAMNodeType)] = [
            "organizational_unit": ("folder:read", .organizationalUnit),
            "project": ("project:read", .project),
            "vm": ("vm:read", .virtualMachine),
        ]

        var allowedByType: [String: Set<UUID>] = [:]
        for (type, check) in actions {
            let ids = results.filter { $0.type == type }.map(\.id)
            guard !ids.isEmpty else { continue }
            let nodes = ids.map { IAMNode(type: check.nodeType, id: $0) }
            allowedByType[type] = Set(try await req.canFilter(check.action, on: nodes).map(\.id))
        }

        return results.filter { result in
            // A result kind nobody mapped is not silently published: an
            // unmapped kind means a new entity type reached the search without
            // a decision to gate it on.
            guard let allowed = allowedByType[result.type] else { return false }
            return allowed.contains(result.id)
        }
    }

    /// Searches OUs, projects, and VMs within a single organization.
    /// - Parameter entityType: optional filter — `"ou"`, `"project"`, or `"vm"`.
    static func search(organizationID: UUID, query: String, entityType: String?, on db: PostgresStoreContext) async throws
        -> [HierarchySearchResult]
    {
        var results: [HierarchySearchResult] = []
        let folderIDs = try await LegacyOrganizationalUnitStore.organizationalUnits(
            organizationIDs: [organizationID], on: db
        ).compactMap(\.id)
        let scopedProjectIDs = try await LegacyProjectStore.projects(
            organizationIDs: [organizationID], organizationalUnitIDs: folderIDs, on: db
        ).compactMap(\.id)

        // Search OUs if not filtered to specific type
        if entityType == nil || entityType == "ou" {
            let ous = try await LegacyOrganizationalUnitStore.search(
                organizationIDs: [organizationID], query: query, on: db)

            for ou in ous {
                results.append(
                    HierarchySearchResult(
                        id: ou.id!,
                        name: ou.name,
                        type: "organizational_unit",
                        path: ou.path,
                        description: ou.description,
                        parentId: ou.parentOUID,
                        parentType: ou.parentOUID != nil ? "organizational_unit" : "organization"
                    ))
            }
        }

        // Search Projects
        if entityType == nil || entityType == "project" {
            let projects = try await LegacyProjectStore.search(
                organizationIDs: [organizationID], organizationalUnitIDs: folderIDs,
                query: query, on: db)

            for project in projects {
                let parentId = project.organizationID ?? project.organizationalUnitID
                let parentType = project.organizationID != nil ? "organization" : "organizational_unit"

                results.append(
                    HierarchySearchResult(
                        id: project.id!,
                        name: project.name,
                        type: "project",
                        path: project.path,
                        description: project.description,
                        parentId: parentId,
                        parentType: parentType
                    ))
            }
        }

        // Search VMs
        if entityType == nil || entityType == "vm" {
            let needle = query.lowercased()
            let vms = try await LegacyVMStore.vms(projectIDs: scopedProjectIDs, on: db)
                .filter {
                    $0.name.lowercased().contains(needle)
                        || $0.description.lowercased().contains(needle)
                }
                .prefix(10)

            for vm in vms {
                results.append(
                    HierarchySearchResult(
                        id: vm.id!,
                        name: vm.name,
                        type: "vm",
                        path: "",  // VMs don't have paths, but we could build one
                        description: vm.description,
                        parentId: vm.projectID,
                        parentType: "project"
                    ))
            }
        }

        return results
    }

    /// Searches OUs and projects across all organizations the user belongs to.
    static func globalSearch(organizationIDs: [UUID], query: String, entityType: String?, on db: PostgresStoreContext) async throws
        -> [HierarchySearchResult]
    {
        var results: [HierarchySearchResult] = []
        let folderIDs = try await LegacyOrganizationalUnitStore.organizationalUnits(
            organizationIDs: organizationIDs, on: db
        ).compactMap(\.id)

        // Search OUs if not filtered to specific type
        if entityType == nil || entityType == "ou" {
            let ous = try await LegacyOrganizationalUnitStore.search(
                organizationIDs: organizationIDs, query: query, on: db)

            for ou in ous {
                results.append(
                    HierarchySearchResult(
                        id: ou.id!,
                        name: ou.name,
                        type: "organizational_unit",
                        path: ou.path,
                        description: ou.description,
                        parentId: ou.parentOUID,
                        parentType: ou.parentOUID != nil ? "organizational_unit" : "organization"
                    ))
            }
        }

        // Search Projects
        if entityType == nil || entityType == "project" {
            // Get projects directly in organizations
            let directProjects = try await LegacyProjectStore.search(
                organizationIDs: organizationIDs, query: query, on: db)

            // Get projects in OUs within user organizations
            let ouProjects = try await LegacyProjectStore.search(
                organizationalUnitIDs: folderIDs, query: query, on: db)

            for project in directProjects + ouProjects {
                let (parentId, parentType): (UUID?, String) = {
                    if let ouId = project.organizationalUnitID {
                        return (ouId, "organizational_unit")
                    } else if let orgId = project.organizationID {
                        return (orgId, "organization")
                    } else {
                        return (nil, "unknown")
                    }
                }()

                results.append(
                    HierarchySearchResult(
                        id: project.id!,
                        name: project.name,
                        type: "project",
                        path: project.path,
                        description: project.description,
                        parentId: parentId,
                        parentType: parentType
                    ))
            }
        }

        return results
    }
}
