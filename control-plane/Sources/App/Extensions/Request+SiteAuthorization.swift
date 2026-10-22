import Fluent
import Vapor

extension Request {
    /// Resolve the route's site before enforcing its canonical action. Uses
    /// authorizedResource's standard forbidden reason for Site and Ceph APIs.
    func authorizedSite(action: String) async throws -> Site {
        let siteID = try requireUUIDParameter("siteId", reason: "Invalid site ID")
        return try await authorizedResource(
            siteID, as: Site.self, nodeType: .site, action: action, notFoundReason: "Site not found")
    }
}
