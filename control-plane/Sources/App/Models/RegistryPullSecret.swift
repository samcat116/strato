import ControlPlanePostgres
import Vapor

/// API shape for a pull secret. Deliberately has no secret field — the
/// credential is write-only through the API, like OIDC client secrets.
struct RegistryPullSecretResponse: Content {
    let id: UUID?
    let projectId: UUID?
    let registry: String
    let username: String
    let createdAt: Date?
    let updatedAt: Date?

    init(from secret: RegistryPullSecretSnapshot) {
        self.id = secret.id
        self.projectId = secret.projectID
        self.registry = secret.registry
        self.username = secret.username
        self.createdAt = secret.createdAt
        self.updatedAt = secret.updatedAt
    }
}
