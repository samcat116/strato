import Foundation
import Vapor
import Fluent

struct ResourceQuotaController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Global quota routes
        let quotas = routes.grouped("api", "quotas")
        quotas.get(use: indexByLevel)  // Add route for /quotas?level=...
        quotas.group(":quotaID") { quota in
            quota.get(use: show)
            quota.put(use: update)
            quota.delete(use: delete)
            quota.get("usage", use: getUsage)
        }

        // Organization context routes
        let organizations = routes.grouped("api", "organizations")
        organizations.group(":organizationID") { org in
            let orgQuotas = org.grouped("quotas")
            orgQuotas.get(use: indexForOrganization)
            orgQuotas.post(use: createForOrganization)

            // OU context routes
            org.group("ous", ":ouID", "quotas") { ouQuotas in
                ouQuotas.get(use: indexForOU)
                ouQuotas.post(use: createForOU)
            }
        }

        // Project context routes
        let projects = routes.grouped("api", "projects")
        projects.group(":projectID", "quotas") { projQuotas in
            projQuotas.get(use: indexForProject)
            projQuotas.post(use: createForProject)
        }
    }

    // MARK: - Resource Quota CRUD Operations

    /// Query params: level (optional),
    /// limit/offset (optional) — select the page.
    func indexByLevel(req: Request) async throws -> PagedResponse<ResourceQuotaResponse> {
        let paging = try ListPaging.decode(from: req)
        let quotas = try await visibleQuotas(req: req)
        return paging.page(quotas)
    }

    /// Every quota hanging on a scope the caller may read, by name, ready for
    /// slicing.
    ///
    /// `readableQuotas` below is the gate; everything here is only the bound
    /// that runs before it. Which matters because the two must not be derived
    /// from the same thing: a bound taken from membership rows silently decides
    /// too, by never putting a row in front of the evaluator. Project rows are
    /// therefore bounded by the caller's *grants* (`ProjectVisibility`, as every
    /// other project-scoped list does), so a caller whose only grant is a
    /// binding on a project — with no `user_organizations` row for that
    /// project's organization — still reaches that project's quota. Org and
    /// folder rows keep the membership bound, because `readableQuotas` decides
    /// both on `org:read` of the owning organization and no wider bound would
    /// survive that.
    func visibleQuotas(req: Request) async throws -> [ResourceQuotaResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let level = req.query[String.self, at: "level"]

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)
        let organizationIDs = user.organizations.compactMap { $0.id }

        let ouIDs =
            organizationIDs.isEmpty
            ? []
            : try await OrganizationalUnit.query(on: req.db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .all()
                .compactMap { $0.id }

        // The projects the caller's own grants reach. Nil means "no bound"
        // (a system admin, an unbounded authored permit), not "everything is
        // visible" — those rows are still decided below.
        let visibility = try await ProjectVisibility.resolve(on: req)

        var query = ResourceQuota.query(on: req.db)

        switch level {
        case "organization":
            if organizationIDs.isEmpty {
                return []
            }
            query = query.filter(\.$organization.$id ~~ organizationIDs)
                .filter(\.$organizationalUnit.$id == nil)
                .filter(\.$project.$id == nil)
        case "project":
            if visibility.reachesNoProject {
                return []
            }
            query = query.filter(\.$project.$id != nil)
            if let candidates = visibility.candidateProjectIDs {
                query = query.filter(\.$project.$id ~~ candidates)
            }
        case "organizational_unit":
            if ouIDs.isEmpty {
                return []
            }
            query = query.filter(\.$organizationalUnit.$id ~~ ouIDs)
                .filter(\.$project.$id == nil)
        default:
            // Every level at once. Folder- and project-scoped rows used to be
            // dropped here (a standing TODO) because nothing decided them; now
            // that `readableQuotas` decides each one they belong in the
            // unfiltered list.
            if organizationIDs.isEmpty, ouIDs.isEmpty, visibility.reachesNoProject {
                return []
            }
            query = query.group(.or) { anyQuota in
                if !organizationIDs.isEmpty {
                    anyQuota.filter(\.$organization.$id ~~ organizationIDs)
                }
                if !ouIDs.isEmpty {
                    anyQuota.filter(\.$organizationalUnit.$id ~~ ouIDs)
                }
                if let candidates = visibility.candidateProjectIDs {
                    if !candidates.isEmpty {
                        anyQuota.filter(\.$project.$id ~~ candidates)
                    }
                } else {
                    anyQuota.filter(\.$project.$id != nil)
                }
            }
        }

        let quotas = try await query.sort(\.$name).sort(\.$id).all()
        return try await readableQuotas(quotas, on: req).map { ResourceQuotaResponse(from: $0) }
    }

    /// Drop the quota rows the caller may not read, deciding each through the
    /// evaluator exactly as the matching item route (`verifyQuotaAccess`) does.
    ///
    /// The membership filters above only bound the candidate set to the
    /// caller's organizations; they are not the item route's gate. Each scope
    /// goes through its own decision here (STR-116), so a guardrail forbid or a
    /// revoked binding narrows the list the same way it narrows the object read
    /// — otherwise the list keeps showing a quota the item route now 403s.
    ///
    /// The question is `quota:read` on the node the row hangs on, for every
    /// scope. It was `org:read` for org- and folder-scoped rows, matching the
    /// `requireMember` the item route then used; both moved together, because
    /// the row ships `usage`/`utilization` — the scope's measured consumption —
    /// and bare membership must not reach it. See ``QuotaVisibility``.
    ///
    /// A scopeless row is never in the input — the queries above always filter
    /// on a scope FK — but is dropped defensively; the item route requires
    /// system admin for one.
    private func readableQuotas(_ quotas: [ResourceQuota], on req: Request) async throws
        -> [ResourceQuota]
    {
        try await QuotaVisibility.readable(quotas, on: req)
    }

    func show(req: Request) async throws -> ResourceQuotaResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has access to quota
        try await verifyQuotaAccess(quota: quota, on: req)

        return ResourceQuotaResponse(from: quota)
    }

    func update(req: Request) async throws -> ResourceQuotaResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        let updateRequest = try req.content.decodeValidated(UpdateResourceQuotaRequest.self)

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has admin access to quota
        try await verifyQuotaAdminAccess(quota: quota, on: req)

        // Measure the scope before evaluating the "not below current usage" guards
        // below. The stored counters are only a cache of the last resync — zero for
        // any quota row nothing has resynced yet — so reading them let an admin set
        // a limit under real usage (issue #742). The refreshed figures are persisted
        // by the `save` at the end, healing the row on the way past. A concurrent
        // create can land between the measurement and the save, but admission
        // always resyncs before it checks, so a momentarily low cache can't
        // over-commit anything.
        try await QuotaEnforcementService.resyncReservations(quota, on: req.db)

        // Update fields
        if let name = updateRequest.name {
            quota.name = name
        }

        if let maxVCPUs = updateRequest.maxVCPUs {
            // Ensure new limit isn't below current reservation
            if maxVCPUs < quota.reservedVCPUs {
                throw Abort(
                    .badRequest,
                    reason: "New vCPU limit (\(maxVCPUs)) cannot be below current reservation (\(quota.reservedVCPUs))")
            }
            quota.maxVCPUs = maxVCPUs
        }

        if let maxMemoryGB = updateRequest.maxMemoryGB {
            let maxMemoryBytes = maxMemoryGB.gbToBytes
            if maxMemoryBytes < quota.reservedMemory {
                let currentReservedGB = Double(quota.reservedMemory) / 1024 / 1024 / 1024
                throw Abort(
                    .badRequest,
                    reason:
                        "New memory limit (\(String(format: "%.2f", maxMemoryGB))GiB) cannot be below current reservation (\(String(format: "%.2f", currentReservedGB))GiB)"
                )
            }
            quota.maxMemory = maxMemoryBytes
        }

        if let maxStorageGB = updateRequest.maxStorageGB {
            let maxStorageBytes = maxStorageGB.gbToBytes
            if maxStorageBytes < quota.reservedStorage {
                let currentReservedGB = Double(quota.reservedStorage) / 1024 / 1024 / 1024
                throw Abort(
                    .badRequest,
                    reason:
                        "New storage limit (\(String(format: "%.2f", maxStorageGB))GiB) cannot be below current reservation (\(String(format: "%.2f", currentReservedGB))GiB)"
                )
            }
            quota.maxStorage = maxStorageBytes
        }

        if let maxVMs = updateRequest.maxVMs {
            if maxVMs < quota.vmCount {
                throw Abort(
                    .badRequest, reason: "New VM limit (\(maxVMs)) cannot be below current count (\(quota.vmCount))")
            }
            quota.maxVMs = maxVMs
        }

        if let maxSandboxes = updateRequest.maxSandboxes {
            if maxSandboxes < quota.sandboxCount {
                throw Abort(
                    .badRequest,
                    reason:
                        "New sandbox limit (\(maxSandboxes)) cannot be below current count (\(quota.sandboxCount))")
            }
            quota.maxSandboxes = maxSandboxes
        }

        if let maxNetworks = updateRequest.maxNetworks {
            quota.maxNetworks = maxNetworks
        }

        if let isEnabled = updateRequest.isEnabled {
            quota.isEnabled = isEnabled
        }

        // Scope and limit invariants only. The counters now hold real usage, and a
        // scope already over a limit this request didn't touch must stay editable —
        // raising, disabling or renaming such a quota is exactly how an operator
        // fixes it. Every limit this request *did* change was checked against the
        // same fresh figures above.
        try quota.validate()
        try await quota.save(on: req.db)

        return ResourceQuotaResponse(from: quota)
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has admin access to quota
        try await verifyQuotaAdminAccess(quota: quota, on: req)

        // Check if the quota's scope holds any workloads, measured now rather than
        // read from the stored counters: those are a cache of the last enforcement
        // resync and are still zero for a quota created over an already populated
        // scope, so the guard used to wave through the deletion of a quota holding
        // back live VMs and sandboxes (issue #742).
        //
        // Measures without writing the figures back, unlike `update`: the row is
        // either about to be deleted or is being left alone by a rejected request,
        // so there is nothing here for a healed cache to be read by.
        let usage = try await QuotaUsageAggregator.measure(quota: quota, on: req.db)
        if usage.vcpus > 0 || usage.memoryBytes > 0 || usage.storageBytes > 0 || usage.vmCount > 0
            || usage.sandboxCount > 0
        {
            throw Abort(.conflict, reason: "Cannot delete quota with active resource reservations")
        }

        try await quota.delete(on: req.db)
        return .noContent
    }

    // MARK: - Organization Context Operations

    func indexForOrganization(req: Request) async throws -> [ResourceQuotaResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Get all quotas for the organization
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$name)
            .all()

        return quotas.map { ResourceQuotaResponse(from: $0) }
    }

    func createForOrganization(req: Request) async throws -> ResourceQuotaResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let createRequest = try req.content.decodeValidated(CreateResourceQuotaRequest.self)

        // Verify user has admin access to organization
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Check for duplicate quota name within organization
        try await validateQuotaNameUniqueness(
            name: createRequest.name,
            organizationID: organizationID,
            ouID: nil,
            projectID: nil,
            environment: createRequest.environment,
            excludeQuotaID: nil,
            on: req.db
        )

        // Create quota
        let quota = try await createQuota(
            createRequest: createRequest,
            organizationID: organizationID,
            ouID: nil,
            projectID: nil,
            on: req.db
        )

        return ResourceQuotaResponse(from: quota)
    }

    func indexForOU(req: Request) async throws -> [ResourceQuotaResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Verify the OU actually belongs to that organization. Membership in the
        // path org does not grant visibility into another org's OU — without this
        // check a member of org A could read org B's OU quotas by supplying B's OU id.
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db),
            ou.$organization.id == organizationID
        else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Get all quotas for the OU
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$organizationalUnit.$id == ouID)
            .sort(\.$name)
            .all()

        return quotas.map { ResourceQuotaResponse(from: $0) }
    }

    func createForOU(req: Request) async throws -> ResourceQuotaResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        let createRequest = try req.content.decodeValidated(CreateResourceQuotaRequest.self)

        // Verify user has admin access to organization
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Verify OU exists and belongs to organization
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        // Check for duplicate quota name within OU
        try await validateQuotaNameUniqueness(
            name: createRequest.name,
            organizationID: nil,
            ouID: ouID,
            projectID: nil,
            environment: createRequest.environment,
            excludeQuotaID: nil,
            on: req.db
        )

        // Create quota
        let quota = try await createQuota(
            createRequest: createRequest,
            organizationID: nil,
            ouID: ouID,
            projectID: nil,
            on: req.db
        )

        return ResourceQuotaResponse(from: quota)
    }

    func indexForProject(req: Request) async throws -> [ResourceQuotaResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        let project = try await req.requireProject()
        let projectID = try project.requireID()

        // Verify user has access to project
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        // Get all quotas for the project
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .sort(\.$name)
            .all()

        return quotas.map { ResourceQuotaResponse(from: $0) }
    }

    func createForProject(req: Request) async throws -> ResourceQuotaResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        let project = try await req.requireProject()
        let projectID = try project.requireID()

        let createRequest = try req.content.decodeValidated(CreateResourceQuotaRequest.self)

        // Verify user has admin access to project
        try await OrganizationAccessService.requireProjectQuotaAdmin(project: project, on: req)

        // Validate environment if specified
        if let environment = createRequest.environment {
            if !project.hasEnvironment(environment) {
                throw Abort(.badRequest, reason: "Environment '\(environment)' does not exist in this project")
            }
        }

        // Check for duplicate quota name within project
        try await validateQuotaNameUniqueness(
            name: createRequest.name,
            organizationID: nil,
            ouID: nil,
            projectID: projectID,
            environment: createRequest.environment,
            excludeQuotaID: nil,
            on: req.db
        )

        // Create quota
        let quota = try await createQuota(
            createRequest: createRequest,
            organizationID: nil,
            ouID: nil,
            projectID: projectID,
            on: req.db
        )

        return ResourceQuotaResponse(from: quota)
    }

    // MARK: - Usage Tracking

    func getUsage(req: Request) async throws -> QuotaUsageResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has access to quota
        try await verifyQuotaAccess(quota: quota, on: req)

        // Measure actual usage over the quota's scope, resolved once and reused
        // by both the totals and the per-VM breakdown.
        let scope = try await QuotaUsageAggregator.scope(of: quota, on: req.db)
        let usage = try await QuotaUsageAggregator.measure(scope, on: req.db)
        let breakdown = try await QuotaUsageAggregator.vmBreakdown(in: scope, on: req.db)

        return QuotaUsageService.usageResponse(
            for: quota, actualUsage: usage.asQuotaUsage, breakdown: breakdown)
    }

    // MARK: - Helper Methods

    /// Gate reading a quota — the row itself (`show`) and its freshly measured
    /// usage (`getUsage`).
    ///
    /// One question, `quota:read` on the node the quota hangs on, for every
    /// scope (``QuotaVisibility``). `getUsage` is the sharpest reason it cannot
    /// be the `requireMember` it used to be: it measures the scope live and
    /// returns the per-VM breakdown alongside the totals, so on an
    /// organization-scoped quota a bare member was handed the organization's
    /// vCPU/memory/VM consumption and its VMs by environment and status — the
    /// inventory the hierarchy endpoints filter per row, in scalar form, from
    /// the one route nothing had narrowed.
    private func verifyQuotaAccess(quota: ResourceQuota, on req: Request) async throws {
        guard QuotaVisibility.measuredNode(of: quota) != nil else {
            // A scopeless row measures nothing and belongs to no organization.
            try await requireSystemAdminForScopelessQuota(on: req)
            return
        }
        guard try await QuotaVisibility.canRead(quota, on: req) else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }

    private func verifyQuotaAdminAccess(quota: ResourceQuota, on req: Request) async throws {
        if let orgID = quota.$organization.id {
            try await OrganizationAccessService.requireAdmin(organizationID: orgID, on: req)
        } else if let ouID = quota.$organizationalUnit.id {
            guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
                throw Abort(.notFound, reason: "Folder not found")
            }
            try await OrganizationAccessService.requireAdmin(organizationID: ou.$organization.id, on: req)
        } else if let projectID = quota.$project.id {
            let project = try await req.requireProject(id: projectID)
            try await OrganizationAccessService.requireProjectQuotaAdmin(project: project, on: req)
        } else {
            try await requireSystemAdminForScopelessQuota(on: req)
        }
    }

    /// A quota with no scope is corrupt data, not a shared resource: every
    /// create path sets exactly one scope FK. Without an explicit branch the
    /// `if/else if` chains above fell through and *allowed*, so any
    /// authenticated user could read and mutate such a row (issue #482
    /// pre-cutover audit). Only system admins may touch it — enough to
    /// inspect and delete a corrupt row without widening access.
    private func requireSystemAdminForScopelessQuota(on req: Request) async throws {
        _ = try await req.requireSystemAdmin("Quota has no scope")
    }

    private func validateQuotaNameUniqueness(
        name: String,
        organizationID: UUID?,
        ouID: UUID?,
        projectID: UUID?,
        environment: String?,
        excludeQuotaID: UUID?,
        on db: Database
    ) async throws {
        let query = ResourceQuota.query(on: db)
            .filter(\.$name == name)

        if let excludeID = excludeQuotaID {
            query.filter(\.$id != excludeID)
        }

        if let orgID = organizationID {
            query.filter(\.$organization.$id == orgID)
        } else if let ouID = ouID {
            query.filter(\.$organizationalUnit.$id == ouID)
        } else if let projID = projectID {
            query.filter(\.$project.$id == projID)
        }

        if let env = environment {
            query.filter(\.$environment == env)
        } else {
            query.filter(\.$environment == nil)
        }

        let existingQuota = try await query.first()
        if existingQuota != nil {
            let scope = environment.map { " for environment '\($0)'" } ?? ""
            throw Abort(.conflict, reason: "Quota name already exists in this scope\(scope)")
        }
    }

    private func createQuota(
        createRequest: CreateResourceQuotaRequest,
        organizationID: UUID?,
        ouID: UUID?,
        projectID: UUID?,
        on db: Database
    ) async throws -> ResourceQuota {
        let maxMemoryBytes = createRequest.maxMemoryGB.gbToBytes
        let maxStorageBytes = createRequest.maxStorageGB.gbToBytes

        let quota = ResourceQuota(
            name: createRequest.name,
            organizationID: organizationID,
            organizationalUnitID: ouID,
            projectID: projectID,
            maxVCPUs: createRequest.maxVCPUs,
            maxMemory: maxMemoryBytes,
            maxStorage: maxStorageBytes,
            maxVMs: createRequest.maxVMs,
            maxSandboxes: createRequest.maxSandboxes,
            maxNetworks: createRequest.maxNetworks ?? 10,
            environment: createRequest.environment,
            isEnabled: createRequest.isEnabled ?? true
        )

        try quota.validate()

        // Backfill the reservation counters from the workloads the new quota
        // already governs, so the stored figures are honest from the moment the
        // row exists instead of reading zero until the next create or delete in
        // this scope resyncs them (issue #742). The scope is resolved from the
        // quota's own scope FKs and environment, so this works before the insert.
        //
        // Deliberately not a `validate()`: a quota introduced *below* an existing
        // tenant's usage is legitimate — that's how enforcement starts on a live
        // tenant, and admission then blocks any further growth.
        try await QuotaEnforcementService.resyncReservations(quota, on: db)
        try await quota.save(on: db)

        return quota
    }

}
