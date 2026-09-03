import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

// MARK: - Security-group actuation (OVN port groups + ACLs)

extension NetworkServiceLinux: SecurityGroupActuator {
    /// External-id key carrying the generation a port group's ACL set was
    /// built from; absence forces a rewrite (see `needsACLRewrite`) and marks
    /// the group not-yet-enforcing for the membership paths — the row can
    /// exist committed transactions before its ACLs do.
    static let generationKey = "strato-generation"
    /// External-id key carrying the `aclSchemaRevision` that wrote the ACLs,
    /// so builder fixes roll out on agent upgrade without waiting for rule
    /// edits to bump each group's generation.
    static let builderRevisionKey = "strato-builder-rev"

    func observeSecurityGroups() async throws -> [ObservedPortGroup] {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        return try await ovnManager.getPortGroups()
            .filter { Self.isManaged($0.external_ids) }
            .map {
                ObservedPortGroup(
                    name: $0.name,
                    generation: $0.external_ids?[Self.generationKey].flatMap(Int64.init),
                    builderRevision: $0.external_ids?[Self.builderRevisionKey].flatMap(Int64.init))
            }
        #else
        return []
        #endif
    }

    func ensurePortGroup(_ plan: PortGroupPlan) async throws -> Bool {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }

        let pgUUID: String
        var supersededACLs: [String] = []
        if let existing = try await ovnManager.getPortGroup(named: plan.name) {
            guard
                SecurityGroupReconciler.needsACLRewrite(
                    planned: plan.generation,
                    observed: existing.external_ids?[Self.generationKey].flatMap(Int64.init),
                    observedBuilderRevision: existing.external_ids?[Self.builderRevisionKey]
                        .flatMap(Int64.init))
            else {
                return existing.external_ids?[Self.builderRevisionKey]
                    .flatMap(Int64.init) == SecurityGroupACLBuilder.aclSchemaRevision
            }
            guard let uuid = existing.uuid else {
                throw NetworkError.ovnError("Port group \(plan.name) has no UUID")
            }
            pgUUID = uuid
            supersededACLs = existing.acls ?? []
        } else {
            // Created without the generation stamp: the membership paths read
            // a stamp-less group as not-yet-enforcing and refuse to join it,
            // so a port can never go live behind a group whose ACLs aren't
            // written yet. `ports` stays untouched here and always
            // (membership belongs to each VM's hosting agent).
            pgUUID = try await ovnManager.createPortGroup(
                OVNPortGroup(name: plan.name, external_ids: [Self.managedKey: Self.managedValue]))
        }

        // Full replace, NEW SET FIRST: OVN ACL rows have no natural key to
        // diff on, and each write is its own OVSDB transaction. Creating
        // before deleting means the group never has *fewer* ACLs than it
        // started with — with both sets present the drops still drop and the
        // allows still allow, so live members (the drop group holds every
        // managed port on the site) never lose their default-deny, and a rule
        // edit never blacks out the group's allows. Deleting first would open
        // exactly those windows. Duplicates during the overlap are harmless.
        for acl in plan.acls {
            _ = try await ovnManager.createACL(
                OVNACL(
                    priority: acl.priority,
                    direction: acl.direction,
                    match: acl.match,
                    action: acl.action,
                    // Per-rule logging (STR-34). `name` is what identifies the
                    // rule in the emitted line, so it rides with `log`.
                    log: acl.log,
                    severity: acl.severity,
                    name: acl.name,
                    external_ids: acl.externalIDs,
                    tier: acl.tier),
                onPortGroup: plan.name)
        }
        for aclUUID in supersededACLs {
            try await ovnManager.deleteACL(uuid: aclUUID)
        }

        // Stamps last: a crash anywhere above leaves them absent/stale and
        // the next sync redoes the whole rewrite.
        try await ovnManager.updatePortGroup(
            uuid: pgUUID,
            OVNPortGroup(
                name: plan.name,
                external_ids: [
                    Self.managedKey: Self.managedValue,
                    Self.generationKey: String(plan.generation),
                    Self.builderRevisionKey: String(SecurityGroupACLBuilder.aclSchemaRevision),
                ]))
        logger.info(
            "Security-group port group converged",
            metadata: [
                "portGroup": .string(plan.name),
                "generation": .stringConvertible(plan.generation),
                "acls": .stringConvertible(plan.acls.count),
            ])
        return true
        #endif

        #if !os(Linux)
        return false
        #endif
    }

    func removePortGroup(named name: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // Only ever called for managed groups (observeSecurityGroups filters),
        // and deletion drops its ACL rows with it; member-port references are
        // weak, so no port cleanup is needed.
        try await ovnManager.deletePortGroup(named: name)
        logger.info(
            "Security-group port group removed", metadata: ["portGroup": .string(name)])
        #endif
    }

    func observeMembership(ofPorts portNames: [String]) async throws -> [String: Set<String>] {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        let groups = try await ovnManager.getPortGroups().filter { Self.isManaged($0.external_ids) }
        var membership: [String: Set<String>] = [:]
        for portName in portNames {
            guard let portUUID = try await ovnManager.getLogicalSwitchPort(named: portName)?.uuid
            else { continue }
            for group in groups where (group.ports ?? []).contains(portUUID) {
                membership[portName, default: []].insert(group.name)
            }
        }
        return membership
        #else
        return [:]
        #endif
    }

    func addPort(named portName: String, toGroup group: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let portGroup = try await ovnManager.getPortGroup(named: group) else {
            throw ConvergenceError.sourceNotReady(
                "port group \(group) does not exist yet; waiting for the site's network controller to realize it"
            )
        }
        // Existence is not enforcement: the authority realizes a group as
        // separate transactions (row, then ACLs, then the generation stamp),
        // so a stamp-less row is a group whose ACLs are not written yet —
        // joining it would put the port behind a drop group with no drops.
        guard portGroup.external_ids?[Self.generationKey] != nil else {
            throw ConvergenceError.sourceNotReady(
                "port group \(group) exists but its ACLs are not realized yet; waiting for the site's network controller"
            )
        }
        guard let portUUID = try await ovnManager.getLogicalSwitchPort(named: portName)?.uuid else {
            // The VM's own reconcile lane creates the port; membership catches
            // up on the next sync.
            throw ConvergenceError.sourceNotReady("logical switch port \(portName) does not exist yet")
        }
        try await ovnManager.addPorts([portUUID], toPortGroup: group)
        #endif
    }

    func removePort(named portName: String, fromGroup group: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let portUUID = try await ovnManager.getLogicalSwitchPort(named: portName)?.uuid else {
            return
        }
        try await ovnManager.removePorts([portUUID], fromPortGroup: group)
        #endif
    }
}
