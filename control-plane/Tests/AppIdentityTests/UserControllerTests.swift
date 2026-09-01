import Testing
import Vapor
import Fluent
import VaporTesting
import AppTestSupport
@testable import App

@Suite("User API Authorization Tests", .serialized)
final class UserControllerTests: BaseTestCase {

    /// Create an additional user (distinct from `testUser`) plus a bearer token for it.
    private func makeUser(
        on db: Database,
        username: String,
        email: String,
        isSystemAdmin: Bool = false
    ) async throws -> (user: User, token: String) {
        let user = User(
            username: username,
            email: email,
            displayName: username,
            isSystemAdmin: isSystemAdmin
        )
        try await user.save(on: db)
        let token = try await user.generateAPIKey(on: db)
        return (user, token)
    }

    // MARK: - index

    /// The directory filters per row on `user:read`, like every other list
    /// endpoint, rather than gating the whole route on system admin: a
    /// non-admin is not forbidden, they simply match only themselves through
    /// the tier-1 `platform-user-self` policy.
    @Test("index returns only your own record for non-admins")
    func testIndexReturnsOnlySelfForNonAdmin() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            _ = try await makeUser(on: app.db, username: "other", email: "other@example.com")

            try await app.test(.GET, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let users = try res.content.decode(PagedResponse<User.Public>.self).items
                #expect(users.map(\.id) == [testUser.id])
            }
        }
    }

    @Test("index succeeds for system admins")
    func testIndexAllowedForAdmin() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let admin = try await makeUser(
                on: app.db, username: "admin", email: "admin@example.com", isSystemAdmin: true
            )

            try await app.test(.GET, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let users = try res.content.decode(PagedResponse<User.Public>.self).items
                #expect(users.count >= 2)
            }
        }
    }

    // MARK: - show

    @Test("show is allowed for self")
    func testShowSelf() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.GET, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let user = try res.content.decode(User.Public.self)
                #expect(user.id == testUser.id)
            }
        }
    }

    @Test("show another user is forbidden for non-admins")
    func testShowOtherForbidden() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.GET, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("show another user is allowed for system admins")
    func testShowOtherAllowedForAdmin() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let admin = try await makeUser(
                on: app.db, username: "admin", email: "admin@example.com", isSystemAdmin: true
            )

            try await app.test(.GET, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    // MARK: - update

    @Test("update self is allowed")
    func testUpdateSelf() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.PUT, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateUserRequest(displayName: "New Name", email: nil))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let user = try res.content.decode(User.Public.self)
                #expect(user.displayName == "New Name")
            }
        }
    }

    @Test("update another user is forbidden for non-admins")
    func testUpdateOtherForbidden() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.PUT, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateUserRequest(displayName: "Hijacked", email: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Confirm the target was not modified
            let reloaded = try await User.find(other.user.id, on: app.db)
            #expect(reloaded?.displayName == "other")
        }
    }

    // MARK: - delete

    @Test("delete another user is forbidden for non-admins")
    func testDeleteOtherForbidden() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.DELETE, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // Confirm the target still exists
            let reloaded = try await User.find(other.user.id, on: app.db)
            #expect(reloaded != nil)
        }
    }

    @Test("delete another user is allowed for system admins")
    func testDeleteOtherAllowedForAdmin() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let admin = try await makeUser(
                on: app.db, username: "admin", email: "admin@example.com", isSystemAdmin: true
            )
            let other = try await makeUser(
                on: app.db, username: "other", email: "other@example.com"
            )

            try await app.test(.DELETE, "/api/users/\(other.user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let reloaded = try await User.find(other.user.id, on: app.db)
            #expect(reloaded == nil)
        }
    }

    // MARK: - delete: creator references are attribution, not ownership (STR-297)

    /// A deletable creator plus a project to hang their resources on.
    private func makeCreatorFixture(
        on db: Database
    ) async throws -> (admin: (user: User, token: String), creator: User, project: Project) {
        let admin = try await makeUser(
            on: db, username: "admin", email: "admin@example.com", isSystemAdmin: true
        )
        let creator = try await makeUser(
            on: db, username: "creator", email: "creator@example.com"
        )
        let project = try await TestDataBuilder(db: db).createProject(
            name: "attribution-project", description: "STR-297", organization: testOrganization)
        return (admin, creator.user, project)
    }

    @Test("deleting a user leaves their volume, its replica, and its bindings, with attribution nulled")
    func testDeleteLeavesCreatedVolume() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let (admin, creator, project) = try await makeCreatorFixture(on: app.db)

            let volume = try await TestDataBuilder(db: app.db).createVolume(
                name: "survivor", project: project, createdBy: creator)
            let volumeID = try volume.requireID()
            try await VolumeReplica(
                volumeID: volumeID, agentId: "agent-1", diskAttachment: nil, state: .healthy
            ).create(on: app.db)
            // A binding protecting the volume for someone who stays. The
            // creator's own bindings are swept as *principal*; the node's
            // other bindings used to leak when the row cascaded (STR-112's
            // failure mode) and must now simply survive with it.
            try await RoleBindingService.grant(
                principalType: .user, principalID: testUser.id!,
                role: .admin, nodeType: .volume, nodeID: volumeID,
                createdBy: nil, on: app.db)

            try await app.test(.DELETE, "/api/users/\(creator.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let survivor = try #require(await Volume.find(volumeID, on: app.db))
            #expect(survivor.$createdBy.id == nil)
            let replicas = try await VolumeReplica.query(on: app.db)
                .filter(\.$volume.$id == volumeID)
                .count()
            #expect(replicas == 1)
            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.volume.rawValue)
                .filter(\.$nodeID == volumeID)
                .count()
            #expect(bindings == 1)
        }
    }

    @Test("deleting a user leaves their image row and its object-store bytes")
    func testDeleteLeavesUploadedImage() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let (admin, creator, project) = try await makeCreatorFixture(on: app.db)

            let tempStorage = FileManager.default.temporaryDirectory
                .appendingPathComponent("str297-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: tempStorage) }
            app.imageObjectStore = FilesystemImageObjectStore(rootPath: tempStorage)

            let image = try await TestDataBuilder(db: app.db).createImage(
                project: project, uploadedBy: creator)
            let imageID = try image.requireID()
            let artifact = try #require(
                await ImageArtifact.query(on: app.db).filter(\.$image.$id == imageID).first())
            let writer = try await app.imageObjectStore.openWriter(key: artifact.storagePath)
            try await writer.write(ByteBuffer(string: "image bytes"))
            try await writer.finish()

            try await app.test(.DELETE, "/api/users/\(creator.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let survivor = try #require(await Image.find(imageID, on: app.db))
            #expect(survivor.$uploadedBy.id == nil)
            // The blob is not reachable from any agent report, so a leaked
            // prefix would be permanent: prove the delete never touched it.
            let blobSurvives = try await app.imageObjectStore.exists(key: artifact.storagePath)
            #expect(blobSurvives)
        }
    }

    @Test("a user who created snapshots, webhooks and SSF streams is deletable and they all survive")
    func testDeleteLeavesOtherCreatedResources() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let (admin, creator, project) = try await makeCreatorFixture(on: app.db)
            let builder = TestDataBuilder(db: app.db)
            let creatorID = try creator.requireID()
            let projectID = try project.requireID()

            // Every table whose creator FK used to be NO ACTION (a raw 500 on
            // delete) or CASCADE, short of the volume and image cases covered
            // by their own tests above.
            let vm = try await builder.createVM(name: "checkpointed", project: project)
            let vmSnapshot = VMSnapshot(
                name: "pre-upgrade", vmID: try vm.requireID(), projectID: projectID,
                environment: "development", agentId: nil, createdByID: creatorID)
            try await vmSnapshot.save(on: app.db)

            let volume = try await builder.createVolume(
                name: "snapshotted", project: project, createdBy: creator)
            let volumeSnapshot = VolumeSnapshot(
                name: "backup", description: "", volumeID: try volume.requireID(),
                projectID: projectID, environment: "development", size: 1 << 30,
                createdByID: creatorID)
            try await volumeSnapshot.save(on: app.db)

            let sandbox = try await builder.createSandbox(name: "sandboxed", project: project)
            let sandboxSnapshot = SandboxSnapshot(
                name: "fork-base", sandboxID: try sandbox.requireID(), projectID: projectID,
                environment: "development", agentId: nil, createdByID: creatorID)
            try await sandboxSnapshot.save(on: app.db)

            let webhook = WebhookSubscription(
                organizationID: testOrganization.id!, name: "notify", url: "https://example.com/hook",
                eventTypes: [], signingSecret: "secret", createdByID: creatorID)
            try await webhook.save(on: app.db)

            let stream = SSFStream(
                organizationID: testOrganization.id!, name: "ssf",
                transmitterURL: "https://idp.example.com/ssf", deliveryMethod: .poll,
                createdByID: creatorID)
            try await stream.save(on: app.db)

            try await app.test(.DELETE, "/api/users/\(creatorID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            #expect(try #require(await VMSnapshot.find(vmSnapshot.id, on: app.db)).$createdBy.id == nil)
            #expect(try #require(await VolumeSnapshot.find(volumeSnapshot.id, on: app.db)).$createdBy.id == nil)
            #expect(try #require(await SandboxSnapshot.find(sandboxSnapshot.id, on: app.db)).$createdBy.id == nil)
            #expect(try #require(await WebhookSubscription.find(webhook.id, on: app.db)).$createdBy.id == nil)
            #expect(try #require(await SSFStream.find(stream.id, on: app.db)).$createdBy.id == nil)
        }
    }

    @Test("delete is refused while a volume the user created is attached to a VM")
    func testDeleteRefusedWhileVolumeAttached() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let (admin, creator, project) = try await makeCreatorFixture(on: app.db)
            let builder = TestDataBuilder(db: app.db)

            let vm = try await builder.createVM(name: "running-guest", project: project)
            let volume = try await builder.createVolume(
                name: "boot-volume", project: project, createdBy: creator)
            volume.$vm.id = try vm.requireID()
            volume.deviceName = "disk0"
            volume.attachedAgentId = "agent-1"
            try await volume.save(on: app.db)

            try await app.test(.DELETE, "/api/users/\(creator.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("attached"))
            }

            // Refused means untouched: the user, the volume, its attribution.
            #expect(try await User.find(creator.id, on: app.db) != nil)
            let untouched = try #require(await Volume.find(volume.id, on: app.db))
            #expect(untouched.$createdBy.id == creator.id)
        }
    }

    @Test("delete is refused while the user's SCIM tokens exist, and succeeds once they are gone")
    func testDeleteRefusedWhileSCIMTokensExist() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let (admin, creator, _) = try await makeCreatorFixture(on: app.db)

            let token = SCIMToken(
                organizationID: testOrganization.id!, name: "provisioning",
                tokenHash: "hash", tokenPrefix: "scim_test", createdByID: try creator.requireID())
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/users/\(creator.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("SCIM"))
            }
            #expect(try await User.find(creator.id, on: app.db) != nil)

            try await token.delete(on: app.db)

            try await app.test(.DELETE, "/api/users/\(creator.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(try await User.find(creator.id, on: app.db) == nil)
        }
    }

    @Test("a mutation saved from a pre-delete snapshot does not resurrect nulled attribution")
    func testStaleModelSaveDoesNotResurrectAttribution() async throws {
        try await withTestApp { app in
            try await setupCommonTestData(on: app.db)
            let (admin, creator, project) = try await makeCreatorFixture(on: app.db)

            let volume = try await TestDataBuilder(db: app.db).createVolume(
                name: "resized-later", project: project, createdBy: creator)
            // A second instance loaded the way a mutation handler loads one,
            // *before* the creator disappears — its in-memory createdBy still
            // names the soon-deleted user.
            let snapshot = try #require(await Volume.find(volume.id, on: app.db))

            try await app.test(.DELETE, "/api/users/\(creator.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: admin.token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // Fluent updates only the properties a handler actually set after
            // loading, so saving the stale snapshot must neither write the
            // deleted UUID back (an FK violation) nor resurrect attribution.
            snapshot.size = snapshot.size * 2
            try await snapshot.save(on: app.db)

            let reloaded = try #require(await Volume.find(volume.id, on: app.db))
            #expect(reloaded.$createdBy.id == nil)
            #expect(reloaded.size == snapshot.size)
        }
    }
}
