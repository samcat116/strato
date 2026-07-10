import Foundation

/// One existing `Gateway_Chassis` row referenced by a router's external port,
/// reduced to what the reconcile decision needs. SwiftOVN's row types are
/// Linux-only, so the actuator maps them into this shape and the decision
/// logic stays testable everywhere.
public struct GatewayChassisBinding: Equatable, Sendable {
    public let uuid: String
    /// The southbound `Chassis` name (the OVS `system-id`) the row binds to.
    public let chassisName: String
    /// Whether the row carries the Strato ownership marker.
    public let managed: Bool

    public init(uuid: String, chassisName: String, managed: Bool) {
        self.uuid = uuid
        self.chassisName = chassisName
        self.managed = managed
    }
}

/// Converges the external router port's gateway-chassis set on "bound to the
/// local chassis" (issue #372). OVN only programs centralized SNAT on the
/// chassis holding the router's distributed gateway port, and that requires a
/// `Gateway_Chassis` row on the external port — without one the NAT rule sits
/// in the NB unprogrammed and VM traffic egresses un-NAT'd.
public enum GatewayChassisPlan {
    public struct Actions: Equatable, Sendable {
        /// Stale Strato-managed rows to delete.
        public let deleteUUIDs: [String]
        /// Whether a binding for the local chassis must be created.
        public let createForLocalChassis: Bool

        public init(deleteUUIDs: [String], createForLocalChassis: Bool) {
            self.deleteUUIDs = deleteUUIDs
            self.createForLocalChassis = createForLocalChassis
        }
    }

    /// Only the uplink-authoring agent (the site's network controller) runs
    /// this, so single-writer rules apply:
    ///
    /// - Any row already naming the local chassis satisfies the binding —
    ///   including an unmanaged one from the documented manual
    ///   `lrp-set-gateway-chassis` workaround — so upgrading a hand-patched
    ///   deployment doesn't insert a duplicate.
    /// - Strato-managed rows naming another chassis are stale (the host was
    ///   re-provisioned with a new system-id, or the network-controller role
    ///   moved to this agent) and are deleted.
    /// - Unmanaged rows naming other chassis are operator HA/failover config
    ///   and are left alone.
    public static func plan(localChassis: String, existing: [GatewayChassisBinding]) -> Actions {
        let satisfied = existing.contains { $0.chassisName == localChassis }
        let stale = existing.filter { $0.managed && $0.chassisName != localChassis }.map(\.uuid)
        return Actions(deleteUUIDs: stale, createForLocalChassis: !satisfied)
    }
}
