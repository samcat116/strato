import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// The guardrail API (`/api/iam/guardrails`, issue #479).
@Suite("Guardrail Endpoint Tests", .serialized)
final class GuardrailEndpointTests {

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
            // This suite is about the API, not the symbolic analysis: with the
            // real analyzer these tests would pass or fail on whether the
            // machine has an SMT solver. The shadowed-bindings report is
            // covered against a real solver in GuardrailWriteCheckTests.
            app.guardrailAnalyzer = PermissiveGuardrailAnalyzer()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "guardrailuser",
                email: "guardrail@example.com",
                displayName: "Guardrail User",
                isSystemAdmin: systemAdmin
            )
            let org = try await builder.createOrganization(name: "Guardrail Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Guardrail Project", description: "d", organization: org)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, Fixture(user: user, token: token, org: org, project: project))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func createBody(
        name: String,
        effect: String? = nil,
        org: Organization,
        actions: [String]? = ["vm:delete"],
        cedarText: String? = nil
    ) -> GuardrailController.CreateGuardrailRequest {
        GuardrailController.CreateGuardrailRequest(
            name: name,
            description: "test ceiling",
            effect: effect,
            nodeType: "organization",
            nodeId: org.id!.uuidString,
            actions: cedarText == nil ? actions : nil,
            principalMatch: nil,
            resourceMatch: nil,
            cedarText: cedarText,
            enabled: nil
        )
    }

    @Test("Creating a guardrail returns it as a forbid and bumps the policy-set version")
    func createReturnsForbidAndBumpsVersion() async throws {
        try await withApp { app, fixture in
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .POST, "/api/iam/guardrails",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(self.createBody(name: "no-vm-delete", org: fixture.org))
                },
                afterResponse: { res in
                    #expect(res.status == .created)
                    let written = try res.content.decode(GuardrailController.GuardrailWriteResponse.self)
                    let decoded = written.guardrail
                    #expect(decoded.effect == "forbid")
                    // The write carries the shadowed-bindings report (#484);
                    // the injected analyzer finds no overlap, so it is empty.
                    #expect(written.shadowedBindings.isEmpty)
                    #expect(decoded.actions == ["vm:delete"])
                    #expect(decoded.shape == "unconditional")
                })

            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == before + 1)
        }
    }

    @Test("A permit-shaped request is a 400 and writes nothing")
    func permitIsRejectedAtTheBoundary() async throws {
        try await withApp { app, fixture in
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .POST, "/api/iam/guardrails",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(name: "sneaky-permit", effect: "permit", org: fixture.org))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(res.body.string.contains("forbid-only"))
                })

            let stored = try await Guardrail.query(on: app.db).count()
            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(stored == 0)
            // A rejected write must not move the version: replicas would
            // recompile an unchanged policy set.
            #expect(after == before)
        }
    }

    @Test("The effective list includes ceilings inherited from above")
    func effectiveListIncludesInherited() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/guardrails",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(self.createBody(name: "org-ceiling", org: fixture.org))
                },
                afterResponse: { res in
                    #expect(res.status == .created)
                })

            // Attached-only at the project: the org's ceiling is not here.
            try await app.test(
                .GET,
                "/api/iam/guardrails?nodeType=project&nodeId=\(fixture.project.id!.uuidString)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let decoded = try res.content.decode(GuardrailController.GuardrailListResponse.self)
                    #expect(decoded.guardrails.isEmpty)
                })

            // Effective at the project: it is in force here.
            try await app.test(
                .GET,
                "/api/iam/guardrails?nodeType=project&nodeId=\(fixture.project.id!.uuidString)&effective=true",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let decoded = try res.content.decode(GuardrailController.GuardrailListResponse.self)
                    #expect(decoded.guardrails.map(\.name) == ["org-ceiling"])
                    #expect(decoded.ancestors?.count == 2)
                })
        }
    }

    @Test("Managing guardrails requires admin over the node")
    func nonAdminIsForbidden() async throws {
        try await withApp { app, fixture in
            // A bare org member holds no admin binding, so iam:setPolicy on
            // the org is denied.
            let member = try await TestDataBuilder(db: app.db).createUser(
                username: "guardrail-member", email: "guardrail-member@example.com")
            try await TestDataBuilder(db: app.db).addUserToOrganization(
                user: member, organization: fixture.org, role: "member")
            let memberToken = try await member.generateAPIKey(on: app.db)

            try await app.test(
                .POST, "/api/iam/guardrails",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                    try req.content.encode(self.createBody(name: "not-allowed", org: fixture.org))
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

            let stored = try await Guardrail.query(on: app.db).count()
            #expect(stored == 0)
        }
    }

    @Test("Deleting a guardrail removes it and bumps the version")
    func deleteRemovesAndBumps() async throws {
        try await withApp { app, fixture in
            var guardrailID: UUID?
            try await app.test(
                .POST, "/api/iam/guardrails",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(self.createBody(name: "temporary", org: fixture.org))
                },
                afterResponse: { res in
                    guardrailID = try res.content.decode(GuardrailController.GuardrailWriteResponse.self).guardrail.id
                })
            let id = try #require(guardrailID)
            let afterCreate = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .DELETE, "/api/iam/guardrails/\(id.uuidString)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                })

            let stored = try await Guardrail.query(on: app.db).count()
            let afterDelete = try await PolicySetVersionService.current(on: app.db)
            #expect(stored == 0)
            #expect(afterDelete == afterCreate + 1)
        }
    }

    @Test("The policy-set version endpoint is system-admin only")
    func policySetVersionRequiresSystemAdmin() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .GET, "/api/iam/policy-set/version",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })
        }

        try await withApp(systemAdmin: true) { app, fixture in
            try await app.test(
                .GET, "/api/iam/policy-set/version",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let decoded = try res.content.decode(GuardrailController.PolicySetVersionResponse.self)
                    #expect(decoded.version > 0)
                })
        }
    }

    // MARK: - Authored guardrails (#610)

    @Test("An authored forbid is created and returned with authored=true and its cedarText")
    func authoredGuardrailEndpoint() async throws {
        try await withApp { app, fixture in
            let projectLiteral = IAMNode(type: .project, id: fixture.project.id!).cedarUID.cedarLiteral
            let text =
                "forbid(principal, action in [Action::\"vm:delete\"], resource in \(projectLiteral));"
            let body = GuardrailController.CreateGuardrailRequest(
                name: "authored-ceiling", description: "d", effect: nil,
                nodeType: "project", nodeId: fixture.project.id!.uuidString,
                actions: nil, principalMatch: nil, resourceMatch: nil, cedarText: text, enabled: nil)

            try await app.test(
                .POST, "/api/iam/guardrails",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(body)
                },
                afterResponse: { res in
                    #expect(res.status == .created)
                    let written = try res.content.decode(GuardrailController.GuardrailWriteResponse.self)
                    #expect(written.guardrail.authored == true)
                    #expect(written.guardrail.cedarText == text)
                    #expect(written.guardrail.effect == "forbid")
                })
        }
    }

    @Test("Sending both matchers and cedarText is a 400 that writes nothing")
    func ambiguousInputRejected() async throws {
        try await withApp { app, fixture in
            let projectLiteral = IAMNode(type: .project, id: fixture.project.id!).cedarUID.cedarLiteral
            let body = GuardrailController.CreateGuardrailRequest(
                name: "ambiguous", description: nil, effect: nil,
                nodeType: "project", nodeId: fixture.project.id!.uuidString,
                actions: ["vm:delete"], principalMatch: nil, resourceMatch: nil,
                cedarText: "forbid(principal, action, resource in \(projectLiteral));", enabled: nil)

            try await app.test(
                .POST, "/api/iam/guardrails",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(body)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

            let count = try await Guardrail.query(on: app.db).count()
            #expect(count == 0)
        }
    }
}
