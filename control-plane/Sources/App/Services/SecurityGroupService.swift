import Fluent
import Foundation
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

    /// The ids of every group attached to `interfaceID`, sorted for stable
    /// wire output.
    static func groupIDs(forInterface interfaceID: UUID, on db: Database) async throws -> [UUID] {
        let memberships = try await VMInterfaceSecurityGroup.query(on: db)
            .filter(\.$interface.$id == interfaceID)
            .all()
        return memberships.map { $0.$securityGroup.id }.sorted { $0.uuidString < $1.uuidString }
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
        for groupId in unique {
            // Scoped to the project, exactly like the NIC's network
            // (`LogicalNetworkService.resolveForWorkloadCreate`), and reported
            // the same way: *not found here*. Nothing authorizes the caller
            // against the named group, so a distinct "belongs to another
            // project" answer would confirm that an opaque id names a group
            // somewhere in the fleet — the disclosure the containment guard is
            // placed behind an authorization check to avoid everywhere it does
            // fire (issue #777).
            let group = try await SecurityGroup.query(on: db)
                .filter(\.$id == groupId)
                .filter(\.$project.$id == projectID)
                .first()
            guard group != nil else {
                throw Abort(.notFound, reason: "Security group \(groupId) not found in this project")
            }
        }
        return unique
    }

    // MARK: - Attachments

    /// How many NICs attach each of `groupIds`, summed across the VM and
    /// sandbox join tables (STR-34). Two queries for the whole page, never a
    /// COUNT per group; groups with no attachments are absent from the result.
    ///
    /// Both tables must be counted everywhere, and it is easy to count only
    /// one: an undercount would let the API report a group as unattached and
    /// then hand the caller a bare FK violation when they try to delete it.
    static func attachmentCounts(forGroups groupIds: [UUID], on db: Database) async throws -> [UUID: Int] {
        guard !groupIds.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        for membership in try await VMInterfaceSecurityGroup.query(on: db)
            .filter(\.$securityGroup.$id ~~ groupIds)
            .all()
        {
            counts[membership.$securityGroup.id, default: 0] += 1
        }
        for membership in try await SandboxInterfaceSecurityGroup.query(on: db)
            .filter(\.$securityGroup.$id ~~ groupIds)
            .all()
        {
            counts[membership.$securityGroup.id, default: 0] += 1
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
        guard let hypervisorId = vm.hypervisorId,
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
        let authority = try await SiteNetworkAuthority.resolve(forAgent: host, on: db)
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

    private static func enforcement(of realization: Realization) -> Bool? {
        switch realization {
        case .unplaced: return nil
        case .unauthored: return false
        case .realizers(let agents):
            return agents.allSatisfy { WireProtocol.supportsSecurityGroups($0.wireProtocolVersion ?? 0) }
        }
    }

    /// Whether each VM's security groups are enforced, keyed by VM id. A VM is
    /// absent from the result when it is unplaced (the caller reports nil).
    ///
    /// Resolved once per *distinct host* rather than once per VM: a page of
    /// VMs clusters onto a handful of agents, so this stays proportional to
    /// the fleet rather than the page.
    static func enforcementByVM(_ vms: [VM], on db: Database) async throws -> [UUID: Bool] {
        let hostIDsByVM: [UUID: UUID] = vms.reduce(into: [:]) { map, vm in
            guard let vmID = vm.id,
                let hypervisorId = vm.hypervisorId,
                let hostID = UUID(uuidString: hypervisorId)
            else { return }
            map[vmID] = hostID
        }
        guard !hostIDsByVM.isEmpty else { return [:] }

        let hosts = try await Agent.query(on: db)
            .filter(\.$id ~~ Array(Set(hostIDsByVM.values)))
            .all()
        var enforcedByHost: [UUID: Bool] = [:]
        for host in hosts {
            guard let hostID = host.id else { continue }
            enforcedByHost[hostID] = enforcement(of: try await realization(host: host, on: db))
        }

        var result: [UUID: Bool] = [:]
        for (vmID, hostID) in hostIDsByVM {
            // A hypervisorId naming an agent row that no longer exists reads as
            // unplaced: better "unknown" than a claim in either direction.
            guard let enforced = enforcedByHost[hostID] else { continue }
            result[vmID] = enforced
        }
        return result
    }
}
