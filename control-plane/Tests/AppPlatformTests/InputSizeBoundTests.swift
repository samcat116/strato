import Fluent
import SQLKit
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
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "bounduser", email: "bound@example.com")
            let org = try await builder.createOrganization(name: "Bound Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .organization, nodeID: org.id!, createdBy: nil, on: app.db)
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Bound Project", description: "p", organization: org)
            try await builder.createNetwork(name: "default", project: project)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, org, project, image, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
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
            let names = try await VM.query(on: app.db).all().map(\.name)
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

            let vmCount = try await VM.query(on: app.db).count()
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

            let vm = try await VM.query(on: app.db).filter(\.$name == "keyed-vm").first()
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

            let vmCount = try await VM.query(on: app.db).count()
            #expect(vmCount == 0)
        }
    }

    @Test("PUT /api/vms/:id holds a rename to the same ceiling as create")
    func vmUpdateNameCeiling() async throws {
        try await withApp { app, user, project, _, token in
            let vm = try await TestDataBuilder(db: app.db).createVM(
                name: "renameable", project: project)
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .virtualMachine, nodeID: vm.id!, createdBy: user.id, on: app.db)

            struct UpdateBody: Content { let name: String }
            try await app.test(.PUT, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateBody(name: self.string(Validate.nameLength + 1)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let reloaded = try await VM.find(vm.id!, on: app.db)
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
        try await withApp { app, _, project, _, token in
            let oversized = self.string(Validate.nameLength + 1)
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: oversized, subnet: "10.77.0.0/24", projectId: project.id))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Nothing was persisted, so nothing can be assembled into a sync,
            // which is the only way a name reaches an agent at all.
            let persisted = try await LogicalNetwork.query(on: app.db).all().map(\.name)
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
            let volumeCount = try await Volume.query(on: app.db).count()
            #expect(volumeCount == 0)
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

            let named = try await Project.query(on: app.db)
                .filter(\.$name == "Duplicate Me")
                .count()
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

            let vmCount = try await VM.query(on: app.db).count()
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

    // MARK: - The migration's pre-scan

    /// `assertRowsFit` exists so an operator gets the offending rows named
    /// rather than a bare constraint violation. Exercised by dropping one
    /// column's constraint, writing a row that no longer fits, and re-running
    /// the migration.
    @Test("The migration refuses to bound a column whose existing rows do not fit")
    func migrationRefusesOversizedExistingRows() async throws {
        try await withApp { app, _, _, _, _ in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Control-plane tests run against Postgres")
                return
            }

            try await sql.raw(
                "ALTER TABLE \"organizations\" DROP CONSTRAINT \"ck_organizations_name_length\""
            ).run()
            let oversized = self.string(Validate.nameLength + 40)
            let organization = Organization(name: "placeholder", description: "d")
            try await organization.save(on: app.db)
            try await sql.raw(
                "UPDATE \"organizations\" SET \"name\" = \(bind: oversized) WHERE \"id\" = \(bind: organization.id!)"
            ).run()

            let error = await #expect(throws: BoundResourceTextColumnsError.self) {
                try await BoundResourceTextColumns().prepare(on: app.db)
            }
            let described = String(describing: try #require(error))
            #expect(described.contains("organizations.name"))
            #expect(described.contains(organization.id!.uuidString))
            #expect(described.contains("\(Validate.nameLength + 40) characters"))
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
                try await volume.save(on: app.db)
            }
        }
    }

    @Test("Every bounded column carries its CHECK constraint after migration")
    func constraintsExist() async throws {
        try await withApp { app, _, _, _, _ in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Control-plane tests run against Postgres")
                return
            }
            let rows = try await sql.raw(
                "SELECT conname FROM pg_constraint WHERE contype = 'c' AND conname LIKE 'ck_%_length'"
            ).all()
            let present = Set(rows.compactMap { try? $0.decode(column: "conname", as: String.self) })
            let expected = Set(BoundResourceTextColumns.columns.map(\.constraintName))
            #expect(expected.subtracting(present).isEmpty)
        }
    }
}
