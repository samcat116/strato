import Foundation
import Vapor

// The production project routes use generated OpenAPI request models. These
// lightweight bodies exist only for black-box route tests that encode JSON.
package struct CreateProjectRequest: Content {
    package let name: String
    package let description: String
    package let organizationalUnitId: UUID?
    package let defaultEnvironment: String?
    package let environments: [String]?

    package init(
        name: String,
        description: String,
        organizationalUnitId: UUID?,
        defaultEnvironment: String?,
        environments: [String]?
    ) {
        self.name = name
        self.description = description
        self.organizationalUnitId = organizationalUnitId
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
    }
}

package struct UpdateProjectRequest: Content {
    package let name: String?
    package let description: String?
    package let defaultEnvironment: String?
    package let environments: [String]?

    package init(
        name: String?,
        description: String?,
        defaultEnvironment: String?,
        environments: [String]?
    ) {
        self.name = name
        self.description = description
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
    }
}

package struct ProjectEnvironmentRequest: Content {
    package let environment: String

    package init(environment: String) {
        self.environment = environment
    }
}

package struct TransferProjectRequest: Content {
    package let organizationId: UUID?
    package let organizationalUnitId: UUID?

    package init(organizationId: UUID?, organizationalUnitId: UUID?) {
        self.organizationId = organizationId
        self.organizationalUnitId = organizationalUnitId
    }
}
