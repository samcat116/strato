import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// The role-definition API (`/api/iam/roles`, issue #605).
///
/// The real Cedar engine stays in place here, unlike `GuardrailEndpointTests`
/// with its solver: parsing and schema validation are in-process and
/// deterministic, and they are half of what these routes promise — a shape
/// rejection this suite asserts on is the shape rejection production makes.
@Suite("Role Endpoint Tests", .serialized)
final class RoleEndpointTests {

    private struct Fixture {
        let user: User
        let token: String
        let org: Organization
        let project: Project
    }

    private func withApp(
        systemAdmin: Bool = false,
        _ test: (Application, Fixture) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "roleuser",
                email: "role@example.com",
                displayName: "Role User",
                isSystemAdmin: systemAdmin
            )
            let org = try await builder.createOrganization(name: "Role Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Role Project", description: "d", organization: org)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, Fixture(user: user, token: token, org: org, project: project))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Request builders

    private func createBody(
        name: String,
        org: Organization,
        actions: [String]? = ["vm:read", "vm:list"],
        cedarText: String? = nil,
        id: UUID? = nil
    ) -> RoleController.CreateRoleRequest {
        RoleController.CreateRoleRequest(
            name: name,
            description: "a custom role",
            ownerType: .organization,
            ownerId: org.id!,
            actions: actions,
            cedarText: cedarText,
            id: id
        )
    }

    /// Post a role and return it, failing the test if the write did not
    /// succeed.
    private func createRole(
        _ body: RoleController.CreateRoleRequest, token: String, on app: Application
    ) async throws -> RoleController.RoleDTO {
        var created: RoleController.RoleDTO?
        try await app.test(
            .POST, "/api/iam/roles",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(body)
            },
            afterResponse: { res in
                // The body is in the failure comment because every rejection
                // this API makes explains itself in `reason` — a bare status
                // would send the reader back to the logs for it.
                #expect(res.status == .created, "\(res.status): \(res.body.string)")
                created = try res.content.decode(RoleController.RoleDTO.self)
            })
        guard let created else {
            throw Abort(.internalServerError, reason: "role was not created")
        }
        return created
    }

    // MARK: - Create

    @Test("Creating a role from an action list generates the canonical permit and bumps the version")
    func createFromActionsGeneratesPermit() async throws {
        try await withApp { app, fixture in
            let before = try await PolicySetVersionService.current(on: app.db)

            let role = try await createRole(
                createBody(name: "vm-reader", org: fixture.org), token: fixture.token, on: app)

            #expect(role.actions == ["vm:list", "vm:read"])
            #expect(role.managed == false)
            #expect(role.ownerType == .organization)
            #expect(role.cedarText == RoleDescriptor.canonicalPermitText(id: role.id, actions: role.actions))
            #expect(role.cedarText.contains("\(role.id.uuidString.lowercased())Users"))

            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == before + 1)
        }
    }

    @Test("Creating a role from hand-written Cedar text stores it verbatim and derives the actions")
    func createFromCedarTextDerivesActions() async throws {
        try await withApp { app, fixture in
            let id = UUID()
            // The canonical permit plus an extra condition — the advanced mode
            // the shape rules exist to allow.
            let text = """
                permit (
                    principal,
                    action in [Action::"vm:read", Action::"vm:start"],
                    resource
                )
                when {
                    principal in context.grants["\(RoleDescriptor.grantsUsersField(id))"] ||
                    principal in context.grants["\(RoleDescriptor.grantsGroupsField(id))"]
                }
                when { resource has environment && resource.environment == "staging" };
                """

            let role = try await createRole(
                createBody(name: "staging-vm-operator", org: fixture.org, actions: nil, cedarText: text, id: id),
                token: fixture.token, on: app)

            #expect(role.id == id)
            #expect(role.actions == ["vm:read", "vm:start"])
            #expect(role.cedarText == text)
        }
    }

    @Test("Sending both input modes, or neither, is a 400")
    func inputModesAreExclusive() async throws {
        try await withApp { app, fixture in
            let bodies = [
                createBody(
                    name: "both", org: fixture.org, actions: ["vm:read"],
                    cedarText: "permit(principal, action, resource);"),
                createBody(name: "neither", org: fixture.org, actions: nil, cedarText: nil),
            ]
            for body in bodies {
                try await app.test(
                    .POST, "/api/iam/roles",
                    beforeRequest: { req in
                        req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                        try req.content.encode(body)
                    },
                    afterResponse: { res in
                        #expect(res.status == .badRequest)
                    })
            }
            let stored = try await IAMRoleDefinition.query(on: app.db).filter(\.$managed == false).count()
            #expect(stored == 0)
        }
    }

    @Test("An action the registry does not know is a 400 and writes nothing")
    func unknownActionIsRejected() async throws {
        try await withApp { app, fixture in
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .POST, "/api/iam/roles",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(name: "typo", org: fixture.org, actions: ["vm:raed"]))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(res.body.string.contains("vm:raed"))
                })

            let stored = try await IAMRoleDefinition.query(on: app.db).filter(\.$managed == false).count()
            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(stored == 0)
            #expect(after == before)
        }
    }

    /// A role naming a *service group* would grant whatever joins that service
    /// later — the auto-absorbing behavior the curated registry exists to
    /// prevent. Cedar collapses `action in [X]` and `action in X` to the same
    /// AST, so this cannot be caught by shape; it is caught by name, because
    /// group names are not registry actions. The test pins that, since it is
    /// the only thing standing between a role and a wildcard.
    @Test("A role naming a service action group is rejected by name")
    func serviceGroupActionIsRejected() async throws {
        try await withApp { app, fixture in
            let id = UUID()
            let group = CedarSchemaBuilder.serviceGroupName("vm")
            let text = """
                permit (principal, action in Action::"\(group)", resource)
                when {
                    principal in context.grants["\(RoleDescriptor.grantsUsersField(id))"] ||
                    principal in context.grants["\(RoleDescriptor.grantsGroupsField(id))"]
                };
                """

            try await app.test(
                .POST, "/api/iam/roles",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(
                            name: "vm-everything", org: fixture.org, actions: nil, cedarText: text, id: id))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(res.body.string.contains(group))
                })

            let stored = try await IAMRoleDefinition.query(on: app.db).filter(\.$managed == false).count()
            #expect(stored == 0)
        }
    }

    /// A one-action role: Cedar renders `action in [X]` the same way it
    /// renders `action in X`, so this is the case the action-scope reader most
    /// easily gets wrong.
    @Test("A role granting exactly one action round-trips")
    func singleActionRole() async throws {
        try await withApp { app, fixture in
            let role = try await createRole(
                createBody(name: "one-action", org: fixture.org, actions: ["vm:read"]),
                token: fixture.token, on: app)
            #expect(role.actions == ["vm:read"])
        }
    }

    // MARK: - EST shape rejections

    /// The shape rules, each with the text that breaks exactly one of them.
    @Test(
        "Cedar text that is not a role's shape is a 400",
        arguments: [
            // A forbid: ceilings belong to the guardrail API.
            ("forbid", "forbid (principal, action in [Action::\"vm:read\"], resource);"),
            // A principal-scoped permit: bindings decide who holds a role.
            ("bound principal", "permit (principal == User::\"%GRANTS%\", action in [Action::\"vm:read\"], resource);"),
            // An unscoped action: nothing to derive the action list from.
            ("unenumerable", "permit (principal, action, resource);"),
            // No grants condition: the role would grant to everyone.
            ("ungated", "permit (principal, action in [Action::\"vm:read\"], resource);"),
            // Another role's grants: a role may only read its own bindings.
            (
                "foreign grants",
                "permit (principal, action in [Action::\"vm:read\"], resource) when { principal in context.grants[\"00000000-0000-0000-0000-000000000004Users\"] };"
            ),
            // Both own fields named, then neutralized by a tautology in the
            // same disjunction. Mentioning the fields is not being gated by
            // them: this permit matches every principal on every resource with
            // no binding behind it, while its derived action list still reads
            // like an ordinary role.
            (
                "neutralized gate",
                """
                permit (principal, action in [Action::"vm:read"], resource)
                when {
                    principal in context.grants["%USERS%"] ||
                    principal in context.grants["%GROUPS%"] ||
                    principal == principal
                };
                """
            ),
            // The same escape by a different spelling — no constant-folding to
            // rely on, and no `||` on the gate itself.
            (
                "gate widened by a second clause",
                """
                permit (principal, action in [Action::"vm:read"], resource)
                when {
                    principal in context.grants["%USERS%"] ||
                    principal in context.grants["%GROUPS%"] ||
                    context.grants["%USERS%"] == context.grants["%USERS%"]
                };
                """
            ),
        ])
    func shapeRejections(label: String, text: String) async throws {
        try await withApp { app, fixture in
            let id = UUID()
            let body = createBody(
                name: "bad-\(label.replacingOccurrences(of: " ", with: "-"))",
                org: fixture.org,
                actions: nil,
                cedarText:
                    text
                    .replacingOccurrences(of: "%GRANTS%", with: id.uuidString)
                    .replacingOccurrences(of: "%USERS%", with: RoleDescriptor.grantsUsersField(id))
                    .replacingOccurrences(of: "%GROUPS%", with: RoleDescriptor.grantsGroupsField(id)),
                id: id
            )
            try await app.test(
                .POST, "/api/iam/roles",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(body)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })
            let stored = try await IAMRoleDefinition.query(on: app.db).filter(\.$managed == false).count()
            #expect(stored == 0)
        }
    }

    @Test("Unparseable Cedar text surfaces the parser's own error as a 400")
    func unparseableTextIsRejected() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/roles",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(
                            name: "garbage", org: fixture.org, actions: nil,
                            cedarText: "permit principal action resource"))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(res.body.string.contains("parseable"))
                })
        }
    }

    // MARK: - Owner scope

    @Test("A platform-owned role cannot be created through the API")
    func platformOwnedCreationIsRejected() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/roles",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        RoleController.CreateRoleRequest(
                            name: "fake-default",
                            description: nil,
                            ownerType: .platform,
                            ownerId: IAMRoleDefinition.platformOwnerID,
                            actions: ["vm:read"],
                            cedarText: nil,
                            id: nil
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })
        }
    }

    @Test("A role owned by an organization that does not exist is a 404")
    func unknownOwnerIsRejected() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/roles",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        RoleController.CreateRoleRequest(
                            name: "orphan",
                            description: nil,
                            ownerType: .organization,
                            ownerId: UUID(),
                            actions: ["vm:read"],
                            cedarText: nil,
                            id: nil
                        ))
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    @Test("Writing a role in an organization the caller does not administer is a 403")
    func foreignOwnerIsForbidden() async throws {
        try await withApp { app, fixture in
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Someone Else's Org")

            try await app.test(
                .POST, "/api/iam/roles",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(self.createBody(name: "trespass", org: otherOrg))
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })
        }
    }

    // MARK: - Managed roles

    @Test("A seeded role is immutable through the API")
    func managedRolesAreImmutable() async throws {
        try await withApp(systemAdmin: true) { app, fixture in
            let adminRole = IAMRole.admin.seededID
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .PATCH, "/api/iam/roles/\(adminRole)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        RoleController.UpdateRoleRequest(
                            name: nil, description: nil, actions: ["vm:read"], cedarText: nil))
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })
            try await app.test(
                .DELETE, "/api/iam/roles/\(adminRole)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

            let stored = try await IAMRoleDefinition.find(adminRole, on: app.db)
            #expect(stored?.actions.contains("iam:setPolicy") == true)
            #expect(try await PolicySetVersionService.current(on: app.db) == before)
        }
    }

    // MARK: - Update and delete

    @Test("Editing a role's actions rewrites its permit and bumps the version")
    func updateRewritesPermit() async throws {
        try await withApp { app, fixture in
            let role = try await createRole(
                createBody(name: "editable", org: fixture.org), token: fixture.token, on: app)
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .PATCH, "/api/iam/roles/\(role.id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        RoleController.UpdateRoleRequest(
                            name: "renamed", description: nil, actions: ["vm:read", "vm:start"], cedarText: nil))
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let updated = try res.content.decode(RoleController.RoleDTO.self)
                    #expect(updated.name == "renamed")
                    #expect(updated.actions == ["vm:read", "vm:start"])
                    #expect(updated.cedarText.contains("vm:start"))
                })

            #expect(try await PolicySetVersionService.current(on: app.db) == before + 1)
        }
    }

    @Test("A role with active bindings is a 409 until they are revoked")
    func deleteBlockedWhileBound() async throws {
        try await withApp { app, fixture in
            let role = try await createRole(
                createBody(name: "in-use", org: fixture.org), token: fixture.token, on: app)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: fixture.user.id!,
                roleID: role.id,
                nodeType: .project,
                nodeID: fixture.project.id!,
                createdBy: fixture.user.id,
                on: app.db
            )

            try await app.test(
                .DELETE, "/api/iam/roles/\(role.id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .conflict)
                    #expect(res.body.string.contains("1 active binding"))
                })
            #expect(try await IAMRoleDefinition.find(role.id, on: app.db) != nil)

            try await RoleBindingService.revoke(
                principalType: .user,
                principalID: fixture.user.id!,
                roleID: role.id,
                nodeType: .project,
                nodeID: fixture.project.id!,
                on: app.db
            )
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .DELETE, "/api/iam/roles/\(role.id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                })
            #expect(try await IAMRoleDefinition.find(role.id, on: app.db) == nil)
            #expect(try await PolicySetVersionService.current(on: app.db) == before + 1)
        }
    }

    @Test("Granting and revoking a role does not bump the policy-set version")
    func bindingsDoNotBumpTheVersion() async throws {
        try await withApp { app, fixture in
            let role = try await createRole(
                createBody(name: "bindable-role", org: fixture.org), token: fixture.token, on: app)
            let before = try await PolicySetVersionService.current(on: app.db)

            try await RoleBindingService.grant(
                principalType: .user, principalID: fixture.user.id!, roleID: role.id,
                nodeType: .project, nodeID: fixture.project.id!, createdBy: nil, on: app.db)
            try await RoleBindingService.revoke(
                principalType: .user, principalID: fixture.user.id!, roleID: role.id,
                nodeType: .project, nodeID: fixture.project.id!, on: app.db)

            #expect(try await PolicySetVersionService.current(on: app.db) == before)
        }
    }

    // MARK: - Listings

    @Test("The bindable list is the platform defaults plus the roles owned along the chain")
    func bindableListsInheritedRoles() async throws {
        try await withApp { app, fixture in
            let orgRole = try await createRole(
                createBody(name: "org-wide", org: fixture.org), token: fixture.token, on: app)
            let projectRole = try await createRole(
                RoleController.CreateRoleRequest(
                    name: "project-only",
                    description: nil,
                    ownerType: .project,
                    ownerId: fixture.project.id!,
                    actions: ["vm:read"],
                    cedarText: nil,
                    id: nil
                ), token: fixture.token, on: app)

            try await app.test(
                .GET, "/api/iam/roles/bindable?nodeType=project&nodeId=\(fixture.project.id!)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let listed = try res.content.decode(RoleController.BindableRolesResponse.self)
                    let ids = Set(listed.roles.map(\.id))
                    #expect(ids.contains(orgRole.id))
                    #expect(ids.contains(projectRole.id))
                    #expect(ids.contains(IAMRole.admin.seededID))

                    // Names and actions, never policy text: this listing is
                    // gated on read of the node, and `cedarText` can describe
                    // the org's security posture.
                    let listedOrgRole = listed.roles.first { $0.id == orgRole.id }
                    #expect(listedOrgRole?.actions == ["vm:list", "vm:read"])
                    let raw = res.body.string
                    #expect(!raw.contains("cedarText"))
                    #expect(!raw.contains("context.grants"))
                })

            // The project's own role is not bindable on the organization
            // above it — ownership is what scopes a role.
            try await app.test(
                .GET, "/api/iam/roles/bindable?nodeType=organization&nodeId=\(fixture.org.id!)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let listed = try res.content.decode(RoleController.BindableRolesResponse.self)
                    let ids = Set(listed.roles.map(\.id))
                    #expect(ids.contains(orgRole.id))
                    #expect(!ids.contains(projectRole.id))
                })
        }
    }

    @Test("Listing an owner's roles returns only what that owner defines")
    func listIsOwnerScoped() async throws {
        try await withApp { app, fixture in
            let orgRole = try await createRole(
                createBody(name: "org-owned", org: fixture.org), token: fixture.token, on: app)

            try await app.test(
                .GET, "/api/iam/roles?ownerType=organization&ownerId=\(fixture.org.id!)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let listed = try res.content.decode(RoleController.RoleListResponse.self)
                    #expect(listed.roles.map(\.id) == [orgRole.id])
                })

            try await app.test(
                .GET, "/api/iam/roles?ownerType=project&ownerId=\(fixture.project.id!)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let listed = try res.content.decode(RoleController.RoleListResponse.self)
                    #expect(listed.roles.isEmpty)
                })
        }
    }

    // MARK: - Validate and catalog

    @Test("Validate compiles without saving and hands back the generated permit")
    func validateSavesNothing() async throws {
        try await withApp { app, fixture in
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .POST, "/api/iam/roles/validate",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        RoleController.ValidateRoleRequest(
                            actions: ["vm:read", "volume:attach"], cedarText: nil, id: nil))
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                    let checked = try res.content.decode(RoleController.ValidateRoleResponse.self)
                    #expect(checked.actions == ["vm:read", "volume:attach"])
                    #expect(checked.cedarText.contains("\(checked.id.uuidString.lowercased())Users"))
                })

            try await app.test(
                .POST, "/api/iam/roles/validate",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        RoleController.ValidateRoleRequest(
                            actions: nil, cedarText: "forbid (principal, action, resource);", id: nil))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

            let stored = try await IAMRoleDefinition.query(on: app.db).filter(\.$managed == false).count()
            #expect(stored == 0)
            #expect(try await PolicySetVersionService.current(on: app.db) == before)
        }
    }

    @Test("The action catalog covers the registry, grouped by service")
    func catalogShape() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .GET, "/api/iam/actions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let catalog = try res.content.decode(IAMActionCatalog.Response.self)
                    let all = catalog.services.flatMap(\.actions)
                    #expect(Set(all.map(\.action)) == IAMRoleRegistry.allActions)
                    #expect(catalog.services.map(\.service) == catalog.services.map(\.service).sorted())

                    let vmRead = all.first { $0.action == "vm:read" }
                    #expect(vmRead?.service == "vm")
                    #expect(vmRead?.roles == ["admin", "editor", "operator", "viewer"])
                    #expect(vmRead?.resourceTypes.contains("virtual_machine") == true)
                    #expect(vmRead?.membershipDerived == false)

                    // An action no role carries still belongs in the catalog:
                    // a custom role granting it is legitimate.
                    let projectCreate = all.first { $0.action == "project:create" }
                    #expect(projectCreate?.roles.isEmpty == true)
                    #expect(projectCreate?.membershipDerived == true)
                })
        }
    }

    // MARK: - Cascades

    @Test("Deleting a project removes the roles it owns and bumps the version")
    func projectDeleteRemovesOwnedRoles() async throws {
        try await withApp { app, fixture in
            let role = try await createRole(
                RoleController.CreateRoleRequest(
                    name: "doomed",
                    description: nil,
                    ownerType: .project,
                    ownerId: fixture.project.id!,
                    actions: ["vm:read"],
                    cedarText: nil,
                    id: nil
                ), token: fixture.token, on: app)
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .DELETE, "/api/projects/\(fixture.project.id!)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                })

            #expect(try await IAMRoleDefinition.find(role.id, on: app.db) == nil)
            #expect(try await PolicySetVersionService.current(on: app.db) == before + 1)
        }
    }
}
