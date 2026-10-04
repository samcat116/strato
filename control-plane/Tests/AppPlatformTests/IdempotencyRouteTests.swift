import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Idempotency route boundary")
struct IdempotencyRouteTests {
    private actor SideEffects {
        private(set) var count = 0
        func commit() { count += 1 }
    }

    private struct MutationResponder: AsyncResponder {
        let effects: SideEffects
        func respond(to request: Request) async throws -> Response {
            await effects.commit()
            return Response(status: .created)
        }
    }

    private func routeKey(_ route: Route) -> String {
        let path = route.path.map { component -> String in
            if case .parameter = component { return "{}" }
            return component.description
        }.joined(separator: "/")
        return "\(route.method) /\(path)"
    }

    private func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: #"\{[^}]+\}"#, with: "{}", options: .regularExpression)
    }

    @Test("registered support, OpenAPI header parameters and audited inventory agree")
    func supportedInventoryMatchesSpec() async throws {
        let app = try await Application.make(.testing)
        do {
            try routes(app)
            let declared = Set(app.routes.all.filter { $0.isIdempotencySupported }.map(routeKey))
            let yaml = try #require(OpenAPISpec.yaml)
            var path = ""
            var method = ""
            var documented: Set<String> = []
            for line in yaml.split(separator: "\n") {
                if line.hasPrefix("  /"), !line.hasPrefix("   ") {
                    path = String(line.trimmingCharacters(in: .whitespaces).dropLast())
                }
                if line.hasPrefix("    "), !line.hasPrefix("     ") {
                    method = String(line.trimmingCharacters(in: .whitespaces).dropLast()).uppercased()
                }
                if line.contains("#/components/parameters/IdempotencyKey") {
                    documented.insert("\(method) \(normalized(path))")
                }
            }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let inventory = try String(
                contentsOf: root.appendingPathComponent("docs/architecture/idempotency.md"), encoding: .utf8)
            let audited = Set(
                inventory.split(separator: "\n").compactMap { line -> String? in
                    let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard cells.count == 3, ["POST", "PUT", "PATCH", "DELETE"].contains(cells[0]) else { return nil }
                    return "\(cells[0]) \(normalized(cells[1].replacingOccurrences(of: "`", with: "")))"
                })
            #expect(declared.count == 32)
            #expect(declared == documented)
            #expect(declared == audited)
            #expect(
                app.routes.all.filter { $0.isIdempotencySupported }.allSatisfy {
                    IdempotencyMiddleware.isMutation($0.method)
                })
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("every unmarked mutation rejects keys before any handler effects; headerless behavior passes through")
    func everyUnsupportedMutationFailsClosed() async throws {
        let app = try await Application.make(.testing)
        do {
            try routes(app)
            // Future routes need no allowlist update to receive the same protection.
            app.post("new-mutation") { _ in HTTPStatus.created }
            let mutations = app.routes.all.filter { IdempotencyMiddleware.isMutation($0.method) }
            #expect(mutations.count > 32)
            for route in mutations {
                let effects = SideEffects()
                let next = MutationResponder(effects: effects)
                let request = Request(
                    application: app, method: route.method, url: URI(path: "/fixture"), on: app.eventLoopGroup.next())
                request.route = route
                if !route.isIdempotencySupported {
                    // Refuse even malformed keys on unsupported routes, before
                    // authentication, decoding, DB/resource/event/session writes.
                    for key in ["retry", "", String(repeating: "k", count: 256)] {
                        request.headers.replaceOrAdd(name: IdempotencyMiddleware.headerName, value: key)
                        do {
                            _ = try await IdempotencyMiddleware().respond(to: request, chainingTo: next)
                            Issue.record("Key accepted on \(routeKey(route))")
                        } catch let error as Abort {
                            #expect(error.status == .badRequest)
                            #expect(error.reason == "Idempotency-Key is not supported for this route")
                        }
                        #expect(await effects.count == 0)
                        #expect(request.idempotencyContext == nil)
                    }
                }
                request.headers.remove(name: IdempotencyMiddleware.headerName)
                let response = try await IdempotencyMiddleware().respond(to: request, chainingTo: next)
                #expect(response.status == .created)
                #expect(await effects.count == 1)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("supported declarations retain the existing key validation before handler effects")
    func supportedKeyBoundsRemainEnforced() async throws {
        let app = try await Application.make(.testing)
        do {
            let route = app.post("supported") { _ in HTTPStatus.created }.supportsIdempotency()
            let effects = SideEffects()
            let request = Request(
                application: app, method: .POST, url: URI(path: "/supported"), on: app.eventLoopGroup.next())
            request.route = route
            for (key, reason) in [
                ("", "Idempotency-Key must not be empty"),
                (String(repeating: "k", count: 256), "Idempotency-Key must not exceed 255 characters"),
            ] {
                request.headers.replaceOrAdd(name: IdempotencyMiddleware.headerName, value: key)
                do {
                    _ = try await IdempotencyMiddleware().respond(
                        to: request, chainingTo: MutationResponder(effects: effects))
                    Issue.record("Malformed key accepted")
                } catch let error as Abort {
                    #expect(error.status == .badRequest)
                    #expect(error.reason == reason)
                }
                #expect(await effects.count == 0)
                #expect(request.idempotencyContext == nil)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("new HTTP routes expose the public refusal contract; reads still ignore the header")
    func matchedRoutePublicContract() async throws {
        let app = try await Application.make(.testing)
        do {
            app.middleware.use(ErrorMiddleware.default(environment: .testing))
            app.middleware.use(IdempotencyMiddleware())
            let effects = SideEffects()
            app.post("future") { _ -> HTTPStatus in
                await effects.commit()
                return .created
            }
            app.get("future") { _ in HTTPStatus.ok }
            try await app.testing().test(.POST, "/future", headers: ["Idempotency-Key": "retry"]) { response in
                #expect(response.status == .badRequest)
                let body =
                    try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                #expect(body?["error"] as? Bool == true)
                #expect(body?["reason"] as? String == "Idempotency-Key is not supported for this route")
            }
            #expect(await effects.count == 0)
            try await app.testing().test(.POST, "/future") { response in
                #expect(response.status == .created)
            }
            #expect(await effects.count == 1)
            try await app.testing().test(.GET, "/future", headers: ["Idempotency-Key": "retry"]) { response in
                #expect(response.status == .ok)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
