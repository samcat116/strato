import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Domain logic shared by the security-group API and the paths that need a
/// group implicitly (VM create attaching the project default).
enum SecurityGroupService {

    /// Returns the project's default security group, creating it — with pure
    /// AWS default-group semantics (allow all ingress from the group itself,
    /// allow all egress; no blanket ingress) — when the project predates the
    /// call. Projects that existed when security groups landed got theirs
    /// from `SeedDefaultSecurityGroups`; this is the path for projects
    /// created afterwards and a defensive fallback everywhere the default is
    /// assumed.
    ///
    /// Call inside the transaction that consumes the group so a concurrent
    /// creator can't observe the invariant half-established; the partial
    /// unique index on `(project_id) WHERE is_default` breaks read-then-write
    /// races (the second creator's insert fails and retries the lookup).
    static func ensureDefaultGroup(projectID: UUID, on db: Database) async throws -> SecurityGroup {
        if let existing = try await SecurityGroup.query(on: db)
            .filter(\.$project.$id == projectID)
            .filter(\.$isDefault == true)
            .first()
        {
            return existing
        }

        let group = SecurityGroup(
            projectID: projectID,
            name: SecurityGroup.defaultGroupName,
            description: "Default security group",
            isDefault: true
        )
        do {
            try await group.save(on: db)
        } catch {
            // Lost a race with a concurrent creator: the partial unique index
            // refused the second default. Use theirs.
            if let existing = try await SecurityGroup.query(on: db)
                .filter(\.$project.$id == projectID)
                .filter(\.$isDefault == true)
                .first()
            {
                return existing
            }
            throw error
        }

        let groupID = try group.requireID()
        for ethertype in [SecurityGroupRule.Ethertype.ipv4, .ipv6] {
            try await SecurityGroupRule(
                securityGroupID: groupID,
                direction: .ingress,
                ethertype: ethertype,
                remoteGroupID: groupID
            ).save(on: db)
            try await SecurityGroupRule(
                securityGroupID: groupID,
                direction: .egress,
                ethertype: ethertype
            ).save(on: db)
        }
        return group
    }

    /// Validates a rule request against the model's invariants. Returns the
    /// normalized protocol name.
    static func validateRule(
        _ request: CreateSecurityGroupRuleRequest,
        groupProjectID: UUID,
        on db: Database
    ) async throws -> String? {
        if request.remoteCIDR != nil && request.remoteGroupId != nil {
            throw Abort(.badRequest, reason: "A rule may have a CIDR peer or a group peer, not both")
        }

        var protocolName: String?
        if let requested = request.protocolName {
            let normalized = requested.lowercased()
            guard SecurityGroupRule.allowedProtocols.contains(normalized) else {
                throw Abort(
                    .badRequest,
                    reason: "Unsupported protocol '\(requested)': expected tcp, udp, or icmp")
            }
            protocolName = normalized
        }

        switch protocolName {
        case "tcp", "udp":
            if let min = request.portRangeMin, let max = request.portRangeMax {
                guard (0...65535).contains(min), (0...65535).contains(max), min <= max else {
                    throw Abort(.badRequest, reason: "Port range must satisfy 0 ≤ min ≤ max ≤ 65535")
                }
            } else if request.portRangeMin != nil || request.portRangeMax != nil {
                throw Abort(.badRequest, reason: "Port ranges need both portRangeMin and portRangeMax")
            }
        case "icmp":
            // portRangeMin is the ICMP type, portRangeMax the code; the code
            // is meaningless without a type.
            if let type = request.portRangeMin {
                guard (0...255).contains(type) else {
                    throw Abort(.badRequest, reason: "ICMP type must be 0–255")
                }
                if let code = request.portRangeMax {
                    guard (0...255).contains(code) else {
                        throw Abort(.badRequest, reason: "ICMP code must be 0–255")
                    }
                }
            } else if request.portRangeMax != nil {
                throw Abort(.badRequest, reason: "An ICMP code (portRangeMax) needs a type (portRangeMin)")
            }
        default:
            if request.portRangeMin != nil || request.portRangeMax != nil {
                throw Abort(.badRequest, reason: "Port ranges require a protocol of tcp, udp, or icmp")
            }
        }

        if let cidr = request.remoteCIDR {
            switch request.ethertype {
            case .ipv4:
                guard IPv4CIDR(cidr) != nil else {
                    throw Abort(.badRequest, reason: "remoteCIDR is not a valid IPv4 CIDR: \(cidr)")
                }
            case .ipv6:
                guard IPv6CIDR(cidr) != nil else {
                    throw Abort(.badRequest, reason: "remoteCIDR is not a valid IPv6 CIDR: \(cidr)")
                }
            }
        }

        if let remoteGroupId = request.remoteGroupId {
            // Cross-project references would leak membership information across
            // tenancy boundaries and complicate sync scoping — and the caller
            // holds rights on *this rule's* group, not on the one it names, so
            // a distinct cross-project answer would itself disclose that the id
            // names a group in some other project. Scoping the lookup collapses
            // both into one honest "not found" (issue #777).
            let remote = try await SecurityGroup.query(on: db)
                .filter(\.$id == remoteGroupId)
                .filter(\.$project.$id == groupProjectID)
                .first()
            guard remote != nil else {
                throw Abort(.badRequest, reason: "Referenced security group not found")
            }
        }

        return protocolName
    }

    /// Validates the security groups a workload create asked for and returns
    /// them deduplicated, order preserved. Empty in means empty out — the
    /// caller substitutes the project default inside its create transaction,
    /// where `ensureDefaultGroup` belongs.
    ///
    /// Deliberately no agent-version gate: workload create must work on a
    /// pre-security-group fleet, where sync assembly simply omits the fields
    /// (documented mixed-fleet rollout semantics).
    static func resolveRequestedGroupIDs(
        _ requested: [UUID]?, projectID: UUID, on db: Database
    ) async throws -> [UUID] {
        let unique: [UUID] = (requested ?? []).reduce(into: []) { unique, groupId in
            if !unique.contains(groupId) { unique.append(groupId) }
        }
        guard unique.count <= SecurityGroup.maxGroupsPerNIC else {
            throw Abort(
                .badRequest,
                reason: "At most \(SecurityGroup.maxGroupsPerNIC) security groups per interface")
        }
        guard !unique.isEmpty else { return unique }

        // Scoped to the project, exactly like the NIC's network
        // (`LogicalNetworkService.resolveForWorkloadCreate`), and reported the
        // same way: *not found here*. Nothing authorizes the caller against the
        // named group, so a distinct "belongs to another project" answer would
        // confirm that an opaque id names a group somewhere in the fleet — the
        // disclosure the containment guard is placed behind an authorization
        // check to avoid everywhere it does fire (issue #777).
        //
        // One query for the set, then a difference, rather than a lookup per
        // id: the cap bounds it either way, but the error still names the
        // specific id that was missing.
        let found = Set(
            try await SecurityGroup.query(on: db)
                .filter(\.$id ~~ unique)
                .filter(\.$project.$id == projectID)
                .all()
                .compactMap(\.id))
        if let missing = unique.first(where: { !found.contains($0) }) {
            throw Abort(.notFound, reason: "Security group \(missing) not found in this project")
        }
        return unique
    }

    // MARK: - Membership serialization

    /// Serializes a NIC's membership mutations for the duration of the
    /// enclosing transaction, so attach/detach enforce their invariants
    /// against a set that cannot move underneath them.
    ///
    /// Without it, detach is a read-guard-delete on three separate
    /// statements: two concurrent detaches of a NIC's last two groups both
    /// read `count == 2`, both pass the >=1-group guard, and the NIC lands on
    /// zero memberships. That state is **not self-healing**, which is what
    /// makes it worth a lock rather than a retry —
    /// `DesiredStateAssembler.nicSecurityGroupMemberships` builds its map by
    /// appending rows, so a NIC with none is *absent* from it, the spec
    /// carries `securityGroupIds: nil`, and the agent reads nil as "no
    /// opinion" and leaves the port's OVN membership exactly as it was. The
    /// port would keep filtering by groups the control plane no longer
    /// records, forever, while the API reported an empty list. The attach
    /// path takes the same lock so the per-NIC cap is enforced against the
    /// same stable set.
    ///
    /// `pg_advisory_xact_lock` for the same reasons as `IPAMService`: it is
    /// held to the end of the transaction and serializes across replicas,
    /// which no unique index can do here (the invariant is a *count*, not a
    /// duplicate). Keyed on the interface id, with a prefix so VM and sandbox
    /// NICs cannot collide in the shared lock space.
    static func lockMembership(interfaceID: UUID, on db: Database) async throws {
        guard let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw(
            "SELECT pg_advisory_xact_lock(hashtext(\(bind: "sgmember:\(interfaceID.uuidString)")))"
        ).run()
    }

    // MARK: - Attachments

    /// How many NICs attach each of `groupIds`, summed across the VM and
    /// sandbox join tables (STR-34). Two grouped counts for the whole page,
    /// never a COUNT per group; groups with no attachments are absent from the
    /// result.
    ///
    /// Aggregated in SQL rather than by fetching the rows and counting them in
    /// memory: a group attached to a few thousand NICs would otherwise make
    /// the security-groups list endpoint allocate proportionally to attachment
    /// count, for a number it only needs to display.
    ///
    /// Both tables must be counted everywhere, and it is easy to count only
    /// one: an undercount would let the API report a group as unattached and
    /// then hand the caller a bare FK violation when they try to delete it.
    static func attachmentCounts(forGroups groupIds: [UUID], on db: Database) async throws -> [UUID: Int] {
        guard !groupIds.isEmpty else { return [:] }
        guard let sql = db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Attachment counts require an SQL database")
        }

        struct CountRow: Decodable {
            let securityGroupID: UUID
            let total: Int

            enum CodingKeys: String, CodingKey {
                case securityGroupID = "security_group_id"
                case total
            }
        }

        var counts: [UUID: Int] = [:]
        for table in ["vm_interface_security_groups", "sandbox_interface_security_groups"] {
            let rows = try await sql.select()
                .column("security_group_id")
                .column(SQLFunction("COUNT", args: SQLLiteral.all), as: "total")
                .from(table)
                .where("security_group_id", .in, SQLBind.group(groupIds))
                .groupBy("security_group_id")
                .all(decoding: CountRow.self)
            for row in rows {
                counts[row.securityGroupID, default: 0] += row.total
            }
        }
        return counts
    }

    /// How many NICs attach one group, across both join tables.
    static func attachmentCount(forGroup groupId: UUID, on db: Database) async throws -> Int {
        let vmCount = try await VMInterfaceSecurityGroup.query(on: db)
            .filter(\.$securityGroup.$id == groupId)
            .count()
        let sandboxCount = try await SandboxInterfaceSecurityGroup.query(on: db)
            .filter(\.$securityGroup.$id == groupId)
            .count()
        return vmCount + sandboxCount
    }

    // MARK: - Enforcement

    /// What would actually realize a VM's security groups — the single source
    /// for both the attach/detach gate and the API's `securityGroupsEnforced`
    /// indicator (STR-34), so the two can never disagree about what a
    /// mixed-version or half-broken fleet is doing.
    enum Realization {
        /// Unplaced: nothing realizes the VM yet, so there is nothing to judge.
        case unplaced
        /// Nothing would author the site's port groups and ACLs at all — no
        /// designated network controller, or one that cannot author topology
        /// right now (issue #833). Carries the 409 a synchronous path throws.
        case unauthored(Abort)
        /// The agents that must understand security groups for the VM's groups
        /// to filter anything: the host (which binds its port's group
        /// membership) and, when the site designates a different one, the
        /// network controller (which authors the ACLs).
        case realizers([Agent])
    }

    static func realization(for vm: VM, on db: Database) async throws -> Realization {
        try await realization(forHypervisorId: vm.hypervisorId, on: db)
    }

    /// The placement-keyed half. Named by the hypervisor id rather than the
    /// workload because that is all the answer ever depended on — which is what
    /// lets sandboxes reuse it (STR-102) without a second copy of the
    /// unplaced/authority reasoning below.
    static func realization(forHypervisorId hypervisorId: String?, on db: Database) async throws -> Realization {
        guard let hypervisorId,
            let agentUUID = UUID(uuidString: hypervisorId),
            let host = try await Agent.find(agentUUID, on: db)
        else { return .unplaced }
        return try await realization(host: host, on: db)
    }

    /// The host-keyed half, so the batch path can resolve once per distinct
    /// agent instead of once per VM.
    ///
    /// Resolving through `SiteNetworkAuthority` rather than reading the site's
    /// controller column keeps this in step with assembly, which notably keeps
    /// a *pre-v4 host* on legacy per-node scoping: such a host authors its own
    /// ACLs and the site controller realizes nothing for it, so
    /// `.selfAuthored` correctly leaves it as the sole realizer.
    static func realization(host: Agent, on db: Database) async throws -> Realization {
        realization(host: host, authority: try await SiteNetworkAuthority.resolve(forAgent: host, on: db))
    }

    /// The pure half, given an already-resolved authority. Split out so the
    /// batch path can share one site's authority across its hosts: the
    /// authority is site-derived, but the *answer* is not — `refusal` excuses
    /// a host that is itself the unusable controller, and the version check
    /// reads the host's own registration.
    static func realization(host: Agent, authority: SiteNetworkAuthority.Authority) -> Realization {
        if let refusal = SiteNetworkAuthority.refusal(
            authority, host: host, consequence: "the group's ACLs would be realized nowhere")
        {
            return .unauthored(refusal)
        }
        var realizers = [host]
        if case .controller(let controller) = authority, controller.id != host.id {
            realizers.append(controller)
        }
        return .realizers(realizers)
    }

    /// Whether one VM's security groups are enforced, or nil when it is
    /// unplaced (unknown — not "unenforced"). An unauthored site is `false`:
    /// the groups are attached and nothing will ever write their ACLs.
    static func enforcement(for vm: VM, on db: Database) async throws -> Bool? {
        enforcement(of: try await realization(for: vm, on: db))
    }

    /// The sandbox twin (STR-102). `sandbox.$networkInterfaces` must be
    /// eager-loaded; an unloaded relation reads as "no NIC", which is the same
    /// contract `SandboxDetailResponse.securityGroupIds` already keeps — the
    /// two are shown side by side, so they must agree about what silence means.
    ///
    /// One question more than the VM path asks (STR-103): a host that does not
    /// advertise sandbox networking is never sent the NIC's `NetworkSpec`, so
    /// there is no logical switch port to join a port group and no version or
    /// site authority can change that. `false`, not nil — the groups are
    /// attached and demonstrably enforce nothing, which is the same answer an
    /// unauthored site gets.
    ///
    /// ## What `true` claims, and the one case where it over-claims
    ///
    /// This is a **host-capability** verdict, not a per-sandbox realization
    /// one. For a VM the two coincide, because a VM's OVN port already exists
    /// and the topology authority updates its port-group membership out of
    /// band. A sandbox's port is created *with the sandbox* and only then:
    /// `bootSandbox` starts or resumes the existing microVM rather than
    /// re-provisioning it, and `sandboxStatusSteps` plans nothing at all for
    /// `.running`/`.running`, so neither a boot nor `POST .../restart` (a
    /// desired-running generation bump) attaches a NIC that was absent at
    /// create. Only delete-and-recreate does.
    ///
    /// So a sandbox created on a host *before* that host advertised sandbox
    /// networking reads `true` here once the host is upgraded, while its
    /// microVM still has no interface. That population is every networked
    /// sandbox predating STR-103, bounded by sandbox lifetime (TTL and the
    /// retention sweep), and it shrinks to nothing as they age out.
    ///
    /// It is not fixed here because the honest signal is not cheap:
    /// `ObservedSandboxState` carries no NIC field, and the obvious source for
    /// one — `FirecrackerSandboxRuntime.Managed.networkAttachments` — is
    /// in-memory and *not* recovered by `adoptSandbox`, so reporting it would
    /// read `false` for every correctly-networked sandbox after an agent
    /// restart. That is a worse lie than this one, in the direction that
    /// matters more. Closing it properly means recovering the attachment at
    /// adoption first; see `docs/architecture/sandboxes.md`.
    static func sandboxEnforcement(for sandbox: Sandbox, on db: Database) async throws -> Bool? {
        // No interface, nothing to filter. Nil is "unknown", not "unenforced" —
        // the same distinction an unplaced VM gets.
        guard let interfaces = sandbox.$networkInterfaces.value, !interfaces.isEmpty else { return nil }
        guard let hypervisorId = sandbox.hypervisorId,
            let hostID = UUID(uuidString: hypervisorId),
            let host = try await Agent.find(hostID, on: db)
        else { return nil }
        guard host.sandboxNetworkingCapable else { return false }
        return enforcement(of: try await realization(host: host, on: db))
    }

    /// Whether each sandbox's security groups are enforced, keyed by sandbox
    /// id — the batched form of ``sandboxEnforcement(for:on:)``, on the same
    /// terms as ``enforcementByVM(_:on:)``: resolved once per distinct host and
    /// once per distinct site, with a sandbox absent from the result whenever
    /// the answer is "unknown" (no NIC, unplaced, or a `hypervisorId` naming a
    /// row that no longer exists).
    ///
    /// The list endpoint needs this now that the verdict reads the database.
    /// Before STR-103 it short-circuited on a fleet-wide constant and cost no
    /// query at all, which is why the list path could afford it per row.
    static func enforcementBySandbox(_ sandboxes: [Sandbox], on db: Database) async throws -> [UUID: Bool] {
        let hostIDsBySandbox: [UUID: UUID] = sandboxes.reduce(into: [:]) { map, sandbox in
            guard let sandboxID = sandbox.id,
                let interfaces = sandbox.$networkInterfaces.value, !interfaces.isEmpty,
                let hypervisorId = sandbox.hypervisorId,
                let hostID = UUID(uuidString: hypervisorId)
            else { return }
            map[sandboxID] = hostID
        }
        guard !hostIDsBySandbox.isEmpty else { return [:] }

        let enforcedByHost = try await enforcementByHost(
            ids: Set(hostIDsBySandbox.values), on: db,
            // A host that cannot realize a sandbox NIC has no port to filter,
            // whatever its site authority says — see `sandboxEnforcement`.
            override: { $0.sandboxNetworkingCapable ? nil : false })

        var result: [UUID: Bool] = [:]
        for (sandboxID, hostID) in hostIDsBySandbox {
            guard let enforced = enforcedByHost[hostID] else { continue }
            result[sandboxID] = enforced
        }
        return result
    }

    private static func enforcement(of realization: Realization) -> Bool? {
        switch realization {
        case .unplaced: return nil
        case .unauthored: return false
        case .realizers: return true
        }
    }

    /// Whether each VM's security groups are enforced, keyed by VM id. A VM is
    /// absent from the result when it is unplaced (the caller reports nil).
    ///
    /// Resolved once per distinct host, and — since
    /// `SiteNetworkAuthority.resolve` is a `Site` lookup plus a controller
    /// `Agent` lookup — once per distinct *site*. Hosts cluster onto sites far
    /// more tightly than VMs cluster onto hosts, so without the site memo every
    /// peer in a site refetches the same two rows: a page spanning 50 hosts
    /// across 3 sites costs ~6 queries instead of ~100.
    static func enforcementByVM(_ vms: [VM], on db: Database) async throws -> [UUID: Bool] {
        let hostIDsByVM: [UUID: UUID] = vms.reduce(into: [:]) { map, vm in
            guard let vmID = vm.id,
                let hypervisorId = vm.hypervisorId,
                let hostID = UUID(uuidString: hypervisorId)
            else { return }
            map[vmID] = hostID
        }
        guard !hostIDsByVM.isEmpty else { return [:] }

        let enforcedByHost = try await enforcementByHost(ids: Set(hostIDsByVM.values), on: db)

        var result: [UUID: Bool] = [:]
        for (vmID, hostID) in hostIDsByVM {
            // A hypervisorId naming an agent row that no longer exists reads as
            // unplaced: better "unknown" than a claim in either direction.
            guard let enforced = enforcedByHost[hostID] else { continue }
            result[vmID] = enforced
        }
        return result
    }

    /// The enforcement verdict per host, memoized per site — the shared half of
    /// both batch paths.
    ///
    /// `override` gets first refusal on each host, for a workload-family fact
    /// that settles the answer before topology authority is even relevant (the
    /// sandbox NIC's capability gate is the only one today). Returning nil from
    /// it means "no opinion, resolve normally".
    ///
    /// Hosts absent from the result are hosts whose row was not found; their
    /// workloads read as unplaced.
    private static func enforcementByHost(
        ids: Set<UUID>, on db: Database, override: (Agent) -> Bool? = { _ in nil }
    ) async throws -> [UUID: Bool] {
        let hosts = try await Agent.query(on: db)
            .filter(\.$id ~~ Array(ids))
            .all()
        var enforcedByHost: [UUID: Bool] = [:]
        var authorityBySite: [UUID: SiteNetworkAuthority.Authority] = [:]
        for host in hosts {
            guard let hostID = host.id else { continue }
            if let settled = override(host) {
                enforcedByHost[hostID] = settled
                continue
            }
            let authority: SiteNetworkAuthority.Authority
            let siteID = host.$site.id
            if let cached = authorityBySite[siteID] {
                authority = cached
            } else {
                authority = try await SiteNetworkAuthority.resolve(forAgent: host, on: db)
                // Cache only site-derived answers. `.selfAuthored` is a
                // property of the agent — a site-less host, or a pre-v4 one
                // writing its own NB — and sharing it with a site's other
                // hosts would claim they author their own topology too.
                authorityBySite[siteID] = authority
            }
            enforcedByHost[hostID] = enforcement(of: realization(host: host, authority: authority))
        }
        return enforcedByHost
    }
}
