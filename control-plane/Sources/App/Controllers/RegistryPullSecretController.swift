import Foundation
import ControlPlanePostgres
import StratoShared
import Vapor

/// `/api/projects/:projectID/registry-credentials`: per-project pull secrets
/// for private OCI registries (issue #414). Project-scoped like project
/// members: reads require `view_project`, mutations `iam:setPolicy` (via
/// `OrganizationAccessService`). The secret value is write-only — it is
/// encrypted at rest and never appears in any response.
struct RegistryPullSecretController: RouteCollection {
    let secrets: RegistryPullSecretsPersistence
    let projects: ProjectsPersistence

    func boot(routes: any RoutesBuilder) throws {
        let credentials = routes.grouped("api", "projects", ":projectID", "registry-credentials")
        credentials.get(use: list)
        credentials.post(use: create)
        credentials.put(":credentialID", use: update)
        credentials.delete(":credentialID", use: delete)
    }

    // MARK: - DTOs

    struct CreateRegistryPullSecretRequest: Content, ValidatedRequestBody {
        /// Registry host, e.g. `ghcr.io` — normalized like image references,
        /// so `https://index.docker.io/` and `docker.io` are the same entry.
        let registry: String
        var username: String
        let secret: String

        mutating func validate() throws {
            username = try Validate.name(username, "username")
            guard !secret.isEmpty else {
                throw Abort(.badRequest, reason: "'secret' must not be empty")
            }
            try Validate.text(secret, "secret")
        }
    }

    struct UpdateRegistryPullSecretRequest: Content, ValidatedRequestBody {
        var username: String?
        /// Replacement secret. Omitted means keep the stored one — there is
        /// no way to read a secret back out through the API.
        let secret: String?

        mutating func validate() throws {
            username = try Validate.name(username, "username")
            if let secret {
                guard !secret.isEmpty else {
                    throw Abort(.badRequest, reason: "'secret' must not be empty")
                }
                try Validate.text(secret, "secret")
            }
        }
    }

    // MARK: - Handlers

    /// GET — every pull secret in the project (metadata only, no secrets).
    func list(req: Request) async throws -> [RegistryPullSecretResponse] {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectMember(projectID: project.id, on: req)

        return try await secrets.secrets(projectID: project.id)
            .map(RegistryPullSecretResponse.init(from:))
    }

    /// POST — add a credential for a registry the project has none for yet.
    func create(req: Request) async throws -> Response {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let projectID = project.id

        let createRequest = try req.content.decodeValidated(CreateRegistryPullSecretRequest.self)
        let registry = try Self.normalizeRegistry(createRequest.registry)

        let pullSecret: RegistryPullSecretSnapshot
        do {
            pullSecret = try await secrets.create(
                RegistryPullSecretWrite(
                    projectID: projectID,
                    registry: registry,
                    username: createRequest.username,
                    encryptedSecret: try req.secretsEncryption.encrypt(createRequest.secret)
                )
            )
        } catch RegistryPullSecretPersistenceError.duplicateRegistry {
            throw Abort(
                .conflict,
                reason: "The project already has a credential for '\(registry)'; update or delete it instead")
        }

        req.logger.info(
            "Registry pull secret created",
            metadata: [
                "project_id": .string(projectID.uuidString),
                "registry": .string(registry),
            ])

        let response = Response(status: .created)
        try response.content.encode(RegistryPullSecretResponse(from: pullSecret))
        return response
    }

    /// PUT — rotate the username and/or secret. The registry host is
    /// immutable: pointing a credential at a different registry is a
    /// delete-and-create, not an edit.
    func update(req: Request) async throws -> RegistryPullSecretResponse {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let pullSecret = try await loadSecret(req, in: project)

        let updateRequest = try req.content.decodeValidated(UpdateRegistryPullSecretRequest.self)
        guard
            let updated = try await secrets.update(
                id: pullSecret.id,
                projectID: project.id,
                username: updateRequest.username,
                encryptedSecret: try updateRequest.secret.map(req.secretsEncryption.encrypt)
            )
        else {
            throw Abort(.notFound, reason: "Registry credential not found")
        }
        return RegistryPullSecretResponse(from: updated)
    }

    /// DELETE — remove the credential. Sandboxes already pinned to a digest
    /// keep converging on it; their next pull simply becomes anonymous.
    func delete(req: Request) async throws -> HTTPStatus {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let pullSecret = try await loadSecret(req, in: project)

        guard try await secrets.delete(id: pullSecret.id, projectID: project.id) != nil else {
            throw Abort(.notFound, reason: "Registry credential not found")
        }

        req.logger.info(
            "Registry pull secret deleted",
            metadata: [
                "project_id": .string(project.id.uuidString),
                "registry": .string(pullSecret.registry),
            ])
        return .noContent
    }

    // MARK: - Helpers

    /// Canonicalizes a user-supplied registry host to the form
    /// `OCIImageReference.parse` produces for image references, so matching at
    /// sync assembly is a plain string compare: lowercased bare host (with
    /// optional port), scheme and path stripped, Docker Hub aliases collapsed
    /// to `docker.io`.
    static func normalizeRegistry(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        if host == "index.docker.io" || host == "registry-1.docker.io" {
            host = "docker.io"
        }
        guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw Abort(.badRequest, reason: "'registry' must be a registry host like 'ghcr.io'")
        }
        return host
    }

    private func requireProject(_ req: Request) async throws -> ProjectSnapshot {
        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        guard let project = try await projects.project(id: projectID) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    private func loadSecret(
        _ req: Request,
        in project: ProjectSnapshot
    ) async throws -> RegistryPullSecretSnapshot {
        guard let credentialID = req.parameters.get("credentialID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid credential ID")
        }
        guard let pullSecret = try await secrets.secret(id: credentialID, projectID: project.id) else {
            throw Abort(.notFound, reason: "Registry credential not found")
        }
        return pullSecret
    }
}
