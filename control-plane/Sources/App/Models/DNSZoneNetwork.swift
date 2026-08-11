import Fluent
import Vapor

/// A zone↔network attachment: "VMs on this network can resolve this zone."
///
/// Many-to-many on purpose. One network may resolve several zones (a shared
/// services zone plus the team's own), and one zone may serve several networks
/// — which is what `Logical_Switch.dns_records` being a set of weak refs
/// already permits. Where a network's VMs *register* is a separate, singular
/// decision: `LogicalNetwork.primaryDNSZone`, which must name one of these
/// attachments.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class DNSZoneNetwork: Model, @unchecked Sendable {
    static let schema = "dns_zone_networks"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "zone_id")
    var zone: DNSZone

    @Parent(key: "logical_network_id")
    var logicalNetwork: LogicalNetwork

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, zoneID: UUID, logicalNetworkID: UUID) {
        self.id = id
        self.$zone.id = zoneID
        self.$logicalNetwork.id = logicalNetworkID
    }
}

extension DNSZoneNetwork: Content {}
