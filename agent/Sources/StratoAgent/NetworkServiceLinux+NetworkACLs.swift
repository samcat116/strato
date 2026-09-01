import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import SwiftOVN
#endif

// MARK: - Network ACL actuation (OVN logical-switch ACLs)

extension NetworkServiceLinux: NetworkACLActuator {
    func observeNetworkACLs() async throws -> [ObservedNetworkACL] {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }

        var managedACLs: [String: OVNACL] = [:]
        for acl in try await ovnManager.getACLs() {
            guard
                acl.external_ids?[NetworkACLRowIdentity.managedKey]
                    == NetworkACLRowIdentity.managedValue,
                acl.external_ids?[NetworkACLRowIdentity.roleKey]
                    == NetworkACLRowIdentity.roleValue
            else { continue }
            guard let uuid = acl.uuid else {
                throw NetworkError.ovnError("Managed network ACL row has no UUID")
            }
            managedACLs[uuid] = acl
        }

        var observed: [ObservedNetworkACL] = []
        for logicalSwitch in try await ovnManager.getLogicalSwitches() {
            let rules = (logicalSwitch.acls ?? []).compactMap { uuid -> ObservedNetworkACLRule? in
                guard let acl = managedACLs[uuid] else { return nil }
                return ObservedNetworkACLRule(
                    uuid: uuid,
                    action: acl.action,
                    direction: acl.direction,
                    priority: acl.priority,
                    tier: acl.tier,
                    match: acl.match,
                    kind: acl.external_ids?[NetworkACLRowIdentity.ruleKindKey],
                    externalIDs: acl.external_ids ?? [:])
            }
            let ids = logicalSwitch.external_ids ?? [:]
            let hasStamp =
                ids[NetworkACLRowIdentity.generationKey] != nil
                || ids[NetworkACLRowIdentity.builderRevisionKey] != nil
                || ids[NetworkACLRowIdentity.policyStampKey] != nil
            guard !rules.isEmpty || hasStamp else { continue }
            observed.append(
                ObservedNetworkACL(
                    switchName: logicalSwitch.name,
                    policyID: ids[NetworkACLRowIdentity.policyStampKey].flatMap(UUID.init(uuidString:)),
                    generation: ids[NetworkACLRowIdentity.generationKey].flatMap(Int64.init),
                    builderRevision: ids[NetworkACLRowIdentity.builderRevisionKey].flatMap(Int64.init),
                    rules: rules))
        }
        return observed
        #else
        return []
        #endif
    }

    func createNetworkACL(_ acl: ACLSpec, onSwitchNamed switchName: String) async throws -> String {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        return try await ovnManager.createACL(
            OVNACL(
                priority: acl.priority,
                direction: acl.direction,
                match: acl.match,
                action: acl.action,
                log: acl.log,
                severity: acl.severity,
                name: acl.name,
                external_ids: acl.externalIDs,
                tier: acl.tier),
            onSwitch: switchName)
        #else
        return ""
        #endif
    }

    func removeNetworkACL(uuid: String) async throws {
        #if os(Linux)
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        // SwiftOVN detaches this strong reference from both Logical_Switch and
        // Port_Group parents in the same transaction before deleting the row.
        try await ovnManager.deleteACL(uuid: uuid)
        #endif
    }

    func stampNetworkACL(_ plan: NetworkACLPlan) async throws {
        #if os(Linux)
        try await updateNetworkACLStamp(onSwitchNamed: plan.switchName) { ids in
            ids[NetworkACLRowIdentity.policyStampKey] = plan.policyID.uuidString.lowercased()
            ids[NetworkACLRowIdentity.generationKey] = String(plan.generation)
            ids[NetworkACLRowIdentity.builderRevisionKey] = String(NetworkACLBuilder.builderRevision)
        }
        #endif
    }

    func clearNetworkACLStamp(onSwitchNamed switchName: String) async throws {
        #if os(Linux)
        try await updateNetworkACLStamp(onSwitchNamed: switchName, missingIsSuccess: true) { ids in
            ids.removeValue(forKey: NetworkACLRowIdentity.policyStampKey)
            ids.removeValue(forKey: NetworkACLRowIdentity.generationKey)
            ids.removeValue(forKey: NetworkACLRowIdentity.builderRevisionKey)
        }
        #endif
    }

    #if os(Linux)
    /// Updates only `external_ids`. Every strong-reference property on the
    /// model stays nil, so stamping can never replace the switch's ports, ACLs,
    /// QoS rules, or forwarding groups with a stale read.
    private func updateNetworkACLStamp(
        onSwitchNamed switchName: String,
        missingIsSuccess: Bool = false,
        mutate: (inout [String: String]) -> Void
    ) async throws {
        guard let ovnManager else {
            throw NetworkError.notConnected("OVN manager not connected")
        }
        guard let logicalSwitch = try await ovnManager.getLogicalSwitch(named: switchName) else {
            if missingIsSuccess { return }
            throw NetworkError.ovnError("Logical switch \(switchName) not found while stamping network ACL")
        }
        guard let uuid = logicalSwitch.uuid else {
            throw NetworkError.ovnError("Logical switch \(switchName) has no UUID")
        }
        var ids = logicalSwitch.external_ids ?? [:]
        mutate(&ids)
        try await ovnManager.updateLogicalSwitch(
            uuid: uuid,
            OVNLogicalSwitch(name: logicalSwitch.name, external_ids: ids))
    }
    #endif
}
