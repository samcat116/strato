import Foundation
import StratoAPIClient

public func parseResourceClassReference(
    site: String?, classID: String?
) throws -> Components.Schemas.WorkloadResourceClassReference? {
    guard site != nil || classID != nil else { return nil }
    guard let site, let classID, UUID(uuidString: site) != nil, UUID(uuidString: classID) != nil else {
        throw CLIError.config("--resource-class-site and --resource-class-id must both be valid UUIDs")
    }
    return .init(siteID: site, classID: classID)
}
