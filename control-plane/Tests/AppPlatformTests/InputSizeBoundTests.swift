import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// STR-195: caller-supplied text and list inputs are bounded.
///
/// Before this, `Validate`'s ceilings existed only as a habit applied to about
/// a dozen fields, and the ones nobody had thought of were the core workload
/// resources — every `name` and `description` on VMs, volumes, networks and the
/// org hierarchy. No column limited length either (`.string` is Postgres
/// `TEXT`), so the only ceiling in the whole path was Vapor's 16 MB default
/// body size: a single authenticated `POST /api/vms` could persist a ~16 MB
/// name.
///
/// These tests pin all three layers — the helper's arithmetic, the request
/// boundary at-limit and one-past-limit, and the database constraint that
/// backstops both.
@Suite("Input Size Bound Tests", .serialized)
final class InputSizeBoundTests {

    /// A valid `ssh-ed25519` authorized_keys line: the algorithm name appears
    /// both in front of the blob and length-prefixed inside it, which is what
    /// `Validate.sshPublicKey` cross-checks.
    static let validSSHKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f strato@test"

    private func string(_ count: Int, _ character: Character = "a") -> String {
        String(repeating: character, count: count)
    }

    private func expectBoundary<Body: ValidatedRequestBody>(
        _ limit: Int, make: (String) throws -> Body
    ) throws {
        var atLimit = try make(string(limit))
        try atLimit.validate()

        var overLimit = try make(string(limit + 1))
        let error = #expect(throws: Abort.self) { try overLimit.validate() }
        #expect(error?.status == .badRequest)
    }

    // MARK: - The helper

    @Test("A name at the ceiling is accepted; one character past it is not")
    func nameCeiling() throws {
        let atLimit = string(Validate.nameLength)
        #expect(try Validate.name(atLimit) == atLimit)

        let overLimit = string(Validate.nameLength + 1)
        let error = #expect(throws: Abort.self) { try Validate.name(overLimit) }
        #expect(error?.status == .badRequest)
    }

    @Test("Free text is bounded at its own, larger ceiling")
    func textCeiling() throws {
        #expect(try Validate.text(string(Validate.textLength)) != nil)
        let error = #expect(throws: Abort.self) {
            try Validate.text(string(Validate.textLength + 1))
        }
        #expect(error?.status == .badRequest)
    }

    @Test("A name is trimmed before it is measured, and whitespace alone is empty")
    func nameNormalization() throws {
        #expect(try Validate.name("  spaced  ") == "spaced")
        // Trimming happens first, so a value that only fits after the trim fits.
        #expect(try Validate.name("  " + string(Validate.nameLength) + "  ").count == Validate.nameLength)
        #expect(throws: Abort.self) { try Validate.name("   ") }
        #expect(throws: Abort.self) { try Validate.name("") }
    }

    @Test("An absent optional name stays absent rather than becoming empty")
    func optionalNamePassesThroughNil() throws {
        #expect(try Validate.name(String?.none) == nil)
        #expect(try Validate.text(nil) == nil)
    }

    /// The bound is counted in Unicode scalars because that is what Postgres's
    /// `char_length` counts. Measuring in grapheme clusters instead would let a
    /// string past the API that the column constraint then refuses — a `500`
    /// where the caller earned a `400`.
    @Test("Length is measured the way the database measures it")
    func lengthMatchesPostgresCharLength() throws {
        // One grapheme cluster, two scalars: 'e' + combining acute accent.
        let combining = "e\u{0301}"
        #expect(combining.count == 1)
        #expect(Validate.length(combining) == 2)

        let atGraphemeLimit = String(repeating: combining, count: Validate.nameLength)
        #expect(throws: Abort.self) { try Validate.name(atGraphemeLimit) }
    }

    @Test("A list is bounded by cardinality")
    func listCeiling() throws {
        try Validate.list(Array(repeating: 1, count: 5), "ids", max: 5)
        let error = #expect(throws: Abort.self) {
            try Validate.list(Array(repeating: 1, count: 6), "ids", max: 5)
        }
        #expect(error?.status == .badRequest)
    }

    @Test("A string list is bounded in both dimensions")
    func stringListCeilings() throws {
        try Validate.stringList(["a", "b"], "args", maxEntries: 2, maxLength: 4)
        #expect(throws: Abort.self) {
            try Validate.stringList(["a", "b", "c"], "args", maxEntries: 2, maxLength: 4)
        }
        #expect(throws: Abort.self) {
            try Validate.stringList(["aaaaa"], "args", maxEntries: 2, maxLength: 4)
        }
    }

    @Test("A string map is bounded in count, key length and value length")
    func stringMapCeilings() throws {
        try Validate.stringMap(["k": "v"], "env", maxEntries: 1, maxKeyLength: 2, maxValueLength: 2)
        #expect(throws: Abort.self) {
            try Validate.stringMap(["k": "v", "j": "w"], "env", maxEntries: 1)
        }
        #expect(throws: Abort.self) {
            try Validate.stringMap(["kkk": "v"], "env", maxEntries: 1, maxKeyLength: 2)
        }
        #expect(throws: Abort.self) {
            try Validate.stringMap(["k": "vvv"], "env", maxEntries: 1, maxValueLength: 2)
        }
    }

    // MARK: - SSH public keys

    @Test("A well-formed SSH key is accepted and returned trimmed")
    func sshKeyAccepted() throws {
        #expect(try Validate.sshPublicKey("  \(Self.validSSHKey)  ") == Self.validSSHKey)
        // Empty means "no key requested", not "an empty key".
        #expect(try Validate.sshPublicKey("   ") == nil)
        #expect(try Validate.sshPublicKey(nil) == nil)
    }

    @Test(
        "Malformed SSH keys are refused before they can reach the guest",
        arguments: [
            // Two keys pasted together: the agent's sink strips the newline,
            // silently merging them into one unusable entry.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f\nssh-ed25519 AAAA",
            // authorized_keys options prefix — not ours to accept.
            "command=\"/bin/false\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            // Unknown algorithm.
            "ssh-nonsense AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            // Algorithm inside the blob disagrees with the one in front of it.
            "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f",
            // Not base64 at all.
            "ssh-ed25519 not-base-64!!",
            // No blob.
            "ssh-ed25519",
        ]
    )
    func sshKeyRejected(candidate: String) throws {
        let error = #expect(throws: Abort.self) { try Validate.sshPublicKey(candidate) }
        #expect(error?.status == .badRequest)
    }

    /// OpenSSH treats any whitespace as a field separator. A tab is accepted
    /// and then *canonicalized to a space*, because the agent's sink strips
    /// control characters — a stored tab would be deleted there, welding the
    /// type onto the blob in the guest's `authorized_keys`.
    @Test("A tab-separated key is accepted and stored space-separated")
    func sshKeyAcceptsTabSeparator() throws {
        let tabbed = Self.validSSHKey.replacingOccurrences(of: " ", with: "\t")
        #expect(try Validate.sshPublicKey(tabbed) == Self.validSSHKey)
    }

    /// CA-based fleets install certificates, not bare keys. The blob opens with
    /// its own algorithm name, so the cross-check works unchanged.
    @Test("Certificate key types are accepted")
    func sshKeyAcceptsCertificateTypes() throws {
        let type = "ssh-ed25519-cert-v01@openssh.com"
        // A blob whose length-prefixed algorithm name is the certificate type.
        var blob = Data()
        let name = Array(type.utf8)
        blob.append(contentsOf: [
            UInt8((name.count >> 24) & 0xff), UInt8((name.count >> 16) & 0xff),
            UInt8((name.count >> 8) & 0xff), UInt8(name.count & 0xff),
        ])
        blob.append(contentsOf: name)
        blob.append(contentsOf: [UInt8](repeating: 0, count: 32))

        let line = "\(type) \(blob.base64EncodedString()) admin@ca"
        #expect(try Validate.sshPublicKey(line) == line)
    }

    @Test("The unsupported-type message names the certificate forms it accepts")
    func sshKeyErrorMentionsCertificateForms() throws {
        let error = #expect(throws: Abort.self) {
            try Validate.sshPublicKey("ssh-dss AAAAB3NzaC1kc3M=")
        }
        #expect(error?.reason.contains("-cert-v01@openssh.com") == true)
    }

    // MARK: - Endpoints

    @Test("Administrative name DTOs share the 128-character boundary")
    func administrativeNameDTOCeilings() throws {
        let id = UUID()
        try expectBoundary(Validate.nameLength) {
            PolicyController.CreatePolicyRequest(
                name: $0, description: nil, ownerType: .organization, ownerId: id,
                cedarText: "forbid(principal, action, resource);", enabled: nil, id: nil)
        }
        try expectBoundary(Validate.nameLength) {
            PolicyController.UpdatePolicyRequest(name: $0, description: nil, cedarText: nil, enabled: nil)
        }
        try expectBoundary(Validate.nameLength) {
            RoleController.CreateRoleRequest(
                name: $0, description: nil, ownerType: .organization, ownerId: id,
                actions: ["vm:read"], cedarText: nil, id: nil)
        }
        try expectBoundary(Validate.nameLength) {
            RoleController.UpdateRoleRequest(name: $0, description: nil, actions: nil, cedarText: nil)
        }
        try expectBoundary(Validate.nameLength) {
            GuardrailController.CreateGuardrailRequest(
                name: $0, description: nil, effect: nil, nodeType: "organization",
                nodeId: id.uuidString, actions: [], principalMatch: nil, resourceMatch: nil,
                cedarText: nil, enabled: nil)
        }
        try expectBoundary(Validate.nameLength) {
            CreateSCIMTokenRequest(name: $0, expiresInDays: nil)
        }
        try expectBoundary(Validate.nameLength) {
            UpdateSCIMTokenRequest(name: $0, isActive: nil)
        }
        try expectBoundary(Validate.nameLength) {
            CreateSSFStreamRequest(
                name: $0, description: nil, transmitterURL: "https://example.com",
                authToken: nil, expectedIssuer: nil, expectedAudience: nil,
                deliveryMethod: .push, eventsRequested: nil)
        }
        try expectBoundary(Validate.nameLength) {
            UpdateSSFStreamRequest(
                name: $0, description: nil, authToken: nil, expectedIssuer: nil,
                expectedAudience: nil, eventsRequested: nil, enabled: nil)
        }
        try expectBoundary(Validate.nameLength) { value in
            try JSONDecoder().decode(
                CreateAPIKeyRequest.self, from: Data("{\"name\":\"\(value)\"}".utf8))
        }
        try expectBoundary(Validate.nameLength) { value in
            try JSONDecoder().decode(
                UpdateAPIKeyRequest.self, from: Data("{\"name\":\"\(value)\"}".utf8))
        }
        try expectBoundary(Validate.nameLength) {
            CreateWebhookSubscriptionRequest(
                name: $0, url: "https://example.com/hook", projectId: nil, eventTypes: nil)
        }
        try expectBoundary(Validate.nameLength) {
            UpdateWebhookSubscriptionRequest(name: $0, url: nil, eventTypes: nil, isActive: nil)
        }
        try expectBoundary(Validate.nameLength) {
            RegistryPullSecretController.CreateRegistryPullSecretRequest(
                registry: "ghcr.io", username: $0, secret: "secret")
        }
        try expectBoundary(Validate.nameLength) {
            RegistryPullSecretController.UpdateRegistryPullSecretRequest(username: $0, secret: nil)
        }
        try expectBoundary(Validate.nameLength) {
            ServiceAccountController.CreateServiceAccountRequest(name: $0, description: nil)
        }
        try expectBoundary(Validate.nameLength) {
            WorkloadRegistrationController.CreateWorkloadRegistrationRequest(
                spiffeId: "spiffe://example.com/workload", organizationId: id, displayName: $0)
        }
        try expectBoundary(Validate.nameLength) {
            CreateSiteRequest(name: $0, organizationId: id)
        }
        try expectBoundary(Validate.nameLength) {
            CreateLoadBalancerRequest(
                name: $0, projectId: id, logicalNetworkId: id, protocol: .tcp,
                healthCheck: nil)
        }
        try expectBoundary(Validate.nameLength) {
            UpdateLoadBalancerRequest(name: $0, protocol: nil, healthCheck: nil)
        }
        try expectBoundary(Validate.nameLength) {
            CreateFloatingIPPoolRequest(
                name: $0, cidr: "203.0.113.0/24", gateway: nil, siteId: id,
                organizationId: id, organizationalUnitId: nil)
        }
    }

    @Test("Administrative free-text DTOs share the 4096-character boundary")
    func administrativeTextDTOCeilings() throws {
        let id = UUID()
        try expectBoundary(Validate.textLength) {
            PolicyController.CreatePolicyRequest(
                name: "policy", description: $0, ownerType: .organization, ownerId: id,
                cedarText: "forbid(principal, action, resource);", enabled: nil, id: nil)
        }
        try expectBoundary(Validate.textLength) {
            PolicyController.UpdatePolicyRequest(name: nil, description: $0, cedarText: nil, enabled: nil)
        }
        try expectBoundary(Validate.textLength) {
            RoleController.CreateRoleRequest(
                name: "role", description: $0, ownerType: .organization, ownerId: id,
                actions: ["vm:read"], cedarText: nil, id: nil)
        }
        try expectBoundary(Validate.textLength) {
            RoleController.UpdateRoleRequest(name: nil, description: $0, actions: nil, cedarText: nil)
        }
        try expectBoundary(Validate.textLength) {
            GuardrailController.CreateGuardrailRequest(
                name: "guardrail", description: $0, effect: nil, nodeType: "organization",
                nodeId: id.uuidString, actions: [], principalMatch: nil, resourceMatch: nil,
                cedarText: nil, enabled: nil)
        }
        try expectBoundary(Validate.textLength) {
            GuardrailController.UpdateGuardrailRequest(
                description: $0, actions: nil, principalMatch: nil, resourceMatch: nil,
                cedarText: nil, enabled: nil)
        }
        try expectBoundary(Validate.textLength) {
            CreateSSFStreamRequest(
                name: "stream", description: $0, transmitterURL: "https://example.com",
                authToken: nil, expectedIssuer: nil, expectedAudience: nil,
                deliveryMethod: .push, eventsRequested: nil)
        }
        try expectBoundary(Validate.textLength) {
            UpdateSSFStreamRequest(
                name: nil, description: $0, authToken: nil, expectedIssuer: nil,
                expectedAudience: nil, eventsRequested: nil, enabled: nil)
        }
        try expectBoundary(Validate.textLength) {
            CreateSSFStreamRequest(
                name: "stream", description: nil, transmitterURL: "https://example.com",
                authToken: nil, expectedIssuer: $0, expectedAudience: nil,
                deliveryMethod: .push, eventsRequested: nil)
        }
        try expectBoundary(Validate.textLength) {
            RegistryPullSecretController.CreateRegistryPullSecretRequest(
                registry: "ghcr.io", username: "user", secret: $0)
        }
        try expectBoundary(Validate.textLength) {
            RegistryPullSecretController.UpdateRegistryPullSecretRequest(username: nil, secret: $0)
        }
        try expectBoundary(Validate.textLength) {
            ServiceAccountController.CreateServiceAccountRequest(name: "account", description: $0)
        }
        try expectBoundary(Validate.textLength) {
            ServiceAccountController.UpdateServiceAccountRequest(description: $0)
        }
        try expectBoundary(Validate.textLength) {
            CreateSiteRequest(name: "site", description: $0, organizationId: id)
        }
        try expectBoundary(Validate.textLength) {
            UpdateSiteRequest(description: $0)
        }
        try expectBoundary(Validate.textLength) {
            CreateSecurityGroupRuleRequest(
                direction: .ingress, ethertype: .ipv4, description: $0)
        }
    }

    private func withApp(
        _ test: (Application, User, Project, Image, String) async throws -> Void
    ) async throws {
        try await withApp { app, user, _, project, image, token in
            try await test(app, user, project, image, token)
        }
    }

    private func withApp(
        _ test: (Application, User, Organization, Project, Image, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "bounduser", email: "bound@example.com")
            let org = try await builder.createOrganization(name: "Bound Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .organization, nodeID: org.id!, createdBy: nil, on: app.testPostgres)
            try await user.replacingCurrentOrganization(org.id).save(on: app.testPostgres)

            let project = try await builder.createProject(
                name: "Bound Project", description: "p", organization: org)
            try await builder.createNetwork(name: "default", project: project)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let token = try await user.generateAPIKey(on: app)

            try await test(app, user, org, project, image, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("IAM writes reject empty and oversized names before PostgreSQL")
    func iamWriteBoundaries() async throws {
        try await withApp { app, _, org, _, _, token in
            app.guardrailAnalyzer = PermissiveGuardrailAnalyzer()
            let orgID = try org.requireID()
            let cedarText =
                """
                forbid (
                    principal,
                    action,
                    resource in Organization::"\(orgID.uuidString.lowercased())"
                );
                """

            func post<Body: Content>(_ path: String, _ body: Body) async throws -> HTTPStatus {
                var status = HTTPStatus.internalServerError
                try await app.test(.POST, path) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(body)
                } afterResponse: { res in
                    status = res.status
                }
                return status
            }

            func policy(_ name: String, description: String? = nil) -> PolicyController.CreatePolicyRequest {
                PolicyController.CreatePolicyRequest(
                    name: name, description: description, ownerType: .organization,
                    ownerId: orgID, cedarText: cedarText, enabled: nil, id: nil)
            }
            func role(_ name: String, description: String? = nil) -> RoleController.CreateRoleRequest {
                RoleController.CreateRoleRequest(
                    name: name, description: description, ownerType: .organization,
                    ownerId: orgID, actions: ["vm:read"], cedarText: nil, id: nil)
            }
            func guardrail(
                _ name: String, description: String? = nil
            ) -> GuardrailController.CreateGuardrailRequest {
                GuardrailController.CreateGuardrailRequest(
                    name: name, description: description, effect: nil,
                    nodeType: "organization", nodeId: orgID.uuidString,
                    actions: ["vm:delete"], principalMatch: nil, resourceMatch: nil,
                    cedarText: nil, enabled: nil)
            }

            #expect(
                try await post(
                    "/api/iam/policies", policy(self.string(Validate.nameLength)))
                    == .created)
            #expect(
                try await post(
                    "/api/iam/policies", policy(self.string(Validate.nameLength + 1)))
                    == .badRequest)
            #expect(try await post("/api/iam/policies", policy("   ")) == .badRequest)
            #expect(
                try await post("/api/iam/policies", policy(self.string(4_000)))
                    == .badRequest)
            #expect(
                try await post(
                    "/api/iam/policies",
                    policy("policy-description-at-limit", description: self.string(Validate.textLength)))
                    == .created)
            #expect(
                try await post(
                    "/api/iam/policies",
                    policy("policy-description-over-limit", description: self.string(Validate.textLength + 1)))
                    == .badRequest)

            #expect(
                try await post(
                    "/api/iam/roles", role(self.string(Validate.nameLength)))
                    == .created)
            #expect(
                try await post(
                    "/api/iam/roles", role(self.string(Validate.nameLength + 1)))
                    == .badRequest)
            #expect(try await post("/api/iam/roles", role("")) == .badRequest)
            #expect(
                try await post(
                    "/api/iam/roles",
                    role("role-description-at-limit", description: self.string(Validate.textLength)))
                    == .created)
            #expect(
                try await post(
                    "/api/iam/roles",
                    role("role-description-over-limit", description: self.string(Validate.textLength + 1)))
                    == .badRequest)

            #expect(
                try await post(
                    "/api/iam/guardrails", guardrail(self.string(Validate.nameLength)))
                    == .created)
            #expect(
                try await post(
                    "/api/iam/guardrails", guardrail(self.string(Validate.nameLength + 1)))
                    == .badRequest)
            #expect(try await post("/api/iam/guardrails", guardrail("   ")) == .badRequest)
            #expect(
                try await post(
                    "/api/iam/guardrails",
                    guardrail("guardrail-description-at-limit", description: self.string(Validate.textLength)))
                    == .created)
            #expect(
                try await post(
                    "/api/iam/guardrails",
                    guardrail(
                        "guardrail-description-over-limit",
                        description: self.string(Validate.textLength + 1)))
                    == .badRequest)

            #expect(try await PolicyStore.count(on: app.testPostgres) == 2)
            #expect(try await RoleStore.legacyRoleCount(managed: false, on: app.testPostgres) == 2)
            #expect(try await LegacyGuardrailStore.count(on: app.testPostgres) == 2)
        }
    }

    /// Mirrors `VMController`'s private `CreateVMRequest` closely enough to
    /// exercise the fields under test.
    private struct CreateVMBody: Content {
        var name: String
        var imageId: UUID?
        var projectId: UUID?
        var environment: String? = "development"
        var cpu: Int? = 1
        var memory: Int64? = 1024 * 1024 * 1024
        var disk: Int64? = 10 * 1024 * 1024 * 1024
        var networkName: String? = "default"
        var description: String? = nil
        var sshPublicKey: String? = nil
        var securityGroupIds: [UUID]? = nil
    }

    @Test("POST /api/vms accepts a name at the ceiling and refuses one past it")
    func vmNameCeiling() async throws {
        try await withApp { app, _, project, image, token in
            let atLimit = self.string(Validate.nameLength)
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(name: atLimit, imageId: image.id, projectId: project.id))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: self.string(Validate.nameLength + 1), imageId: image.id,
                        projectId: project.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Only the accepted create left a row.
            let names = try await LegacyVMStore.vms(on: app.testPostgres).map(\.name)
            #expect(names == [atLimit])
        }
    }

    @Test("POST /api/vms refuses an oversized description and SSH key")
    func vmTextCeilings() async throws {
        try await withApp { app, _, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "described", imageId: image.id, projectId: project.id,
                        description: self.string(Validate.textLength + 1)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "keyed", imageId: image.id, projectId: project.id,
                        sshPublicKey: "ssh-ed25519 " + self.string(Validate.textLength)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let vmCount = try await LegacyVMStore.vms(on: app.testPostgres).count
            #expect(vmCount == 0)
        }
    }

    @Test("POST /api/vms stores a valid SSH key verbatim after trimming")
    func vmAcceptsValidSSHKey() async throws {
        try await withApp { app, _, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "keyed-vm", imageId: image.id, projectId: project.id,
                        sshPublicKey: "  \(Self.validSSHKey)\n"))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let vm = try await LegacyVMStore.vms(name: "keyed-vm", on: app.testPostgres).first
            #expect(vm?.sshPublicKey == Self.validSSHKey)
        }
    }

    /// The list is now bounded as sent, not only after
    /// `SecurityGroupService.resolveRequestedGroupIDs` deduplicates it — that
    /// dedupe is O(n²), so it was work performed *before* the cap was checked.
    /// Duplicates count toward the ceiling for the same reason.
    @Test("POST /api/vms refuses more security groups than a NIC may hold")
    func vmSecurityGroupCardinality() async throws {
        try await withApp { app, _, project, image, token in
            let overLimit = SecurityGroup.maxGroupsPerNIC + 1
            let distinct = (0..<overLimit).map { _ in UUID() }
            let duplicated = Array(repeating: UUID(), count: overLimit)

            for ids in [distinct, duplicated] {
                try await app.test(.POST, "/api/vms") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateVMBody(
                            name: "sg-vm", imageId: image.id, projectId: project.id,
                            securityGroupIds: ids))
                } afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            }

            let vmCount = try await LegacyVMStore.vms(on: app.testPostgres).count
            #expect(vmCount == 0)
        }
    }

    @Test("PUT /api/vms/:id holds a rename to the same ceiling as create")
    func vmUpdateNameCeiling() async throws {
        try await withApp { app, user, project, _, token in
            let vm = try await TestDataBuilder(db: app.testPostgres).createVM(
                name: "renameable", project: project)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .virtualMachine, nodeID: vm.id!, createdBy: user.id, on: app.testPostgres)

            struct UpdateBody: Content { let name: String }
            try await app.test(.PUT, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateBody(name: self.string(Validate.nameLength + 1)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let reloaded = try await VM.find(vm.id!, on: app.testPostgres)
            #expect(reloaded?.name == "renameable")
        }
    }

    /// The regression this issue's "why it matters" section is about:
    /// `LogicalNetwork.name` rides `DesiredNetworkState.name` to the topology
    /// authority, which writes it into OVN NB `DHCP_Options.external_ids` via
    /// `DHCPOptions.externalIDs(networkId:networkName:)` — and then reads those
    /// same `external_ids` back to decide which DHCP rows the network owns. The
    /// name has to be refused at the API, because past it there is nothing
    /// between the string and an identity key in the datapath's control database.
    @Test("POST /api/networks refuses an oversized name before it can reach OVSDB")
    func networkNameNeverReachesOVSDB() async throws {
        try await withApp { app, _, _, project, _, token in
            let siteID = try await TestDataBuilder(db: app.testPostgres).placementSite(for: project).requireID()
            let oversized = self.string(Validate.nameLength + 1)
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: oversized, subnet: "10.77.0.0/24", projectId: project.id,
                        siteId: siteID))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Nothing was persisted, so nothing can be assembled into a sync,
            // which is the only way a name reaches an agent at all.
            let persisted = try await LogicalNetwork.all(on: app.testPostgres).map(\.name)
            #expect(persisted == ["default"])
        }
    }

    @Test("POST /api/security-groups refuses an oversized name")
    func securityGroupNameCeiling() async throws {
        try await withApp { app, _, project, _, token in
            try await app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSecurityGroupRequest(
                        name: self.string(Validate.nameLength + 1), projectId: project.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST /api/volumes refuses an oversized name and an oversized description")
    func volumeCeilings() async throws {
        try await withApp { app, _, project, _, token in
            func post(name: String, description: String?) async throws -> HTTPStatus {
                var status: HTTPStatus = .ok
                try await app.test(.POST, "/api/volumes") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateVolumeRequest(
                            name: name, description: description, projectId: project.id, environment: nil,
                            sizeGB: 1, format: "qcow2", volumeType: "data", sourceImageId: nil,
                            iopsTotal: nil, bpsTotal: nil))
                } afterResponse: { res in
                    status = res.status
                }
                return status
            }

            let oversizedName = try await post(
                name: self.string(Validate.nameLength + 1), description: nil)
            #expect(oversizedName == .badRequest)
            let oversizedDescription = try await post(
                name: "ok", description: self.string(Validate.textLength + 1))
            #expect(oversizedDescription == .badRequest)
            let volumeCount = try await LegacyVolumeStore.volumes(on: app.testPostgres).count
            #expect(volumeCount == 0)
        }
    }

    // MARK: - DNS (STR-198)

    /// A syntactically valid domain name of exactly `DNSName.maxNameLength`
    /// characters: three 63-character labels and a 61-character one, plus the
    /// three dots between them. The ceiling has to be reachable by something
    /// the *grammar* also accepts, or the at-limit half of these tests would
    /// only ever prove that `normalizedZoneName` refuses gibberish.
    private var maximalDNSName: String {
        let labels = [63, 63, 63, 61].map { string($0) }
        return labels.joined(separator: ".")
    }

    private func postZone(
        _ app: Application, _ token: String, _ project: Project,
        name: String, description: String? = nil
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .ok
        try await app.test(.POST, "/api/dns-zones") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                CreateDNSZoneRequest(name: name, description: description, projectId: project.id))
        } afterResponse: { res in
            status = res.status
        }
        return status
    }

    private func postRecord(
        _ app: Application, _ token: String, zone: UUID,
        name: String?, type: DNSRecordType, value: String
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .ok
        try await app.test(.POST, "/api/dns-zones/\(zone)/records") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(CreateDNSRecordRequest(name: name, type: type, value: value))
        } afterResponse: { res in
            status = res.status
        }
        return status
    }

    /// The ceiling is `DNSName.maxNameLength`, not `Validate.nameLength`: RFC
    /// 1035 permits 253 characters and `normalizedZoneName` has always accepted
    /// them, so holding a zone to 128 would refuse names that work today. What
    /// the DTO adds is that the bound is applied at decode rather than after a
    /// megabyte of name has been lowercased and split into labels.
    @Test("POST /api/dns-zones accepts a name at the DNS ceiling and refuses one past it")
    func dnsZoneNameCeiling() async throws {
        try await withApp { app, _, project, _, token in
            let atLimit = self.maximalDNSName
            #expect(atLimit.count == DNSName.maxNameLength)
            #expect(try await self.postZone(app, token, project, name: atLimit) == .ok)

            // One character past, still valid syntax otherwise — the extra
            // character lands in the trailing 61-character label, so nothing
            // but the total length can be what refuses it.
            let overLimit = atLimit + "a"
            #expect(overLimit.count == DNSName.maxNameLength + 1)
            #expect(try await self.postZone(app, token, project, name: overLimit) == .badRequest)

            // And the shape the bound is actually there for.
            #expect(
                try await self.postZone(app, token, project, name: self.string(100_000))
                    == .badRequest)

            let names = try await LegacyDNSZoneStore.zones(on: app.testPostgres).map(\.name)
            #expect(names == [atLimit])
        }
    }

    /// The field with no grammar and, before this, no bound at all.
    @Test("POST /api/dns-zones accepts a description at the ceiling and refuses one past it")
    func dnsZoneDescriptionCeiling() async throws {
        try await withApp { app, _, project, _, token in
            let status = try await self.postZone(
                app, token, project, name: "described.internal",
                description: self.string(Validate.textLength))
            #expect(status == .ok)

            let overLimit = try await self.postZone(
                app, token, project, name: "over.internal",
                description: self.string(Validate.textLength + 1))
            #expect(overLimit == .badRequest)

            let names = try await LegacyDNSZoneStore.zones(on: app.testPostgres).map(\.name)
            #expect(names == ["described.internal"])
        }
    }

    @Test("POST /api/dns-zones/:id/records bounds the owner name at the DNS ceiling")
    func dnsRecordNameCeiling() async throws {
        try await withApp { app, _, project, _, token in
            #expect(try await self.postZone(app, token, project, name: "records.internal") == .ok)
            let zoneID = try #require(try await LegacyDNSZoneStore.zones(on: app.testPostgres).first?.id)

            let atLimit = self.maximalDNSName
            #expect(
                try await self.postRecord(
                    app, token, zone: zoneID, name: atLimit, type: .a, value: "10.9.0.1") == .ok)
            #expect(
                try await self.postRecord(
                    app, token, zone: zoneID, name: self.string(100_000), type: .a,
                    value: "10.9.0.2") == .badRequest)

            let stored = try await LegacyDNSRecordStore.records(
                zoneID: zoneID, on: app.testPostgres).map(\.name)
            #expect(stored == [atLimit])
        }
    }

    /// An empty owner name means the apex, the same as `@`. The record DTO
    /// therefore bounds its name rather than requiring it non-empty — a
    /// "required name" guard here would turn a documented spelling into a 400.
    @Test("An empty record name still means the zone apex")
    func dnsRecordEmptyNameIsApex() async throws {
        try await withApp { app, _, project, _, token in
            #expect(try await self.postZone(app, token, project, name: "apex.internal") == .ok)
            let zoneID = try #require(try await LegacyDNSZoneStore.zones(on: app.testPostgres).first?.id)

            #expect(
                try await self.postRecord(app, token, zone: zoneID, name: "", type: .a, value: "10.9.0.1")
                    == .ok)
            let record = try #require(
                try await LegacyDNSRecordStore.records(zoneID: zoneID, on: app.testPostgres).first)
            #expect(record.name == DNSName.apex)
        }
    }

    /// A record's value is bounded by its *type's* grammar, which is tighter
    /// than any generic ceiling — 255 bytes for TXT. What this pins is that the
    /// bound is on both write paths, not only on create: `value` is the one
    /// field an update can change, so an update that skipped the check would
    /// leave the create-side bound decorative.
    @Test("A record's value is bounded on create and on update alike")
    func dnsRecordValueCeiling() async throws {
        try await withApp { app, _, project, _, token in
            #expect(try await self.postZone(app, token, project, name: "txt.internal") == .ok)
            let zoneID = try #require(try await LegacyDNSZoneStore.zones(on: app.testPostgres).first?.id)

            let atLimit = self.string(255)
            #expect(
                try await self.postRecord(
                    app, token, zone: zoneID, name: "note", type: .txt, value: atLimit) == .ok)
            #expect(
                try await self.postRecord(
                    app, token, zone: zoneID, name: "big", type: .txt, value: self.string(256))
                    == .badRequest)
            #expect(
                try await self.postRecord(
                    app, token, zone: zoneID, name: "huge", type: .txt,
                    value: self.string(Validate.textLength + 1)) == .badRequest)

            let record = try #require(
                try await LegacyDNSRecordStore.records(zoneID: zoneID, on: app.testPostgres).first)
            for oversized in [self.string(256), self.string(Validate.textLength + 1)] {
                try await app.test(.PUT, "/api/dns-zones/\(zoneID)/records/\(record.id)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(UpdateDNSRecordRequest(value: oversized))
                } afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            }

            let reloaded = try #require(
                try await LegacyDNSRecordStore.record(id: record.id, on: app.testPostgres))
            #expect(reloaded.value == atLimit)
        }
    }

    /// The regression this issue is about, in the shape STR-40 gave it: a zone
    /// name is not a label in the database, it is realized. `DNSZoneAssembler`
    /// renders it into every FQDN in the zone, the topology authority writes
    /// those rows into the OVN `DNS` table referenced from
    /// `Logical_Switch.dns_records`, and a per-network CoreDNS serves them.
    /// A refused rename must leave the realized name exactly as it was — a
    /// half-applied one would be a name in OVSDB nothing in the API can name.
    @Test("An oversized zone name never reaches the zone an agent realizes")
    func dnsZoneNameNeverReachesOVSDB() async throws {
        try await withApp { app, _, project, _, token in
            #expect(try await self.postZone(app, token, project, name: "acme.internal") == .ok)
            let zone = try #require(try await LegacyDNSZoneStore.zones(on: app.testPostgres).first)
            let zoneID = zone.id
            let network = try #require(
                try await LegacyLogicalNetworkStore.networks(name: "default", on: app.testPostgres).first)
            let networkID = try network.requireID()

            #expect(
                try await self.postRecord(
                    app, token, zone: zoneID, name: "web", type: .a, value: "10.9.0.1") == .ok)

            // Attached and primary: only then is the zone something an agent is
            // sent at all.
            try await app.test(.POST, "/api/dns-zones/\(zoneID)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachDNSZoneRequest(networkId: networkID, primary: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            try await app.test(.PUT, "/api/dns-zones/\(zoneID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateDNSZoneRequest(name: self.string(DNSName.maxNameLength + 1)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let stored = try #require(try await LegacyDNSZoneStore.find(id: zoneID, on: app.testPostgres))
            #expect(stored.name == "acme.internal")

            // The projection an agent receives, which is the last thing between
            // the control plane and an OVSDB transaction.
            let assembled = try await DNSZoneAssembler.assemble(zone: stored, on: app.testPostgres)
            let desired = DNSZoneAssembler.desiredZone(assembled, networkIDs: [networkID])
            #expect(desired.zoneName == "acme.internal")
            #expect(!desired.records.isEmpty)
            #expect(desired.records.allSatisfy { $0.name.hasSuffix(".acme.internal") })
        }
    }

    // MARK: - Projects (the generated OpenAPI service)

    /// Projects don't decode a `ValidatedRequestBody` — the generated service
    /// hands `Project.validate()` a model — so their bounds need their own
    /// coverage.
    @Test("POST /api/organizations/:id/projects refuses an oversized name")
    func projectNameCeiling() async throws {
        try await withApp { app, _, org, _, _, token in
            try await app.test(.POST, "/api/organizations/\(org.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateProjectRequest(
                        name: self.string(Validate.nameLength + 1),
                        description: "over the ceiling",
                        organizationalUnitId: nil,
                        defaultEnvironment: "development",
                        environments: ["development"]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    /// The uniqueness check is an exact-match query, and `Project.validate()`
    /// trims before the save. Checking the raw value would let `"Foo "` past a
    /// scope already holding `"Foo"` and then store it as `"Foo"` — two projects
    /// with one name, and no unique index to catch it.
    @Test("A project name differing only by whitespace cannot duplicate an existing one")
    func projectNameUniquenessSurvivesTrimming() async throws {
        try await withApp { app, _, org, _, _, token in
            func create(_ name: String) async throws -> HTTPStatus {
                var status: HTTPStatus = .ok
                try await app.test(.POST, "/api/organizations/\(org.id!)/projects") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateProjectRequest(
                            name: name,
                            description: "d",
                            organizationalUnitId: nil,
                            defaultEnvironment: "development",
                            environments: ["development"]))
                } afterResponse: { res in
                    status = res.status
                }
                return status
            }

            #expect(try await create("Duplicate Me") == .ok)
            #expect(try await create("Duplicate Me ") == .conflict)
            #expect(try await create("  Duplicate Me") == .conflict)

            let named = try await Project.count(name: "Duplicate Me", on: app.testPostgres)
            #expect(named == 1)
        }
    }

    @Test("A project name is stored trimmed, so a later exact-match lookup finds it")
    func projectNameIsStoredTrimmed() async throws {
        try await withApp { app, _, org, _, _, token in
            try await app.test(.POST, "/api/organizations/\(org.id!)/projects") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateProjectRequest(
                        name: "  Padded Project  ",
                        description: "d",
                        organizationalUnitId: nil,
                        defaultEnvironment: " development ",
                        environments: [" development ", "staging"]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let created = try res.content.decode(ProjectResponse.self)
                #expect(created.name == "Padded Project")
                // The default has to match a member of the list *after* both
                // are normalized, or the project is born inconsistent.
                #expect(created.defaultEnvironment == "development")
                #expect(created.environments == ["development", "staging"])
            }
        }
    }

    // MARK: - The request body ceiling

    /// `defaultMaxBodySize` is the one change here a client can hit without
    /// sending an oversized *field*, so it gets its own test.
    ///
    /// Driven through a real server rather than the in-memory tester: body
    /// collection is the HTTP server's job, so `.inMemory` hands the handler
    /// the whole body regardless of the limit — a naive version of this test
    /// passes for the wrong reason, reporting the field's `400` instead of the
    /// transport's `413`.
    @Test("A request body past the global ceiling is refused before any handler sees it")
    func oversizedBodyIsRefused() async throws {
        try await withApp { app, _, project, image, token in
            // Comfortably past 1 MiB, and far below Vapor's old 16 MB default.
            let payload = self.string(2 * 1024 * 1024)
            try await app.testing(method: .running(port: 0)).test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "huge-body", imageId: image.id, projectId: project.id,
                        description: payload))
            } afterResponse: { res in
                #expect(res.status == .payloadTooLarge)
            }

            let vmCount = try await LegacyVMStore.vms(on: app.testPostgres).count
            #expect(vmCount == 0)
        }
    }

    /// The value itself, pinned separately from the behaviour above: it is a
    /// deployment-visible contract, and the test that exercises it end-to-end
    /// needs a live server, so this is the cheap one that always runs.
    @Test("The configured body ceiling is 1 MiB")
    func bodyCeilingIsConfigured() async throws {
        try await withApp { app, _, _, _, _ in
            #expect(app.routes.defaultMaxBodySize.value == 1024 * 1024)
        }
    }

    // MARK: - The database backstop

    /// The API is the layer that produces a good error; the column constraint
    /// is the layer that makes the bound true regardless of which code path
    /// writes the row.
    @Test("The database refuses an oversized name written straight to a model")
    func databaseRefusesOversizedName() async throws {
        try await withApp { app, _, project, _, _ in
            let volume = Volume(
                name: self.string(Validate.nameLength + 1),
                description: "",
                projectID: project.id!, environment: "development",
                size: 1024,
                format: .qcow2,
                volumeType: .data,
                status: .available,
                createdByID: UUID()
            )
            await #expect(throws: (any Error).self) {
                try await volume.save(on: app.testPostgres)
            }
        }
    }

    /// The DNS half of the backstop (STR-198), installed by the current-schema
    /// baseline alongside the rest of the text-length constraints.
    @Test("The database refuses an oversized zone name written straight to a model")
    func databaseRefusesOversizedDNSZoneName() async throws {
        try await withApp { app, user, project, _, _ in
            await #expect(throws: (any Error).self) {
                try await LegacyDNSZoneStore.insert(
                    name: self.string(DNSName.maxNameLength + 1),
                    projectID: project.id!, createdByID: user.id, on: app.testPostgres)
            }
        }
    }

}
