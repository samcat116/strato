import Fluent
import Vapor

/// A pool of external (floating) IPv4 addresses the control plane's IPAM
/// allocates `FloatingIP`s from (issue #344). The pool's CIDR is address
/// space the *customer* owns and routes to the site's provider network —
/// typically the uplink subnet itself, or a separate prefix their fabric
/// statically routes (or BGP-learns, with OVN dynamic routing + FRR) toward
/// the site's gateway.
///
/// Pools are infrastructure, scoped like sites: an org-or-OU owner, plus an
/// optional pin to one site. A site-pinned pool only attaches to NICs on
/// networks of that site (one OVN deployment advertises/answers for the
/// addresses); an unpinned pool is for the legacy single-node model.
final class FloatingIPPool: Model, @unchecked Sendable {
    static let schema = "floating_ip_pools"

    @ID(key: .id)
    var id: UUID?

    /// Unique operator-facing name.
    @Field(key: "name")
    var name: String

    /// The external address range in CIDR notation (e.g. `203.0.113.0/24`).
    /// Floating IPs are allocated from its host range, lowest-free.
    @Field(key: "cidr")
    var cidr: String

    /// Router/gateway address inside the range, excluded from allocation.
    /// Operators should also size or split the range so agents' dedicated
    /// uplink IPs (`[ovn_uplink] external_cidr`) fall outside it.
    @OptionalField(key: "gateway")
    var gateway: String?

    /// Site whose OVN deployment answers for these addresses; nil for
    /// single-node deployments.
    @OptionalParent(key: "site_id")
    var site: Site?

    /// Owning organization scope (exactly one of the two), mirroring `Site`.
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    @OptionalParent(key: "organizational_unit_id")
    var organizationalUnit: OrganizationalUnit?

    @Children(for: \.$pool)
    var floatingIPs: [FloatingIP]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        cidr: String,
        gateway: String? = nil,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) {
        self.id = id
        self.name = name
        self.cidr = cidr
        self.gateway = gateway
        self.$site.id = siteID
        self.$organization.id = organizationScope?.organizationID
        self.$organizationalUnit.id = organizationScope?.organizationalUnitID
    }

    /// The pool's org-or-OU owner; nil only for rows that predate scoping.
    var organizationScope: OrganizationScope? {
        get {
            if let orgID = self.$organization.id { return .organization(orgID) }
            if let ouID = self.$organizationalUnit.id { return .organizationalUnit(ouID) }
            return nil
        }
        set {
            self.$organization.id = newValue?.organizationID
            self.$organizationalUnit.id = newValue?.organizationalUnitID
        }
    }
}

extension FloatingIPPool: Content {}

// MARK: - DTOs

struct CreateFloatingIPPoolRequest: Content {
    let name: String
    /// External range in CIDR notation; prefix must be within /8–/30.
    let cidr: String
    /// Gateway inside the range, excluded from allocation.
    let gateway: String?
    /// Site whose OVN deployment answers for the range.
    let siteId: UUID?
    /// Owning scope; exactly one of the two is required.
    let organizationId: UUID?
    let organizationalUnitId: UUID?
}

/// Full-replace (PUT) semantics for the mutable fields, matching
/// `UpdateSiteRequest`. The CIDR is immutable while addresses are allocated.
struct UpdateFloatingIPPoolRequest: Content {
    let gateway: String?
    let siteId: UUID?
}

struct FloatingIPPoolResponse: Content {
    let id: UUID
    let name: String
    let cidr: String
    let gateway: String?
    let siteId: UUID?
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let allocatedCount: Int
    let createdAt: Date?

    init(from pool: FloatingIPPool, allocatedCount: Int) throws {
        self.id = try pool.requireID()
        self.name = pool.name
        self.cidr = pool.cidr
        self.gateway = pool.gateway
        self.siteId = pool.$site.id
        self.organizationId = pool.$organization.id
        self.organizationalUnitId = pool.$organizationalUnit.id
        self.allocatedCount = allocatedCount
        self.createdAt = pool.createdAt
    }
}
