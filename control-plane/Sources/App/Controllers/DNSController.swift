import ControlPlanePostgres
import StratoShared
import Vapor

/// DNS zones, their attachment to logical networks, and user-authored records
/// (issue #770, roadmap #769).
///
/// Zones are ordinary project resources with network-style authorization: the
/// evaluator resolves the zone's project and the bindings there decide.
/// Records hang off their zone in the resource tree, so a binding on a zone
/// carries its records.
///
/// Phase 1 was the record *model* — the one hard-to-reverse decision in the
/// DNS work — and every later phase is a driver reading `DNSZoneAssembler`'s
/// output. The first of those drivers landed in STR-39: a zone attached to a
/// network is realized into the OVN `DNS` table by that network's topology
/// authority, so the writes below ring the fleet doorbell.
///
/// Fleet-wide rather than per-agent, on `SecurityGroupController`'s terms: a
/// zone's blast radius is every network it is attached to, which may span
/// sites, so the affected agents aren't known at the mutation site. Purely a
/// latency optimization either way — a lost doorbell is caught by the agent's
/// own periodic re-fetch. Routes that cannot change anything realized (a zone
/// created or deleted with no attachments — an unattached zone is never sent
/// to any agent) deliberately don't ring.
struct DNSController: RouteCollection {
    let iam: IAMPersistence
    let projects: ProjectsPersistence
    let database: PostgresStoreContext

    init(iam: IAMPersistence, projects: ProjectsPersistence, database: PostgresStoreContext) {
        self.iam = iam
        self.projects = projects
        self.database = database
    }
    func boot(routes: RoutesBuilder) throws {
        let zones = routes.grouped("api", "dns-zones").grouped(User.guardMiddleware())
        zones.get(use: listZones)
        zones.post(use: createZone)
        zones.get(":zoneId", use: getZone)
        zones.put(":zoneId", use: updateZone)
        zones.delete(":zoneId", use: deleteZone)

        zones.get(":zoneId", "recordset", use: getRecordSet)

        zones.get(":zoneId", "records", use: listRecords)
        zones.post(":zoneId", "records", use: createRecord)
        zones.get(":zoneId", "records", ":recordId", use: getRecord)
        zones.put(":zoneId", "records", ":recordId", use: updateRecord)
        zones.delete(":zoneId", "records", ":recordId", use: deleteRecord)

        zones.post(":zoneId", "networks", use: attachNetwork)
        zones.delete(":zoneId", "networks", ":networkId", use: detachNetwork)
    }

    // MARK: - Zone CRUD

    /// GET /api/dns-zones
    /// Query params: project_id (optional), limit/offset (optional).
    @Sendable
    func listZones(req: Request) async throws -> PagedResponse<DNSZoneResponse> {
        let paging = try ListPaging.decode(from: req)
        return paging.page(try await visibleZones(req: req))
    }

    /// Every zone the caller may read, by name, ready for slicing.
    func visibleZones(req: Request) async throws -> [DNSZoneResponse] {
        _ = try req.auth.require(User.self)
        let requestedProjectID = req.query[String.self, at: "project_id"].flatMap(UUID.init(uuidString:))

        var projectIDs: [UUID]?

        // Project scoping runs for every caller, admins included: their
        // fleet-wide view comes from the tier-1 `platform-system-admin` policy
        // answering each `view_project` check, so it lands in the decision log
        // and a tier-2 guardrail can narrow it.
        var visibility: ProjectVisibility?
        if let requestedProjectID {
            let hasAccess = try await req.can(
                "project:read", on: IAMNode(type: .project, id: requestedProjectID))
            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }
            projectIDs = [requestedProjectID]
        } else {
            let resolved = try await ProjectVisibility.resolve(on: req, using: iam, projects: projects)
            guard !resolved.reachesNoProject else { return [] }
            projectIDs = resolved.candidateProjectIDs
            visibility = resolved
        }

        var zones = try await LegacyDNSZoneStore.zones(projectIDs: projectIDs, on: database)
        if let visibility {
            zones = try await visibility.readableRows(zones, projectID: \.projectID, on: req)
        }
        return try await Self.responses(for: zones, on: database)
    }

    /// POST /api/dns-zones
    @Sendable
    func createZone(req: Request) async throws -> DNSZoneResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decodeValidated(CreateDNSZoneRequest.self)

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId,
            action: "dns:create", resourceKind: "DNS zones", on: database)
        let projectID = try project.requireID()

        let name = try DNSName.normalizedZoneName(request.name)
        let creatorID = try user.requireID()
        let zone: DNSZoneSnapshot
        do {
            zone = try await database.transaction { db in
                let zone = try await LegacyDNSZoneStore.insert(
                    name: name,
                    description: request.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .nilWhenEmpty,
                    projectID: projectID,
                    createdByID: creatorID,
                    on: db)
                // Creator binding (issue #477), mirroring network create.
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .dnsZone,
                    nodeID: zone.id,
                    createdBy: creatorID,
                    on: db
                )
                return zone
            }
        } catch let error as any PostgresConstraintError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A DNS zone named '\(name)' already exists in this project")
        }

        req.logger.info(
            "DNS zone created",
            metadata: [
                "dnsZoneId": .string(zone.id.uuidString),
                "name": .string(name),
                "projectId": .string(projectID.uuidString),
            ])
        return DNSZoneResponse(from: zone, networks: [], recordCount: 0)
    }

    /// GET /api/dns-zones/:zoneId
    @Sendable
    func getZone(req: Request) async throws -> DNSZoneResponse {
        let zone = try await fetchZone(req: req, action: "dns:read")
        return try await Self.responses(for: [zone], on: database)[0]
    }

    /// PUT /api/dns-zones/:zoneId
    @Sendable
    func updateZone(req: Request) async throws -> DNSZoneResponse {
        let zone = try await fetchZone(req: req, action: "dns:update")
        let request = try req.content.decodeValidated(UpdateDNSZoneRequest.self)
        let originalName = zone.name
        let nextName: String
        if let requestedName = request.name {
            nextName = try DNSName.normalizedZoneName(requestedName)
            // Renaming moves every derived record in the zone, and every
            // authored one with it. That is the operator's call to make — the
            // zone name is the suffix, not an identity anything resolves
            // through — but it is worth being a deliberate PUT rather than a
            // side effect.
        } else {
            nextName = zone.name
        }
        let nextDescription = request.description.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
        } ?? zone.zoneDescription

        let updated: DNSZoneSnapshot
        do {
            updated = try await database.transaction { db in
                guard let updated = try await LegacyDNSZoneStore.update(
                    id: zone.id, name: nextName, description: nextDescription, on: db)
                else { throw Abort(.notFound, reason: "DNS zone no longer exists") }

                // A search domain that still spells this primary zone is
                // following it, so a rename has to move both columns together.
                // Otherwise the stale spelling can no longer be distinguished
                // from one the operator chose and will never follow again.
                guard updated.name != originalName else { return updated }
                let primaryNetworks = try await LegacyLogicalNetworkStore.networks(
                    primaryDNSZoneID: zone.id, on: db)
                for network in primaryNetworks {
                    let next = DNSZoneService.searchDomainFollowingPrimaryZone(
                        current: network.domainName,
                        previousZoneName: originalName,
                        nextZoneName: updated.name)
                    guard next != network.domainName else { continue }
                    try await network.replacing(domainName: .some(next)).save(on: db)
                }
                return updated
            }
        } catch let error as any PostgresConstraintError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A DNS zone named '\(nextName)' already exists in this project")
        }
        // A rename moves every name in the zone; a description edit realizes
        // nothing, so only the former is worth a fleet-wide re-assembly.
        if updated.name != originalName {
            await req.application.agentService.syncDesiredStateToFleet()
        }
        return try await Self.responses(for: [updated], on: database)[0]
    }

    /// DELETE /api/dns-zones/:zoneId
    @Sendable
    func deleteZone(req: Request) async throws -> HTTPStatus {
        let zone = try await fetchZone(req: req, action: "dns:delete")
        let zoneID = zone.id

        // Attachments are the zone's blast radius: deleting one that networks
        // still resolve would silently stop answering for every VM on them.
        // Detach first, so losing resolution is always an explicit act.
        let attachments = try await DNSZoneNetworkStore.count(zoneID: zoneID, on: database)
        guard attachments == 0 else {
            throw Abort(
                .conflict,
                reason: "DNS zone is attached to \(attachments) network(s); detach them first")
        }

        try await database.transaction { db in
            // Records cascade with the zone; bindings have no FK to the
            // resources they protect, so the zone's node bindings *and* its
            // records' are dropped here (STR-137) — before the delete, which
            // takes the record rows the sweep reads with it.
            try await ResourceBindingCleanup.revokeBindings(forDeletedDNSZone: zoneID, on: db)
            _ = try await LegacyDNSZoneStore.delete(id: zoneID, on: db)
        }

        req.logger.info(
            "DNS zone deleted",
            metadata: ["dnsZoneId": .string(zoneID.uuidString), "name": .string(zone.name)])
        return .noContent
    }

    // MARK: - Assembled record set

    /// GET /api/dns-zones/:zoneId/recordset — the zone's effective contents,
    /// derived ∪ authored, exactly as a realization driver will see them.
    @Sendable
    func getRecordSet(req: Request) async throws -> AssembledDNSZone {
        let zone = try await fetchZone(req: req, action: "dns:read")
        return try await DNSZoneAssembler.assemble(zone: zone, on: database)
    }

    // MARK: - Records

    /// GET /api/dns-zones/:zoneId/records — the authored rows only.
    @Sendable
    func listRecords(req: Request) async throws -> PagedResponse<DNSRecordResponse> {
        let paging = try ListPaging.decode(from: req)
        let zone = try await fetchZone(req: req, action: "dns:read")
        let zoneID = zone.id
        let records = try await LegacyDNSRecordStore.records(zoneID: zoneID, on: database)
        return paging.page(records.map { DNSRecordResponse(from: $0, zoneName: zone.name) })
    }

    /// POST /api/dns-zones/:zoneId/records
    @Sendable
    func createRecord(req: Request) async throws -> DNSRecordResponse {
        let user = try req.auth.require(User.self)
        let zone = try await fetchZone(req: req, action: "dns:create")
        let zoneID = zone.id
        let request = try req.content.decodeValidated(CreateDNSRecordRequest.self)

        let name = try DNSName.normalizedRecordName(request.name ?? DNSName.apex)
        let value = try DNSZoneService.validatedValue(request.value, type: request.type)
        let ttl = try Self.validatedTTL(request.ttl)

        let view = request.view ?? .both
        let record: DNSRecordSnapshot
        do {
            // Every check here is read-then-write, and none of them is backed
            // by an index: the unique index is `(zone, name, type, value)`,
            // which cannot see the CNAME-exclusivity rule, the RRset's shared
            // TTL, or the per-zone cap. Two concurrent creates would otherwise
            // land a CNAME and an A at one owner name and leave the zone
            // permanently invalid, with no idempotent recovery to lean on (the
            // way `attachNetwork` has one). Serializing a zone's record writes
            // on an advisory lock costs nothing — record writes are rare — and
            // makes the checks mean what they say.
            record = try await database.transaction { db in
                try await DNSZoneService.lockZone(zoneID, on: db)

                let count = try await LegacyDNSRecordStore.count(zoneID: zoneID, on: db)
                guard count < DNSZone.maxRecordsPerZone else {
                    throw Abort(
                        .forbidden,
                        reason: "Record limit reached: \(DNSZone.maxRecordsPerZone) records per zone")
                }
                try await DNSZoneService.assertNoConflict(
                    zone: zone, name: name, type: request.type, on: db)
                try await DNSZoneService.assertRRsetSettingsAgree(
                    zone: zone, name: name, type: request.type, ttl: ttl, view: view, on: db)

                return try await LegacyDNSRecordStore.insert(
                    zoneID: zoneID, name: name, type: request.type, value: value,
                    ttl: ttl, view: view, createdByID: user.requireID(), on: db)
            }
        } catch let error as any PostgresConstraintError where error.isConstraintFailure {
            throw Abort(
                .conflict,
                reason: "A \(request.type.rawValue) record with that value already exists at "
                    + "'\(DNSName.qualified(name: name, inZone: zone.name))'")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return DNSRecordResponse(from: record, zoneName: zone.name)
    }

    /// GET /api/dns-zones/:zoneId/records/:recordId
    @Sendable
    func getRecord(req: Request) async throws -> DNSRecordResponse {
        let (zone, record) = try await fetchRecord(req: req, action: "dns:read")
        return DNSRecordResponse(from: record, zoneName: zone.name)
    }

    /// PUT /api/dns-zones/:zoneId/records/:recordId — value, TTL, and view.
    /// The owner name and type are the record's identity; change those by
    /// deleting and recreating, so a rename can be checked for conflicts as
    /// the create it effectively is.
    ///
    /// TTL and view belong to the whole RRset (RFC 2181 §5.2), so changing
    /// either applies to every record sharing this one's name and type. The
    /// alternative — rejecting the edit — would leave a multi-value RRset's
    /// TTL uneditable without deleting members first.
    @Sendable
    func updateRecord(req: Request) async throws -> DNSRecordResponse {
        let (zone, record) = try await fetchRecord(req: req, action: "dns:update")
        let zoneID = zone.id
        let request = try req.content.decodeValidated(UpdateDNSRecordRequest.self)

        let value = try request.value.map {
            try DNSZoneService.validatedValue($0, type: record.type)
        } ?? record.value
        let ttl = try request.ttl.map(Self.validatedTTL) ?? record.ttl
        let view = request.view ?? record.view
        let ttlOrViewChanged = request.ttl != nil || request.view != nil

        let updated: DNSRecordSnapshot
        do {
            updated = try await database.transaction { db in
                try await DNSZoneService.lockZone(zoneID, on: db)
                guard let saved = try await LegacyDNSRecordStore.update(
                    id: record.id, value: value, ttl: ttl, view: view, on: db)
                else { throw Abort(.notFound, reason: "DNS record no longer exists") }
                if ttlOrViewChanged {
                    try await DNSZoneService.applyRRsetSettings(
                        zoneID: zoneID, name: record.name, type: record.type,
                        ttl: ttl, view: view, on: db)
                }
                return saved
            }
        } catch let error as any PostgresConstraintError where error.isConstraintFailure {
            throw Abort(
                .conflict,
                reason: "A \(record.type.rawValue) record with that value already exists at "
                    + "'\(DNSName.qualified(name: record.name, inZone: zone.name))'")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return DNSRecordResponse(from: updated, zoneName: zone.name)
    }

    /// DELETE /api/dns-zones/:zoneId/records/:recordId
    @Sendable
    func deleteRecord(req: Request) async throws -> HTTPStatus {
        let (_, record) = try await fetchRecord(req: req, action: "dns:delete")
        _ = try await LegacyDNSRecordStore.delete(id: record.id, on: database)
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Network attachment

    /// POST /api/dns-zones/:zoneId/networks — "VMs on this network can
    /// resolve this zone", optionally also making it the network's primary.
    @Sendable
    func attachNetwork(req: Request) async throws -> DNSZoneResponse {
        let zone = try await fetchZone(req: req, action: "dns:attach")
        let zoneID = zone.id
        let request = try req.content.decode(AttachDNSZoneRequest.self)

        let network = try await authorizedNetwork(req: req, id: request.networkId, zone: zone)
        let networkID = try network.requireID()

        // Checked before anything is written, so a request that asks for
        // `primary` and cannot have it changes nothing at all rather than
        // leaving a half-applied attachment behind.
        let promoting = request.primary == true && network.primaryDNSZoneID != zoneID
        var promotedDomainName: String?
        if promoting {
            try await DNSZoneService.assertPrimaryZoneAssignable(
                zone: zone, networkID: networkID, on: database)
            let outgoing = try await DNSZoneService.primaryZoneName(of: network, on: database)
            // Zone names are stored through `normalizedZoneName`, whose rules
            // are stricter than a search domain's. Derive this before writing
            // the attachment so promotion still has no later validation path
            // that can leave a half-applied row behind.
            promotedDomainName = DNSZoneService.searchDomainFollowingPrimaryZone(
                current: network.domainName,
                previousZoneName: outgoing,
                nextZoneName: zone.name)
        }

        // Attachment is one idempotent INSERT ... ON CONFLICT statement, so a
        // concurrent attach neither leaks a uniqueness error nor poisons the
        // primary-zone update that follows. Promotion is validated before this
        // write so a rejected request still cannot leave an attachment behind.
        _ = try await DNSZoneNetworkStore.attach(
            zoneID: zoneID, networkID: networkID, on: database)
        if promoting {
            // The search domain follows the zone unless an operator has set one
            // of their own (STR-201). Without it a guest resolves
            // `alpha.<zone>` and not `alpha`, which is the half of "attaching a
            // primary zone points guests at it" that the resolver cannot supply
            // — a search list is guest-side config, not something a resolver
            // answers with.
            try await network.replacing(
                domainName: .some(promotedDomainName),
                primaryDNSZoneID: .some(zoneID)
            ).save(on: database)
        }

        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "DNS zone attached to network",
            metadata: [
                "dnsZoneId": .string(zoneID.uuidString),
                "networkId": .string(networkID.uuidString),
                "primary": .string(String(request.primary == true)),
            ])
        return try await Self.responses(for: [zone], on: database)[0]
    }

    /// DELETE /api/dns-zones/:zoneId/networks/:networkId
    @Sendable
    func detachNetwork(req: Request) async throws -> HTTPStatus {
        let zone = try await fetchZone(req: req, action: "dns:detach")
        let zoneID = zone.id
        guard let networkID = req.parameters.get("networkId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid network ID")
        }
        let network = try await authorizedNetwork(req: req, id: networkID, zone: zone)

        // Detaching a network's primary zone would strand its VMs' derived
        // records with no zone to live in, so clearing the primary is a
        // separate, explicit edit on the network.
        guard network.primaryDNSZoneID != zoneID else {
            throw Abort(
                .conflict,
                reason: "This zone is the network's primary DNS zone; clear the network's primary zone "
                    + "before detaching it")
        }

        guard try await DNSZoneNetworkStore.detach(
            zoneID: zoneID, networkID: networkID, on: database)
        else {
            return .noContent
        }
        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "DNS zone detached from network",
            metadata: [
                "dnsZoneId": .string(zoneID.uuidString),
                "networkId": .string(networkID.uuidString),
            ])
        return .noContent
    }

    // MARK: - Helpers

    /// The zone's own canonical action check.
    private func fetchZone(req: Request, action: String) async throws -> DNSZoneSnapshot {
        guard let zoneID = req.parameters.get("zoneId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid DNS zone ID")
        }
        guard let zone = try await LegacyDNSZoneStore.find(id: zoneID, on: database) else {
            throw Abort(.notFound, reason: "DNS zone not found")
        }
        let allowed = try await req.can(action, on: IAMNode(type: .dnsZone, id: zoneID))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this DNS zone")
        }
        return zone
    }

    /// A record and its zone, authorized on the *record* — a binding on the
    /// zone reaches it through the tree, and a binding on the record alone
    /// reaches only that row.
    private func fetchRecord(
        req: Request, action: String
    ) async throws -> (DNSZoneSnapshot, DNSRecordSnapshot) {
        guard let zoneID = req.parameters.get("zoneId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid DNS zone ID")
        }
        guard let recordID = req.parameters.get("recordId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid DNS record ID")
        }
        guard let zone = try await LegacyDNSZoneStore.find(id: zoneID, on: database) else {
            throw Abort(.notFound, reason: "DNS zone not found")
        }
        guard let record = try await LegacyDNSRecordStore.record(
            id: recordID, zoneID: zoneID, on: database) else {
            throw Abort(.notFound, reason: "Record not found in this DNS zone")
        }
        let allowed = try await req.can(action, on: IAMNode(type: .dnsRecord, id: recordID))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this DNS record")
        }
        return (zone, record)
    }

    /// The attachment target: a network in the zone's project that the caller
    /// may also modify. Attaching changes what the network's VMs resolve, so
    /// owning the zone alone is not enough (the volume/floating-IP rule).
    private func authorizedNetwork(
        req: Request, id networkID: UUID, zone: DNSZoneSnapshot
    ) async throws -> LogicalNetwork {
        guard let network = try await LogicalNetwork.find(networkID, on: database) else {
            throw Abort(.badRequest, reason: "Network \(networkID) does not exist")
        }
        let allowed = try await req.can("network:update", on: IAMNode(type: .network, id: networkID))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to modify this network")
        }
        // After the network check, never before: a containment refusal handed
        // to a caller who can't touch the network would tell them it exists in
        // another project (issue #777).
        try ProjectContainment.require(
            "Network", in: network.projectID,
            sameProjectAs: "the DNS zone", in: zone.projectID)
        return network
    }

    static func validatedTTL(_ ttl: Int?) throws -> Int {
        guard let ttl else { return DNSRecord.defaultTTL }
        guard DNSRecord.ttlRange.contains(ttl) else {
            throw Abort(
                .badRequest,
                reason: "TTL must be between \(DNSRecord.ttlRange.lowerBound) and "
                    + "\(DNSRecord.ttlRange.upperBound) seconds")
        }
        return ttl
    }

    /// Build responses for a page of zones with two batched queries rather
    /// than a pair per zone.
    private static func responses(
        for zones: [DNSZoneSnapshot], on db: PostgresStoreContext
    ) async throws -> [DNSZoneResponse] {
        let zoneIDs = zones.map(\.id)
        guard !zoneIDs.isEmpty else { return [] }

        let attachments = try await DNSZoneNetworkStore.attachments(zoneIDs: zoneIDs, on: db)
        let networkIDs = Array(Set(attachments.map(\.logicalNetworkID)))
        var networks: [UUID: LogicalNetwork] = [:]
        if !networkIDs.isEmpty {
            for network in try await LegacyLogicalNetworkStore.networks(ids: networkIDs, on: db) {
                if let id = network.id { networks[id] = network }
            }
        }
        // The warning is about the *network*, so it counts every zone attached
        // to it — not just the ones on this page — and is computed once per
        // network rather than once per attachment (STR-201).
        let zoneCounts = try await DNSZoneNetworkStore.counts(networkIDs: networkIDs, on: db)
        let capability = try await ResolverCapability.index(on: db)
        var warnings: [UUID: String] = [:]
        for (networkID, network) in networks {
            warnings[networkID] = ResolverCapability.zoneResolutionWarning(
                network: network, attachedZoneCount: zoneCounts[networkID] ?? 0,
                incapableAgentNames: capability.incapableAgentNames(forSite: network.siteID))
        }

        var attachedByZone: [UUID: [DNSZoneNetworkResponse]] = [:]
        for attachment in attachments {
            guard let network = networks[attachment.logicalNetworkID], let networkID = network.id else {
                continue
            }
            attachedByZone[attachment.zoneID, default: []].append(
                DNSZoneNetworkResponse(
                    networkId: networkID,
                    networkName: network.name,
                    isPrimary: network.primaryDNSZoneID == attachment.zoneID,
                    zoneResolutionWarning: warnings[networkID]))
        }

        let recordCounts = try await LegacyDNSRecordStore.counts(zoneIDs: zoneIDs, on: db)

        return zones.map { zone in
            let id = zone.id
            return DNSZoneResponse(
                from: zone,
                networks: (attachedByZone[id] ?? []).sorted { $0.networkName < $1.networkName },
                recordCount: recordCounts[id] ?? 0)
        }
    }
}

extension String {
    fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
