import Fluent
import Foundation
import StratoShared
import Vapor

/// `/api/projects/:projectID/registry-credentials`: per-project pull secrets
/// for private OCI registries (issue #414). Project-scoped like project
/// members: reads require `view_project`, mutations `manage_project` (SpiceDB,
/// via `OrganizationAccessService`). The secret value is write-only — it is
/// encrypted at rest and never appears in any response.
struct RegistryPullSecretController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let credentials = routes.grouped("api", "projects", ":projectID", "registry-credentials")
        credentials.get(use: list)
        credentials.post(use: create)
        credentials.put(":credentialID", use: update)
        credentials.delete(":credentialID", use: delete)
    }

    // MARK: - DTOs

    struct CreateRegistryPullSecretRequest: Content {
        /// Registry host, e.g. `ghcr.io` — normalized like image references,
        /// so `https://index.docker.io/` and `docker.io` are the same entry.
        let registry: String
        let username: String
        let secret: String
    }

    struct UpdateRegistryPullSecretRequest: Content {
        let username: String?
        /// Replacement secret. Omitted means keep the stored one — there is
        /// no way to read a secret back out through the API.
        let secret: String?
    }

    // MARK: - Handlers

    /// GET — every pull secret in the project (metadata only, no secrets).
    func list(req: Request) async throws -> [RegistryPullSecretResponse] {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        let secrets = try await RegistryPullSecret.query(on: req.db)
            .filter(\.$project.$id == project.requireID())
            .sort(\.$registry)
            .all()
        return secrets.map { RegistryPullSecretResponse(from: $0) }
    }

    /// POST — add a credential for a registry the project has none for yet.
    func create(req: Request) async throws -> Response {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let projectID = try project.requireID()

        let createRequest = try req.content.decode(CreateRegistryPullSecretRequest.self)
        let registry = try Self.normalizeRegistry(createRequest.registry)
        let username = createRequest.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw Abort(.badRequest, reason: "'username' must not be empty")
        }
        guard !createRequest.secret.isEmpty else {
            throw Abort(.badRequest, reason: "'secret' must not be empty")
        }

        let existing = try await RegistryPullSecret.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$registry == registry)
            .first()
        guard existing == nil else {
            throw Abort(
                .conflict,
                reason: "The project already has a credential for '\(registry)'; update or delete it instead")
        }

        let pullSecret = RegistryPullSecret(
            projectID: projectID,
            registry: registry,
            username: username,
            secret: try req.secretsEncryption.encrypt(createRequest.secret)
        )
        try await pullSecret.save(on: req.db)

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
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let pullSecret = try await loadSecret(req, in: project)

        let updateRequest = try req.content.decode(UpdateRegistryPullSecretRequest.self)
        if let username = updateRequest.username {
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw Abort(.badRequest, reason: "'username' must not be empty")
            }
            pullSecret.username = trimmed
        }
        if let secret = updateRequest.secret {
            guard !secret.isEmpty else {
                throw Abort(.badRequest, reason: "'secret' must not be empty")
            }
            pullSecret.secret = try req.secretsEncryption.encrypt(secret)
        }

        try await pullSecret.save(on: req.db)
        return RegistryPullSecretResponse(from: pullSecret)
    }

    /// DELETE — remove the credential. Sandboxes already pinned to a digest
    /// keep converging on it; their next pull simply becomes anonymous.
    func delete(req: Request) async throws -> HTTPStatus {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let pullSecret = try await loadSecret(req, in: project)

        try await pullSecret.delete(on: req.db)

        req.logger.info(
            "Registry pull secret deleted",
            metadata: [
                "project_id": .string(project.id?.uuidString ?? ""),
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

    private func loadProject(_ req: Request) async throws -> Project {
        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    private func loadSecret(_ req: Request, in project: Project) async throws -> RegistryPullSecret {
        guard let credentialID = req.parameters.get("credentialID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid credential ID")
        }
        guard
            let pullSecret = try await RegistryPullSecret.query(on: req.db)
                .filter(\.$id == credentialID)
                .filter(\.$project.$id == project.requireID())
                .first()
        else {
            throw Abort(.notFound, reason: "Registry credential not found")
        }
        return pullSecret
    }
}
