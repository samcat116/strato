import Fluent
import Foundation
import StratoShared

/// One site's topology authority's view of a security group's OVN realization.
/// Rows exist only while the group belongs to that site's desired closure.
final class SecurityGroupSiteObservation: Model, @unchecked Sendable {
    static let schema = "security_group_site_observations"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "security_group_id")
    var securityGroup: SecurityGroup

    @Parent(key: "site_id")
    var site: Site

    @Field(key: "observed_generation")
    var observedGeneration: Int64

    @OptionalField(key: "status")
    var status: String?

    @OptionalField(key: "last_error")
    var lastError: String?

    @OptionalField(key: "failed_generation")
    var failedGeneration: Int64?

    @OptionalField(key: "failure_classification")
    var failureClassification: String?

    @OptionalField(key: "last_error_at")
    var lastErrorAt: Date?

    init() {}

    init(id: UUID? = nil, securityGroupID: UUID, siteID: UUID) {
        self.id = id
        self.$securityGroup.id = securityGroupID
        self.$site.id = siteID
        self.observedGeneration = 0
        self.status = nil
        self.lastError = nil
        self.failedGeneration = nil
        self.failureClassification = nil
        self.lastErrorAt = nil
    }

    var observedStatus: ObservedNetworkFabricStatus? {
        get { status.flatMap(ObservedNetworkFabricStatus.init(rawValue:)) }
        set { status = newValue?.rawValue }
    }

    var observedFailureClassification: ObservedFailureClassification? {
        get { failureClassification.flatMap(ObservedFailureClassification.init(rawValue:)) }
        set { failureClassification = newValue?.rawValue }
    }
}
