import ControlPlanePostgres
import Vapor

// MARK: - DTOs

struct CreateFloatingIPPoolRequest: Content, ValidatedRequestBody {
    var name: String
    /// External range in CIDR notation; prefix must be within /8–/30.
    let cidr: String
    /// Gateway inside the range, excluded from allocation.
    let gateway: String?
    /// Site whose OVN deployment answers for the range.
    let siteId: UUID
    /// Owning scope; exactly one of the two is required.
    let organizationId: UUID?
    let organizationalUnitId: UUID?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}

/// Full-replace (PUT) semantics for the mutable fields, matching
/// `UpdateSiteRequest`. The CIDR is immutable while addresses are allocated.
struct UpdateFloatingIPPoolRequest: Content {
    let gateway: String?
    let siteId: UUID
}

struct FloatingIPPoolResponse: Content {
    let id: UUID
    let name: String
    let cidr: String
    let gateway: String?
    let siteId: UUID
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let allocatedCount: Int
    let createdAt: Date?

    init(from pool: FloatingIPPoolSnapshot) {
        self.id = pool.id
        self.name = pool.name
        self.cidr = pool.cidr
        self.gateway = pool.gateway
        self.siteId = pool.siteID
        self.organizationId = pool.organizationID
        self.organizationalUnitId = pool.organizationalUnitID
        self.allocatedCount = pool.allocatedCount
        self.createdAt = pool.createdAt
    }
}
