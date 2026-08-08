import Fluent
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

        var query = DNSZone.query(on: req.db).sort(\.$name).sort(\.$id)

        // Project scoping runs for every caller, admins included: their
        // fleet-wide view comes from the tier-1 `platform-system-admin` policy
        // answering each `view_project` check, so it lands in the decision log
        // and a tier-2 guardrail can narrow it.
        var visibility: ProjectVisibility?
        if let requestedProjectID {
            let hasAccess = try await req.can("view_project", on: "project", id: requestedProjectID.uuidString)
            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }
            query = query.filter(\.$project.$id == requestedProjectID)
        } else {
            let resolved = try await ProjectVisibility.resolve(on: req)
            guard !resolved.reachesNoProject else { return [] }
            if let candidates = resolved.candidateProjectIDs {
                query = query.filter(\.$project.$id ~~ candidates)
            }
            visibility = resolved
        }

        var zones = try await query.all()
        if let visibility {
            zones = try await visibility.readableRows(zones, projectID: { $0.$project.id }, on: req)
        }
        return try await Self.responses(for: zones, on: req.db)
    }

    /// POST /api/dns-zones
    @Sendable
    func createZone(req: Request) async throws -> DNSZoneResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decode(CreateDNSZoneRequest.self)

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId,
            action: "create_dns_zone", resourceKind: "DNS zones")
        let projectID = try project.requireID()

        let name = try DNSName.normalizedZoneName(request.name)
        let creatorID = try user.requireID()
        let zone = DNSZone(
            name: name,
            description: request.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty,
            projectID: projectID,
            createdByID: creatorID
        )
        do {
            try await req.db.transaction { db in
                try await zone.save(on: db)
                // Creator binding (issue #477), mirroring network create.
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .dnsZone,
                    nodeID: try zone.requireID(),
                    createdBy: creatorID,
                    on: db
                )
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A DNS zone named '\(name)' already exists in this project")
        }

        req.logger.info(
            "DNS zone created",
            metadata: [
                "dnsZoneId": .string(zone.id!.uuidString),
                "name": .string(name),
                "projectId": .string(projectID.uuidString),
            ])
        return try DNSZoneResponse(from: zone, networks: [], recordCount: 0)
    }

    /// GET /api/dns-zones/:zoneId
    @Sendable
    func getZone(req: Request) async throws -> DNSZoneResponse {
        let zone = try await fetchZone(req: req, permission: "read")
        return try await Self.responses(for: [zone], on: req.db)[0]
    }

    /// PUT /api/dns-zones/:zoneId
    @Sendable
    func updateZone(req: Request) async throws -> DNSZoneResponse {
        let zone = try await fetchZone(req: req, permission: "update")
        let request = try req.content.decode(UpdateDNSZoneRequest.self)
        let originalName = zone.name

        if let requestedName = request.name {
            let name = try DNSName.normalizedZoneName(requestedName)
            // Renaming moves every derived record in the zone, and every
            // authored one with it. That is the operator's call to make — the
            // zone name is the suffix, not an identity anything resolves
            // through — but it is worth being a deliberate PUT rather than a
            // side effect.
            zone.name = name
        }
        if let description = request.description {
            zone.zoneDescription = description.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
        }

        do {
            try await zone.save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A DNS zone named '\(zone.name)' already exists in this project")
        }
        // A rename moves every name in the zone; a description edit realizes
        // nothing, so only the former is worth a fleet-wide re-assembly.
        if zone.name != originalName {
            await req.application.agentService.syncDesiredStateToFleet()
        }
        return try await Self.responses(for: [zone], on: req.db)[0]
    }

    /// DELETE /api/dns-zones/:zoneId
    @Sendable
    func deleteZone(req: Request) async throws -> HTTPStatus {
        let zone = try await fetchZone(req: req, permission: "delete")
        let zoneID = try zone.requireID()

        // Attachments are the zone's blast radius: deleting one that networks
        // still resolve would silently stop answering for every VM on them.
        // Detach first, so losing resolution is always an explicit act.
        let attachments = try await DNSZoneNetwork.query(on: req.db)
            .filter(\.$zone.$id == zoneID)
            .count()
        guard attachments == 0 else {
            throw Abort(
                .conflict,
                reason: "DNS zone is attached to \(attachments) network(s); detach them first")
        }

        try await req.db.transaction { db in
            // Records cascade with the zone; bindings have no FK to the
            // resources they protect, so the zone's node bindings *and* its
            // records' are dropped here (STR-137) — before the delete, which
            // takes the record rows the sweep reads with it.
            try await ResourceBindingCleanup.revokeBindings(forDeletedDNSZone: zoneID, on: db)
            try await zone.delete(on: db)
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
        let zone = try await fetchZone(req: req, permission: "read")
        return try await DNSZoneAssembler.assemble(zone: zone, on: req.db)
    }

    // MARK: - Records

    /// GET /api/dns-zones/:zoneId/records — the authored rows only.
    @Sendable
    func listRecords(req: Request) async throws -> PagedResponse<DNSRecordResponse> {
        let paging = try ListPaging.decode(from: req)
        let zone = try await fetchZone(req: req, permission: "read")
        let zoneID = try zone.requireID()
        let records = try await DNSRecord.query(on: req.db)
            .filter(\.$zone.$id == zoneID)
            .sort(\.$name)
            .sort(\.$id)
            .all()
        return paging.page(try records.map { try DNSRecordResponse(from: $0, zoneName: zone.name) })
    }

    /// POST /api/dns-zones/:zoneId/records
    @Sendable
    func createRecord(req: Request) async throws -> DNSRecordResponse {
        let user = try req.auth.require(User.self)
        let zone = try await fetchZone(req: req, permission: "create")
        let zoneID = try zone.requireID()
        let request = try req.content.decode(CreateDNSRecordRequest.self)

        let name = try DNSName.normalizedRecordName(request.name ?? DNSName.apex)
        let value = try DNSZoneService.validatedValue(request.value, type: request.type)
        let ttl = try Self.validatedTTL(request.ttl)

        let record = DNSRecord(
            zoneID: zoneID,
            name: name,
            type: request.type,
            value: value,
            ttl: ttl,
            view: request.view ?? .both,
            createdByID: try user.requireID()
        )
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
            try await req.db.transaction { db in
                try await DNSZoneService.lockZone(zoneID, on: db)

                let count = try await DNSRecord.query(on: db).filter(\.$zone.$id == zoneID).count()
                guard count < DNSZone.maxRecordsPerZone else {
                    throw Abort(
                        .forbidden,
                        reason: "Record limit reached: \(DNSZone.maxRecordsPerZone) records per zone")
                }
                try await DNSZoneService.assertNoConflict(
                    zone: zone, name: name, type: request.type, on: db)
                try await DNSZoneService.assertRRsetSettingsAgree(
                    zone: zone, name: name, type: request.type, ttl: record.ttl, view: record.view, on: db)

                try await record.save(on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(
                .conflict,
                reason: "A \(request.type.rawValue) record with that value already exists at "
                    + "'\(DNSName.qualified(name: name, inZone: zone.name))'")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return try DNSRecordResponse(from: record, zoneName: zone.name)
    }

    /// GET /api/dns-zones/:zoneId/records/:recordId
    @Sendable
    func getRecord(req: Request) async throws -> DNSRecordResponse {
        let (zone, record) = try await fetchRecord(req: req, permission: "read")
        return try DNSRecordResponse(from: record, zoneName: zone.name)
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
        let (zone, record) = try await fetchRecord(req: req, permission: "update")
        let zoneID = try zone.requireID()
        let request = try req.content.decode(UpdateDNSRecordRequest.self)

        if let value = request.value {
            record.value = try DNSZoneService.validatedValue(value, type: record.type)
        }
        if let ttl = request.ttl {
            record.ttl = try Self.validatedTTL(ttl)
        }
        if let view = request.view {
            record.view = view
        }
        let ttlOrViewChanged = request.ttl != nil || request.view != nil

        do {
            try await req.db.transaction { db in
                try await DNSZoneService.lockZone(zoneID, on: db)
                try await record.save(on: db)
                if ttlOrViewChanged {
                    try await DNSZoneService.applyRRsetSettings(
                        zoneID: zoneID, name: record.name, type: record.type,
                        ttl: record.ttl, view: record.view, on: db)
                }
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(
                .conflict,
                reason: "A \(record.type.rawValue) record with that value already exists at "
                    + "'\(DNSName.qualified(name: record.name, inZone: zone.name))'")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return try DNSRecordResponse(from: record, zoneName: zone.name)
    }

    /// DELETE /api/dns-zones/:zoneId/records/:recordId
    @Sendable
    func deleteRecord(req: Request) async throws -> HTTPStatus {
        let (_, record) = try await fetchRecord(req: req, permission: "delete")
        try await record.delete(on: req.db)
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Network attachment

    /// POST /api/dns-zones/:zoneId/networks — "VMs on this network can
    /// resolve this zone", optionally also making it the network's primary.
    @Sendable
    func attachNetwork(req: Request) async throws -> DNSZoneResponse {
        let zone = try await fetchZone(req: req, permission: "attach")
        let zoneID = try zone.requireID()
        let request = try req.content.decode(AttachDNSZoneRequest.self)

        let network = try await Self.authorizedNetwork(req: req, id: request.networkId, zone: zone)
        let networkID = try network.requireID()

        // Checked before anything is written, so a request that asks for
        // `primary` and cannot have it changes nothing at all rather than
        // leaving a half-applied attachment behind.
        let promoting = request.primary == true && network.$primaryDNSZone.id != zoneID
        if promoting {
            try await DNSZoneService.assertPrimaryZoneAssignable(
                zone: zone, networkID: networkID, on: req.db)
        }

        // Deliberately not one transaction: the duplicate-attach catch below is
        // the idempotency path, and inside a Postgres transaction a constraint
        // violation aborts the whole thing — the recovery would poison the
        // `network.save` that follows it. Pre-validating the promotion is what
        // makes the two writes safe to do separately.
        let alreadyAttached = try await DNSZoneNetwork.query(on: req.db)
            .filter(\.$zone.$id == zoneID)
            .filter(\.$logicalNetwork.$id == networkID)
            .count()
        if alreadyAttached == 0 {
            do {
                try await DNSZoneNetwork(zoneID: zoneID, logicalNetworkID: networkID).save(on: req.db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                // Lost the race with a concurrent attach; the unique pair index
                // makes that a no-op rather than an error.
            }
        }
        if promoting {
            network.$primaryDNSZone.id = zoneID
            try await network.save(on: req.db)
        }

        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "DNS zone attached to network",
            metadata: [
                "dnsZoneId": .string(zoneID.uuidString),
                "networkId": .string(networkID.uuidString),
                "primary": .string(String(request.primary == true)),
            ])
        return try await Self.responses(for: [zone], on: req.db)[0]
    }

    /// DELETE /api/dns-zones/:zoneId/networks/:networkId
    @Sendable
    func detachNetwork(req: Request) async throws -> HTTPStatus {
        let zone = try await fetchZone(req: req, permission: "detach")
        let zoneID = try zone.requireID()
        guard let networkID = req.parameters.get("networkId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid network ID")
        }
        let network = try await Self.authorizedNetwork(req: req, id: networkID, zone: zone)

        // Detaching a network's primary zone would strand its VMs' derived
        // records with no zone to live in, so clearing the primary is a
        // separate, explicit edit on the network.
        guard network.$primaryDNSZone.id != zoneID else {
            throw Abort(
                .conflict,
                reason: "This zone is the network's primary DNS zone; clear the network's primary zone "
                    + "before detaching it")
        }

        guard
            let attachment = try await DNSZoneNetwork.query(on: req.db)
                .filter(\.$zone.$id == zoneID)
                .filter(\.$logicalNetwork.$id == networkID)
                .first()
        else {
            return .noContent
        }
        try await attachment.delete(on: req.db)
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

    /// The zone's own permission check. `permission` speaks the legacy
    /// vocabulary the translator maps onto `dns:*`.
    private func fetchZone(req: Request, permission: String) async throws -> DNSZone {
        guard let zoneID = req.parameters.get("zoneId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid DNS zone ID")
        }
        guard let zone = try await DNSZone.find(zoneID, on: req.db) else {
            throw Abort(.notFound, reason: "DNS zone not found")
        }
        let allowed = try await req.can(permission, on: "dns_zone", id: zoneID.uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this DNS zone")
        }
        return zone
    }

    /// A record and its zone, authorized on the *record* — a binding on the
    /// zone reaches it through the tree, and a binding on the record alone
    /// reaches only that row.
    private func fetchRecord(req: Request, permission: String) async throws -> (DNSZone, DNSRecord) {
        guard let zoneID = req.parameters.get("zoneId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid DNS zone ID")
        }
        guard let recordID = req.parameters.get("recordId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid DNS record ID")
        }
        guard let zone = try await DNSZone.find(zoneID, on: req.db) else {
            throw Abort(.notFound, reason: "DNS zone not found")
        }
        guard
            let record = try await DNSRecord.query(on: req.db)
                .filter(\.$id == recordID)
                .filter(\.$zone.$id == zoneID)
                .first()
        else {
            throw Abort(.notFound, reason: "Record not found in this DNS zone")
        }
        let allowed = try await req.can(permission, on: "dns_record", id: recordID.uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this DNS record")
        }
        return (zone, record)
    }

    /// The attachment target: a network in the zone's project that the caller
    /// may also modify. Attaching changes what the network's VMs resolve, so
    /// owning the zone alone is not enough (the volume/floating-IP rule).
    private static func authorizedNetwork(
        req: Request, id networkID: UUID, zone: DNSZone
    ) async throws -> LogicalNetwork {
        guard let network = try await LogicalNetwork.find(networkID, on: req.db) else {
            throw Abort(.badRequest, reason: "Network \(networkID) does not exist")
        }
        let allowed = try await req.can("update", on: "network", id: networkID.uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to modify this network")
        }
        // After the network check, never before: a containment refusal handed
        // to a caller who can't touch the network would tell them it exists in
        // another project (issue #777).
        try ProjectContainment.require(
            "Network", in: network.$project.id,
            sameProjectAs: "the DNS zone", in: zone.$project.id)
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
    private static func responses(for zones: [DNSZone], on db: any Database) async throws -> [DNSZoneResponse] {
        let zoneIDs = try zones.map { try $0.requireID() }
        guard !zoneIDs.isEmpty else { return [] }

        let attachments = try await DNSZoneNetwork.query(on: db)
            .filter(\.$zone.$id ~~ zoneIDs)
            .all()
        let networkIDs = Array(Set(attachments.map { $0.$logicalNetwork.id }))
        var networks: [UUID: LogicalNetwork] = [:]
        if !networkIDs.isEmpty {
            for network in try await LogicalNetwork.query(on: db).filter(\.$id ~~ networkIDs).all() {
                if let id = network.id { networks[id] = network }
            }
        }
        var attachedByZone: [UUID: [DNSZoneNetworkResponse]] = [:]
        for attachment in attachments {
            guard let network = networks[attachment.$logicalNetwork.id], let networkID = network.id else {
                continue
            }
            attachedByZone[attachment.$zone.id, default: []].append(
                DNSZoneNetworkResponse(
                    networkId: networkID,
                    networkName: network.name,
                    isPrimary: network.$primaryDNSZone.id == attachment.$zone.id))
        }

        var recordCounts: [UUID: Int] = [:]
        for record in try await DNSRecord.query(on: db).filter(\.$zone.$id ~~ zoneIDs).all() {
            recordCounts[record.$zone.id, default: 0] += 1
        }

        return try zones.map { zone in
            let id = try zone.requireID()
            return try DNSZoneResponse(
                from: zone,
                networks: (attachedByZone[id] ?? []).sorted { $0.networkName < $1.networkName },
                recordCount: recordCounts[id] ?? 0)
        }
    }
}

extension String {
    fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
