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
            guard let remote = try await SecurityGroup.find(remoteGroupId, on: db) else {
                throw Abort(.badRequest, reason: "Referenced security group not found")
            }
            guard remote.$project.id == groupProjectID else {
                // Cross-project references would leak membership information
                // across tenancy boundaries and complicate sync scoping.
                throw Abort(.badRequest, reason: "A rule can only reference a security group in the same project")
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
}
