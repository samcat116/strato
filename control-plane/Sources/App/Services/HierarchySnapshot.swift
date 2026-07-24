import Fluent
import Foundation
import Vapor

/// Every row the hierarchy endpoints report on, read in four flat queries:
/// the organization's folders, their projects, those projects' VMs, and every
/// quota attached anywhere in the organization.
///
/// One load serves the tree, the aggregate stats and the resource totals alike.
/// The recursive walk this replaced re-derived the project list for each of
/// them and fetched VMs one query per project, so a 20-folder / 50-project
/// organization cost hundreds of round-trips per request (issue #692).
struct HierarchySnapshot {
    let organizationID: UUID
    let folders: [OrganizationalUnit]
    let projects: [Project]
    let vms: [VM]
    let quotas: [ResourceQuota]

    static func load(organizationID: UUID, on db: Database) async throws -> HierarchySnapshot {
        let folders = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$depth)
            .sort(\.$name)
            .all()
        let folderIDs = folders.compactMap { $0.id }

        let projects = try await Project.all(inOrganization: organizationID, folders: folderIDs, on: db)
        let projectIDs = projects.compactMap { $0.id }

        var vms: [VM] = []
        if !projectIDs.isEmpty {
            vms = try await VM.query(on: db)
                .filter(\.$project.$id ~~ projectIDs)
                .all()
        }

        let quotas = try await ResourceQuota.query(on: db)
            .group(.or) { anyQuota in
                anyQuota.filter(\.$organization.$id == organizationID)
                if !folderIDs.isEmpty {
                    anyQuota.filter(\.$organizationalUnit.$id ~~ folderIDs)
                }
                if !projectIDs.isEmpty {
                    anyQuota.filter(\.$project.$id ~~ projectIDs)
                }
            }
            .all()

        return HierarchySnapshot(
            organizationID: organizationID,
            folders: folders,
            projects: projects,
            vms: vms,
            quotas: quotas
        )
    }

    // MARK: - In-memory projections

    /// The folders directly under the organization.
    var topLevelFolders: [OrganizationalUnit] {
        folders.filter { $0.$parentOU.id == nil }
    }

    func childFolders(of folderID: UUID) -> [OrganizationalUnit] {
        folders.filter { $0.$parentOU.id == folderID }
    }

    func projects(in folderID: UUID) -> [Project] {
        projects.filter { $0.$organizationalUnit.id == folderID }
    }

    /// Projects hanging directly off the organization rather than off a folder.
    var directProjects: [Project] {
        projects.filter { $0.$organization.id == organizationID }
    }

    func vms(in projectID: UUID) -> [VM] {
        vms.filter { $0.$project.id == projectID }
    }

    func quotas(forOrganization organizationID: UUID) -> [ResourceQuota] {
        quotas.filter { $0.$organization.id == organizationID }
    }

    func quotas(forFolder folderID: UUID) -> [ResourceQuota] {
        quotas.filter { $0.$organizationalUnit.id == folderID }
    }

    func quotas(forProject projectID: UUID) -> [ResourceQuota] {
        quotas.filter { $0.$project.id == projectID }
    }

    var maxDepth: Int {
        folders.map { $0.depth }.max() ?? 0
    }

    var resourceUsage: ResourceUsageResponse {
        Self.resourceUsage(of: vms)
    }

    /// Totals over a set of VMs. Shared with `Organization.getResourceUsage` so
    /// both routes to the same figures agree.
    static func resourceUsage(of vms: [VM]) -> ResourceUsageResponse {
        ResourceUsageResponse(
            totalVCPUs: vms.reduce(0) { $0 + $1.cpu },
            totalMemoryGB: vms.reduce(Int64(0)) { $0 + $1.memory }.bytesToGB,
            totalStorageGB: vms.reduce(Int64(0)) { $0 + $1.disk }.bytesToGB,
            totalVMs: vms.count
        )
    }
}
