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

    /// The folders the caller may read in their own right, as opposed to those
    /// `readable(on:)` additionally retains to keep the tree connected. Equal to
    /// `folders` until that narrowing runs.
    ///
    /// The two differ only for a caller who can read a project but not the
    /// folders it is nested in, and the distinction matters because only the
    /// nested tree needs the ancestors: a flat list of folders has nothing to
    /// connect, so it shows `decidedFolders` and no more.
    var decidedFolders: [OrganizationalUnit] {
        guard let decidedFolderIDs else { return folders }
        return folders.filter { folder in folder.id.map(decidedFolderIDs.contains) ?? false }
    }

    private let decidedFolderIDs: Set<UUID>?

    static func load(organizationID: UUID, on db: Database) async throws -> HierarchySnapshot {
        let folders = try await LegacyOrganizationalUnitStore.organizationalUnits(
            organizationIDs: [organizationID], on: db)
        let folderIDs = folders.compactMap { $0.id }

        let projects = try await Project.all(inOrganization: organizationID, folders: folderIDs, on: db)
        let projectIDs = projects.compactMap { $0.id }

        var vms: [VM] = []
        if !projectIDs.isEmpty {
            vms = try await LegacyVMStore.vms(projectIDs: projectIDs, on: db)
        }

        let quotas = try await LegacyResourceQuotaStore.hierarchy(
            organizationID: organizationID,
            organizationalUnitIDs: folderIDs,
            projectIDs: projectIDs,
            on: db)

        return HierarchySnapshot(
            organizationID: organizationID,
            folders: folders,
            projects: projects,
            vms: vms,
            quotas: quotas,
            decidedFolderIDs: nil
        )
    }

    // MARK: - Visibility

    /// The snapshot narrowed to the rows the caller may actually read.
    ///
    /// The hierarchy endpoints gate on `view_organization`, which bare org
    /// membership grants — so without this they hand a bare member every
    /// folder, project and VM in the organization, the same disclosure the
    /// project list endpoints made (issue #870). Reaching a container is not
    /// reaching its contents; each row is put to the evaluator on its own node,
    /// three batched decisions for the whole tree.
    ///
    /// One row is kept without a decision of its own: folders on the path down
    /// to a project the caller *can* read. Dropping them would strand the
    /// project outside the nesting, and the project's own materialized `path`
    /// (which `GET /api/projects/{id}/path` already hands to any project member)
    /// names them anyway. Their quotas are not kept — only folders that survive
    /// `folder:read` contribute those.
    ///
    /// That argument is about *nesting*, so it only holds for the tree: a
    /// consumer with nothing to connect reads `decidedFolders` instead, and
    /// never sees a folder it did not earn.
    ///
    /// Quotas are the exception to "the container gate implies it": an
    /// organization-scoped quota used to ride the handler's `view_organization`
    /// on the grounds that it describes that organization, but its `usage` and
    /// `utilization` are the organization's measured consumption, not a
    /// description — the inventory above in scalar form. They go through
    /// ``QuotaVisibility``, which is the one gate every route onto that number
    /// shares.
    func readable(on req: Request) async throws -> HierarchySnapshot {
        let readableFolderIDs = Set(
            try await req.canFilter(
                "folder:read",
                on: folders.compactMap { folder in folder.id.map { IAMNode(type: .organizationalUnit, id: $0) } }
            ).map(\.id))
        let readableProjectIDs = Set(
            try await req.canFilter(
                "project:read",
                on: projects.compactMap { project in project.id.map { IAMNode(type: .project, id: $0) } }
            ).map(\.id))
        let readableVMIDs = Set(
            try await req.canFilter(
                "vm:read",
                on: vms.compactMap { vm in vm.id.map { IAMNode(type: .virtualMachine, id: $0) } }
            ).map(\.id))

        let keptProjects = projects.filter { project in project.id.map(readableProjectIDs.contains) ?? false }

        // Retain each surviving folder's ancestor chain, so the tree the
        // builder walks is still connected. Stopping at an id already retained
        // is safe: every insertion walks its own chain to the root.
        let foldersByID = Dictionary(
            folders.compactMap { folder in folder.id.map { ($0, folder) } },
            uniquingKeysWith: { first, _ in first })
        var keptFolderIDs: Set<UUID> = []
        func retainChain(from folderID: UUID?) {
            var current = folderID
            while let id = current, !keptFolderIDs.contains(id) {
                keptFolderIDs.insert(id)
                current = foldersByID[id]?.parentOUID
            }
        }
        for folderID in readableFolderIDs { retainChain(from: folderID) }
        for project in keptProjects { retainChain(from: project.organizationalUnitID) }

        return HierarchySnapshot(
            organizationID: organizationID,
            folders: folders.filter { folder in folder.id.map(keptFolderIDs.contains) ?? false },
            projects: keptProjects,
            vms: vms.filter { vm in
                readableProjectIDs.contains(vm.projectID) && (vm.id.map(readableVMIDs.contains) ?? false)
            },
            quotas: try await QuotaVisibility.readable(quotas, on: req),
            decidedFolderIDs: readableFolderIDs
        )
    }

    // MARK: - In-memory projections

    /// The folders directly under the organization.
    var topLevelFolders: [OrganizationalUnit] {
        folders.filter { $0.parentOUID == nil }
    }

    func childFolders(of folderID: UUID) -> [OrganizationalUnit] {
        folders.filter { $0.parentOUID == folderID }
    }

    func projects(in folderID: UUID) -> [Project] {
        projects.filter { $0.organizationalUnitID == folderID }
    }

    /// Projects hanging directly off the organization rather than off a folder.
    var directProjects: [Project] {
        projects.filter { $0.organizationID == organizationID }
    }

    func vms(in projectID: UUID) -> [VM] {
        vms.filter { $0.projectID == projectID }
    }

    func quotas(forOrganization organizationID: UUID) -> [ResourceQuota] {
        quotas.filter { $0.organizationID == organizationID }
    }

    func quotas(forFolder folderID: UUID) -> [ResourceQuota] {
        quotas.filter { $0.organizationalUnitID == folderID }
    }

    func quotas(forProject projectID: UUID) -> [ResourceQuota] {
        quotas.filter { $0.projectID == projectID }
    }

    var maxDepth: Int {
        folders.map { $0.depth }.max() ?? 0
    }

    var resourceUsage: ResourceUsageResponse {
        Self.resourceUsage(of: vms)
    }

    /// Totals over a set of VMs.
    static func resourceUsage(of vms: [VM]) -> ResourceUsageResponse {
        ResourceUsageResponse(
            totalVCPUs: vms.reduce(0) { $0 + $1.cpu },
            totalMemoryGB: vms.reduce(Int64(0)) { $0 + $1.memory }.bytesToGB,
            totalStorageGB: vms.reduce(Int64(0)) { $0 + $1.disk }.bytesToGB,
            totalVMs: vms.count
        )
    }
}
