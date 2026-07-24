import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Coverage for the default-on offset pagination of resource list endpoints
/// (issue #700): every list returns a `PagedResponse` envelope, and `limit`/
/// `offset` slice *after* authorization filtering, so `total` counts exactly
/// the rows the caller may read. `GET /api/vms` stands in for the shared
/// mechanics (all endpoints go through the same `ListPaging` helper); the
/// authorization interaction gets its own test because it is the property the
/// slicing order exists to protect.
@Suite("List Pagination Tests", .serialized)
final class ListPaginationTests: BaseTestCase {

    @Test("GET /api/vms pages with the envelope: defaults, slices, clamping, validation")
    func vmListPages() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let builder = TestDataBuilder(db: app.db)
            let project = try await builder.createProject(
                name: "Paging Project", description: "pagination coverage", organization: testOrganization)
            for index in 0..<5 {
                _ = try await builder.createVM(name: "pager-vm-\(index)", project: project)
            }

            // No params: still the envelope, with the default limit applied.
            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let page = try res.content.decode(PagedResponse<VMDetailResponse>.self)
                #expect(page.total == 5)
                #expect(page.items.count == 5)
                #expect(page.limit == ListPaging.defaultLimit)
                #expect(page.offset == 0)
            }

            // Successive slices are disjoint and cover the whole set — the
            // stable createdAt/id ordering is what keeps offsets meaningful.
            var collected: [UUID] = []
            for offset in stride(from: 0, to: 5, by: 2) {
                try await app.test(.GET, "/api/vms?limit=2&offset=\(offset)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                } afterResponse: { res in
                    #expect(res.status == .ok)
                    let page = try res.content.decode(PagedResponse<VMDetailResponse>.self)
                    #expect(page.total == 5)
                    #expect(page.limit == 2)
                    #expect(page.offset == offset)
                    collected.append(contentsOf: page.items.compactMap(\.id))
                }
            }
            #expect(collected.count == 5)
            #expect(Set(collected).count == 5)

            // Past the end: an empty page, not an error, with total intact.
            try await app.test(.GET, "/api/vms?offset=50") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let page = try res.content.decode(PagedResponse<VMDetailResponse>.self)
                #expect(page.total == 5)
                #expect(page.items.isEmpty)
            }

            // An over-cap limit is clamped and the clamped value echoed back.
            try await app.test(.GET, "/api/vms?limit=9999") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let page = try res.content.decode(PagedResponse<VMDetailResponse>.self)
                #expect(page.limit == ListPaging.maxLimit)
            }

            // Garbage is a 400, not a silently ignored parameter.
            try await app.test(.GET, "/api/vms?limit=abc") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("total counts only the rows the caller is authorized to read")
    func totalRespectsAuthorization() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let builder = TestDataBuilder(db: app.db)

            let member = try await builder.createUser(
                username: "pagingmember", email: "pagingmember@example.com", isSystemAdmin: false)
            try await builder.addUserToOrganization(
                user: member, organization: testOrganization, role: "member")
            member.currentOrganizationId = testOrganization.id
            try await member.save(on: app.db)
            let memberToken = try await member.generateAPIKey(on: app.db)

            let granted = try await builder.createProject(
                name: "Granted", description: "readable", organization: testOrganization)
            let withheld = try await builder.createProject(
                name: "Withheld", description: "not readable", organization: testOrganization)
            try await RoleBindingService.grant(
                principalType: .user, principalID: member.id!, role: .viewer,
                nodeType: .project, nodeID: granted.id!, createdBy: nil, on: app.db)

            for index in 0..<3 {
                _ = try await builder.createVM(name: "granted-vm-\(index)", project: granted)
            }
            for index in 0..<2 {
                _ = try await builder.createVM(name: "withheld-vm-\(index)", project: withheld)
            }

            // A limit of 1 forces slicing, and total must still be the
            // authorization-filtered count (3), not the row count (5): the
            // page is cut after `canFilter`, never before.
            try await app.test(.GET, "/api/vms?limit=1") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let page = try res.content.decode(PagedResponse<VMDetailResponse>.self)
                #expect(page.total == 3)
                #expect(page.items.count == 1)
                #expect(page.items.allSatisfy { $0.name.hasPrefix("granted-vm-") })
            }
        }
    }
}
