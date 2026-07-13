import Fluent
import Vapor

/// A project's pull credential for one OCI registry (issue #414). Sandboxes in
/// the project whose image lives on `registry` are pulled with it: the control
/// plane uses it to resolve tags to digests and to mint the short-lived
/// credential carried in `DesiredSandboxState` — the durable secret itself
/// never leaves the control plane.
///
/// Named distinctly from the wire-level `StratoShared.RegistryCredential`,
/// which is the short-lived material derived from this row at sync assembly.
final class RegistryPullSecret: Model, @unchecked Sendable {
    static let schema = "registry_pull_secrets"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "project_id")
    var project: Project

    /// Normalized registry host (optionally `host:port`), e.g. `ghcr.io`,
    /// `docker.io`, `registry.example.com:5000`. Matching against a sandbox's
    /// image uses `OCIImageReference.parse`'s normalization, so store the
    /// same canonical form. Unique per project — one credential per registry
    /// keeps matching deterministic.
    @Field(key: "registry")
    var registry: String

    @Field(key: "username")
    var username: String

    /// The password or long-lived token, encrypted at rest with
    /// `SecretsEncryptionService` (`enc:v1:` prefix) like OIDC client secrets.
    /// Always store through `req.secretsEncryption.encrypt`.
    @Field(key: "secret")
    var secret: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, projectID: UUID, registry: String, username: String, secret: String) {
        self.id = id
        self.$project.id = projectID
        self.registry = registry
        self.username = username
        self.secret = secret
    }
}

/// API shape for a pull secret. Deliberately has no secret field — the
/// credential is write-only through the API, like OIDC client secrets.
struct RegistryPullSecretResponse: Content {
    let id: UUID?
    let projectId: UUID?
    let registry: String
    let username: String
    let createdAt: Date?
    let updatedAt: Date?

    init(from secret: RegistryPullSecret) {
        self.id = secret.id
        self.projectId = secret.$project.id
        self.registry = secret.registry
        self.username = secret.username
        self.createdAt = secret.createdAt
        self.updatedAt = secret.updatedAt
    }
}
