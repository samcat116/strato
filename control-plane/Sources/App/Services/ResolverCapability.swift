import Fluent
import Vapor

/// Who can run the per-network DNS resolver, and why a network's guests might
/// not reach one.
///
/// The capability is a property of the **site**, not of any one agent (STR-40):
/// a network's resolver is advertised through one DHCP row authored by the
/// site's topology authority, but answered by a CoreDNS on each chassis, so one
/// host that cannot serve it withholds the feature from every network in the
/// site. That predicate lives here rather than in `DesiredStateAssembler`
/// because two callers now need it — the sync path, which decides what to send,
/// and the API, which has to be able to say *why* a network with an attached
/// zone will not resolve it (STR-201).
enum ResolverCapability {
    /// The agents in `siteID` that cannot run the resolver, sorted. Empty means
    /// the site is capable.
    ///
    /// The names are what the answer costs, and they are worth it: without them
    /// an operator is told a site is holding the feature back with no way to
    /// find which host. A decommissioned agent whose row was never deleted
    /// counts here forever and looks identical to one that is merely
    /// un-upgraded, so both remedies belong in every message built from this.
    ///
    /// Offline agents count. A host that is down is one that will come back, and
    /// treating "not currently connected" as "not in the site" would flip the
    /// resolver on during a rolling restart and off again afterwards.
    static func incapableAgentNames(inSite siteID: UUID, on db: any Database) async throws
        -> [String]
    {
        try await Agent.query(on: db)
            .filter(\.$site.$id == siteID)
            .filter(\.$resolverCapable == false)
            .all()
            .map(\.name)
            .sorted()
    }

    /// Every resolver-incapable agent in the fleet, grouped for repeated asking.
    ///
    /// One query, so listing N networks costs one round trip rather than N. The
    /// common case materializes zero rows.
    static func index(on db: any Database) async throws -> Index {
        Index(
            incapable: try await Agent.query(on: db)
                .filter(\.$resolverCapable == false)
                .all())
    }

    /// A fleet-wide snapshot of which sites are holding the resolver back.
    struct Index: Sendable {
        private let bySite: [UUID: [String]]
        init(incapable: [Agent]) {
            self.bySite = Dictionary(grouping: incapable) { $0.$site.id }
            .mapValues { $0.map(\.name).sorted() }
        }

        /// The agents that would withhold the resolver from a network pinned to
        /// `siteID`, or the site-less agents for an unpinned network.
        ///
        /// The sync path asks a site-less receiving agent's own capability and
        /// never consults agents assigned to unrelated sites. Restricting this
        /// warning to the site-less complement keeps the API's explanation on
        /// the same scope as that delivery decision.
        func incapableAgentNames(forSite siteID: UUID) -> [String] {
            return bySite[siteID] ?? []
        }
    }

    /// Why this network's guests will not resolve the DNS zones attached to it,
    /// or nil when they will (STR-201).
    ///
    /// Only ever non-nil for a network that has an attached zone — a network
    /// with none has nothing to fail to deliver, and `dnsServers` pointing at a
    /// public resolver is then exactly right rather than a misconfiguration.
    ///
    /// Every branch is a case where the control plane hands guests `dnsServers`
    /// verbatim instead of the network's own resolver address, which is the
    /// state the operator cannot otherwise see: the zone realizes correctly, the
    /// resolver would answer it, and the guest simply never asks. Each names its
    /// remedy, because none of them is guessable from an NXDOMAIN.
    static func zoneResolutionWarning(
        network: LogicalNetwork, attachedZoneCount: Int, incapableAgentNames: [String]
    ) -> String? {
        guard attachedZoneCount > 0 else { return nil }
        let zones = attachedZoneCount == 1 ? "its attached DNS zone" : "its \(attachedZoneCount) attached DNS zones"

        if !network.resolverEnabled {
            return "This network's resolver is off, so guests are given its DNS servers directly "
                + "and will not resolve \(zones). Enable the resolver, or point dnsServers at a "
                + "server that already serves the zone."
        }
        if !incapableAgentNames.isEmpty {
            let hosts = incapableAgentNames.joined(separator: ", ")
            return "The resolver is withheld because \(hosts) cannot run it, so guests are given "
                + "this network's DNS servers directly and will not resolve \(zones). Install "
                + "CoreDNS on those hosts and restart their agents, or delete the rows of any that "
                + "are decommissioned."
        }
        if network.resolverIndex == nil {
            return "This network's resolver has no address allocated yet, so guests are given its "
                + "DNS servers directly and will not resolve \(zones). Updating the network "
                + "allocates one."
        }
        return nil
    }
}
