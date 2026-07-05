import Foundation
import Vapor
import Fluent

/// Case-insensitive search across OUs, projects, and VMs in the hierarchy.
/// Extracted from `HierarchyController`; handlers keep authentication and response
/// wrapping while the query building lives here.
struct HierarchySearchService {
    /// Searches OUs, projects, and VMs within a single organization.
    /// - Parameter entityType: optional filter — `"ou"`, `"project"`, or `"vm"`.
    static func search(organizationID: UUID, query: String, entityType: String?, on db: Database) async throws -> [HierarchySearchResult] {
        var results: [HierarchySearchResult] = []

        // Search OUs if not filtered to specific type
        if entityType == nil || entityType == "ou" {
            let ous = try await OrganizationalUnit.query(on: db)
                .filter(\.$organization.$id == organizationID)
                .group(.or) { or in
                    or.filter(.caseInsensitiveContains(schema: OrganizationalUnit.schema, column: "name", value: query))
                    or.filter(.caseInsensitiveContains(schema: OrganizationalUnit.schema, column: "description", value: query))
                }
                .limit(10)
                .all()

            for ou in ous {
                results.append(HierarchySearchResult(
                    id: ou.id!,
                    name: ou.name,
                    type: "organizational_unit",
                    path: ou.path,
                    description: ou.description,
                    parentId: ou.$parentOU.id,
                    parentType: ou.$parentOU.id != nil ? "organizational_unit" : "organization"
                ))
            }
        }

        // Search Projects
        if entityType == nil || entityType == "project" {
            let projects = try await Project.query(on: db)
                .group(.or) { or in
                    or.filter(\.$organization.$id == organizationID)
                    or.join(OrganizationalUnit.self, on: \Project.$organizationalUnit.$id == \OrganizationalUnit.$id)
                        .filter(OrganizationalUnit.self, \.$organization.$id == organizationID)
                }
                .group(.or) { or in
                    or.filter(.caseInsensitiveContains(schema: Project.schema, column: "name", value: query))
                    or.filter(.caseInsensitiveContains(schema: Project.schema, column: "description", value: query))
                }
                .limit(10)
                .all()

            for project in projects {
                let parentId = project.$organization.id ?? project.$organizationalUnit.id
                let parentType = project.$organization.id != nil ? "organization" : "organizational_unit"

                results.append(HierarchySearchResult(
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
            let vms = try await VM.query(on: db)
                .join(Project.self, on: \VM.$project.$id == \Project.$id)
                .group(.or) { or in
                    or.filter(Project.self, \.$organization.$id == organizationID)
                    or.join(OrganizationalUnit.self, on: \Project.$organizationalUnit.$id == \OrganizationalUnit.$id)
                        .filter(OrganizationalUnit.self, \.$organization.$id == organizationID)
                }
                .group(.or) { or in
                    or.filter(.caseInsensitiveContains(schema: VM.schema, column: "name", value: query))
                    or.filter(.caseInsensitiveContains(schema: VM.schema, column: "description", value: query))
                }
                .limit(10)
                .all()

            for vm in vms {
                results.append(HierarchySearchResult(
                    id: vm.id!,
                    name: vm.name,
                    type: "vm",
                    path: "", // VMs don't have paths, but we could build one
                    description: vm.description,
                    parentId: vm.$project.id,
                    parentType: "project"
                ))
            }
        }

        return results
    }

    /// Searches OUs and projects across all organizations the user belongs to.
    static func globalSearch(organizationIDs: [UUID], query: String, entityType: String?, on db: Database) async throws -> [HierarchySearchResult] {
        var results: [HierarchySearchResult] = []

        // Search OUs if not filtered to specific type
        if entityType == nil || entityType == "ou" {
            let ous = try await OrganizationalUnit.query(on: db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .group(.or) { or in
                    or.filter(.caseInsensitiveContains(schema: OrganizationalUnit.schema, column: "name", value: query))
                    or.filter(.caseInsensitiveContains(schema: OrganizationalUnit.schema, column: "description", value: query))
                }
                .limit(10)
                .all()

            for ou in ous {
                results.append(HierarchySearchResult(
                    id: ou.id!,
                    name: ou.name,
                    type: "organizational_unit",
                    path: ou.path,
                    description: ou.description,
                    parentId: ou.$parentOU.id,
                    parentType: ou.$parentOU.id != nil ? "organizational_unit" : "organization"
                ))
            }
        }

        // Search Projects
        if entityType == nil || entityType == "project" {
            // Get projects directly in organizations
            let directProjects = try await Project.query(on: db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .group(.or) { or in
                    or.filter(.caseInsensitiveContains(schema: Project.schema, column: "name", value: query))
                    or.filter(.caseInsensitiveContains(schema: Project.schema, column: "description", value: query))
                }
                .limit(10)
                .all()

            // Get projects in OUs within user organizations
            let ouProjects = try await Project.query(on: db)
                .join(OrganizationalUnit.self, on: \Project.$organizationalUnit.$id == \OrganizationalUnit.$id)
                .filter(OrganizationalUnit.self, \.$organization.$id ~~ organizationIDs)
                .group(.or) { or in
                    or.filter(.caseInsensitiveContains(schema: Project.schema, column: "name", value: query))
                    or.filter(.caseInsensitiveContains(schema: Project.schema, column: "description", value: query))
                }
                .limit(10)
                .all()

            for project in directProjects + ouProjects {
                let (parentId, parentType): (UUID?, String) = {
                    if let ouId = project.$organizationalUnit.id {
                        return (ouId, "organizational_unit")
                    } else if let orgId = project.$organization.id {
                        return (orgId, "organization")
                    } else {
                        return (nil, "unknown")
                    }
                }()

                results.append(HierarchySearchResult(
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
