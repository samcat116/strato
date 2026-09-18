import AppTestSupport
import Fluent
import Testing
import Vapor
@testable import App

@Suite("Network fabric mutation deadlines", .serialized)
struct NetworkFabricGenerationTests {
    @Test(arguments: [false, true])
    func networkMutationRenewsWithoutShorteningDeadline(guarded: Bool) async throws {
        try await withProjectApp(prefix: "fabric-deadline") { app, builder, fixture in
            let siteID = try await builder.placementSite(for: fixture.project).requireID()
            let network = LogicalNetwork(
                name: "deadline", subnet: "192.168.1.0/24", gateway: "192.168.1.1",
                projectID: try fixture.project.requireID(), siteID: siteID)
            network.convergenceDeadline = Date().addingTimeInterval(1)
            try await network.save(on: app.db)
            let id = try network.requireID()
            let before = Date()
            let outcome = try await DesiredStateGenerationWriter.advance(
                schema: LogicalNetwork.schema, id: id,
                expectedGeneration: guarded ? network.generation : nil, on: app.db)
            #expect(outcome == .applied(network.generation + 1))
            let renewed = try #require(try await LogicalNetwork.find(id, on: app.db))
            #expect(try #require(renewed.convergenceDeadline) >= before.addingTimeInterval(180))

            let extended = Date().addingTimeInterval(600)
            renewed.convergenceDeadline = extended
            try await renewed.save(on: app.db)
            _ = try await DesiredStateGenerationWriter.advance(
                schema: LogicalNetwork.schema, id: id,
                expectedGeneration: guarded ? renewed.generation : nil, on: app.db)
            let preserved = try #require(try await LogicalNetwork.find(id, on: app.db))
            #expect(abs(try #require(preserved.convergenceDeadline).timeIntervalSince(extended)) < 0.001)
        }
    }

    @Test(arguments: [false, true])
    func groupMutationRenewsOnlyScopedGroups(guarded: Bool) async throws {
        try await withProjectApp(prefix: "sg-deadline") { app, builder, fixture in
            let group = SecurityGroup(projectID: try fixture.project.requireID(), name: "deadline")
            try await group.save(on: app.db)
            let id = try group.requireID()
            _ = try await DesiredStateGenerationWriter.advance(
                schema: SecurityGroup.schema, id: id,
                expectedGeneration: guarded ? group.generation : nil, on: app.db)
            let unattached = try #require(try await SecurityGroup.find(id, on: app.db))
            #expect(unattached.convergenceDeadline == nil)

            let siteID = try await builder.placementSite(for: fixture.project).requireID()
            try await SecurityGroupSiteObservation(securityGroupID: id, siteID: siteID).save(on: app.db)
            // Cover a converged group (nil), an almost-expired generation,
            // and an existing longer-running mutation's runway.
            for deadline: Date? in [nil, Date().addingTimeInterval(1), Date().addingTimeInterval(600)] {
                let current = try #require(try await SecurityGroup.find(id, on: app.db))
                current.convergenceDeadline = deadline
                try await current.save(on: app.db)
                let before = Date()
                let outcome = try await DesiredStateGenerationWriter.advance(
                    schema: SecurityGroup.schema, id: id,
                    expectedGeneration: guarded ? current.generation : nil, on: app.db)
                #expect(outcome == .applied(current.generation + 1))
                let renewed = try #require(try await SecurityGroup.find(id, on: app.db))
                let actual = try #require(renewed.convergenceDeadline)
                #expect(actual >= before.addingTimeInterval(180))
                if let deadline { #expect(actual.timeIntervalSince(deadline) > -0.001) }
            }
        }
    }
}
