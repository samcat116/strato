import Foundation
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("UUID route parameters")
struct RequireUUIDParameterTests {
    @Test("Valid UUIDs parse and missing or malformed values retain the caller's 400 reason")
    func routeParameters() async throws {
        let app = try await Application.make(.testing)
        do {
            let request = Request(application: app, on: app.eventLoopGroup.any())
            let id = UUID()
            request.parameters.set("resourceID", to: id.uuidString.lowercased())
            #expect(try request.requireUUIDParameter("resourceID", reason: "Invalid resource ID") == id)
            for raw in [nil, "", "not-a-uuid"] as [String?] {
                let invalid = Request(application: app, on: app.eventLoopGroup.any())
                if let raw { invalid.parameters.set("resourceID", to: raw) }
                for reason in ["Invalid resource ID", "Role id must be a UUID", "Invalid project or image ID"] {
                    do {
                        _ = try invalid.requireUUIDParameter("resourceID", reason: reason)
                        Issue.record("Expected a bad request for \(String(describing: raw))")
                    } catch let abort as Abort {
                        #expect(abort.status == .badRequest)
                        #expect(abort.reason == reason)
                    }
                }
            }
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
