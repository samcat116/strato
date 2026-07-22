import Foundation
import Testing
import Vapor

@testable import App

/// Route-drift guard for the spec-first OpenAPI adoption (issue #557).
///
/// As of Phase 2 (#582) the OpenAPI document (`Sources/App/openapi.yaml`)
/// describes the **entire** JSON API — there is no longer a quarantine list of
/// undocumented controllers. This suite boots the app, enumerates every
/// registered route, and enforces two invariants:
///
///   1. **Forward** — every registered route appears in the spec (or is an
///      explicitly listed WebSocket exception).
///   2. **Reverse** — every operation the spec describes maps to a real
///      registered route (catches typos and removed routes).
///
/// Adding a route without documenting it fails this suite, in either direction.
struct OpenAPISpecDriftTests {
    /// Routes deliberately **not** modeled as OpenAPI operations: WebSocket
    /// upgrades, which OpenAPI 3.0 cannot express. They are documented as prose
    /// in the spec's "Out of scope" section. Normalized as `METHOD /path` with
    /// `{}` for every path parameter.
    private static let webSocketExceptions: Set<String> = [
        "GET /agent/ws",
        "GET /api/vms/{}/console",
        "POST /api/sandboxes/{}/exec",
        "GET /api/sandboxes/{}/exec/{}/attach",
    ]

    /// Collapse every path parameter to `{}` so the spec's `{vmID}` and Vapor's
    /// `:vmID` compare equal regardless of the parameter's name.
    private static func normalizePath(_ path: String) -> String {
        var result = ""
        var depth = 0
        for ch in path {
            switch ch {
            case "{": depth += 1
            case "}": if depth > 0 { depth -= 1; result += "{}" }
            default: if depth == 0 { result.append(ch) }
            }
        }
        return result
    }

    /// A registered route, normalized for comparison against the spec.
    ///
    /// `catchallPrefix` is non-nil for routes registered with Vapor's `**`
    /// wildcard. The SCIM data plane
    /// (`/organizations/:organizationID/scim/v2/**`) is registered that way and
    /// dispatched internally by SwiftSCIM's request processor, so the spec
    /// describes the concrete resource endpoints that processor serves
    /// (`/Users`, `/Groups`, `/ServiceProviderConfig`, …) rather than the
    /// uninformative wildcard. Such a route is satisfied by any spec operation
    /// beneath its prefix, and conversely those operations are backed by it.
    private struct RegisteredRoute {
        let key: String
        let method: String
        let catchallPrefix: String?
    }

    private static func registeredRoute(_ route: Route) -> RegisteredRoute {
        var components: [String] = []
        var catchallPrefix: String?
        for component in route.path {
            switch component {
            case .constant(let value):
                components.append(value)
            case .catchall:
                // Everything before the wildcard is the prefix it serves.
                catchallPrefix = "/" + components.joined(separator: "/")
                components.append("{}")
            default:
                components.append("{}")
            }
        }
        let path = "/" + components.joined(separator: "/")
        let method = route.method.rawValue
        return RegisteredRoute(
            key: "\(method) \(path)",
            method: method,
            catchallPrefix: catchallPrefix
        )
    }

    /// Extract `METHOD /normalized/path` keys from the raw YAML by scanning the
    /// `paths:` block. Deliberately dependency-free (no YAML library in the test
    /// target); relies on the document's 2-space indentation (paths at 2 spaces,
    /// operations at 4). This is a hard invariant of openapi.yaml — reflowing to
    /// a different indent would break parsing, but fail-loud: a misparse yields a
    /// drift-test failure, never a silently missed route.
    private static func specOperationKeys(from yaml: String) -> Set<String> {
        Set(specOperations(from: yaml).map { $0.key })
    }

    /// Every operation in the spec as its route key plus, when declared, its
    /// `operationId` — the name the generator turns into a handler.
    private static func specOperations(from yaml: String) -> [(key: String, operationID: String?)] {
        let httpMethods: Set<String> = [
            "get", "put", "post", "delete", "patch", "options", "head", "trace",
        ]
        var operations: [(key: String, operationID: String?)] = []
        var inPaths = false
        var currentPath: String?

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Top-level key (column 0): enter/leave the paths block.
            if let first = line.first, first != " " {
                inPaths = line.hasPrefix("paths:")
                currentPath = nil
                continue
            }
            guard inPaths else { continue }

            // Path entry: exactly two-space indent, e.g. "  /api/vms:".
            if line.hasPrefix("  /"), !line.hasPrefix("   ") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let colon = trimmed.lastIndex(of: ":") {
                    currentPath = normalizePath(String(trimmed[trimmed.startIndex..<colon]))
                }
                continue
            }

            // Operation entry: exactly four-space indent, e.g. "    get:".
            if line.hasPrefix("    "), !line.hasPrefix("     ") {
                var token = line.trimmingCharacters(in: .whitespaces)
                if token.hasSuffix(":") { token.removeLast() }
                if httpMethods.contains(token), let path = currentPath {
                    operations.append((key: "\(token.uppercased()) \(path)", operationID: nil))
                }
                continue
            }

            // `operationId:` belongs to the operation entry above it.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("operationId:"), !operations.isEmpty {
                let id = trimmed.dropFirst("operationId:".count).trimmingCharacters(in: .whitespaces)
                operations[operations.count - 1].operationID = id
            }
        }
        return operations
    }

    /// The `filter.operations` list from `openapi-generator-config.yaml` — the
    /// operations the generator emits into `APIProtocol`, i.e. exactly the
    /// surfaces migrated onto generated handlers.
    private static func migratedOperationIDs() throws -> [String] {
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // control-plane
            .appendingPathComponent("Sources/App/openapi-generator-config.yaml")
        let yaml = try String(contentsOf: configURL, encoding: .utf8)

        var ids: [String] = []
        var inOperations = false
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "operations:" {
                inOperations = true
                continue
            }
            guard inOperations else { continue }
            guard trimmed.hasPrefix("- ") else { break }
            ids.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        return ids
    }

    @Test("openapi.yaml is bundled and served from the App resources")
    func specResourceIsBundled() async throws {
        let yaml = try #require(OpenAPISpec.yaml, "openapi.yaml was not bundled into the App target")
        #expect(yaml.contains("openapi: 3.0.3"))
    }

    /// Phase 3 (#583) migrated the projects surface onto handlers generated from
    /// the spec. For a migrated surface the guarantee is stronger than "the route
    /// exists": the generator emits `APIProtocol` from the operations listed in
    /// `openapi-generator-config.yaml`, the compiler forces `ProjectsAPIService`
    /// to implement all of them, and this test closes the loop by checking that
    /// each one is actually served — on the path and method the spec gives it,
    /// by the generated transport, and by nothing else.
    @Test("Migrated operations are served by generated handlers on their spec routes")
    func migratedOperationsAreGeneratorServed() async throws {
        let yaml = try #require(OpenAPISpec.yaml)
        let specOperations = Self.specOperations(from: yaml)
        var keysByOperationID: [String: String] = [:]
        for operation in specOperations {
            guard let id = operation.operationID else { continue }
            #expect(keysByOperationID[id] == nil, "Duplicate operationId in openapi.yaml: \(id)")
            keysByOperationID[id] = operation.key
        }

        let migratedIDs = try Self.migratedOperationIDs()
        #expect(!migratedIDs.isEmpty, "Failed to parse filter.operations out of openapi-generator-config.yaml")

        // Forward: every generator-filtered operation is a real spec operation.
        var expectedKeys: Set<String> = []
        for id in migratedIDs {
            let key = keysByOperationID[id]
            #expect(
                key != nil,
                "openapi-generator-config.yaml filters on '\(id)', which openapi.yaml does not define"
            )
            if let key { expectedKeys.insert(key) }
        }

        try await withApp { app in
            // Reverse: the routes the generated transport registered are exactly
            // those operations — no more (a stale handler) and no fewer (an
            // operation whose route never got registered).
            #expect(
                app.generatedAPIRouteKeys == expectedKeys,
                """
                Generated handler routes and the spec's migrated operations disagree.
                Only in the transport: \(app.generatedAPIRouteKeys.subtracting(expectedKeys).sorted())
                Only in the spec:      \(expectedKeys.subtracting(app.generatedAPIRouteKeys).sorted())
                """
            )

            // And no hand-written controller still answers on those routes: a
            // leftover registration would shadow the generated handler for every
            // request, silently un-migrating the surface.
            var registrations: [String: Int] = [:]
            for route in app.routes.all {
                registrations[Self.registeredRoute(route).key, default: 0] += 1
            }
            let shadowed = expectedKeys.filter { (registrations[$0] ?? 0) != 1 }.sorted()
            #expect(
                shadowed.isEmpty,
                """
                These migrated routes are registered more than once — a hand-written \
                controller is shadowing the generated handler:
                \(shadowed.joined(separator: "\n"))
                """
            )
        }
    }

    @Test("Every registered route is documented in openapi.yaml")
    func routesMatchSpec() async throws {
        let yaml = try #require(OpenAPISpec.yaml)
        let specKeys = Self.specOperationKeys(from: yaml)
        #expect(!specKeys.isEmpty, "Failed to parse any operations out of openapi.yaml")

        try await withApp { app in
            let routes = app.routes.all.map { Self.registeredRoute($0) }
            let registeredKeys = Set(routes.map { $0.key })

            /// Spec operations served by a catch-all route, as `METHOD /prefix`.
            let catchallPrefixes: [(method: String, prefix: String)] = routes.compactMap {
                guard let prefix = $0.catchallPrefix else { return nil }
                return ($0.method, prefix)
            }
            func specCoversCatchall(method: String, prefix: String) -> Bool {
                specKeys.contains { $0.hasPrefix("\(method) \(prefix)/") }
            }
            func catchallCoversSpec(_ specKey: String) -> Bool {
                catchallPrefixes.contains { specKey.hasPrefix("\($0.method) \($0.prefix)/") }
            }

            // Forward: no undocumented registered route.
            let undocumented =
                routes
                .filter { route in
                    if let prefix = route.catchallPrefix {
                        return !specCoversCatchall(method: route.method, prefix: prefix)
                    }
                    return !specKeys.contains(route.key)
                }
                .filter { !Self.webSocketExceptions.contains($0.key) }
                .map { $0.key }
                .sorted()
            #expect(
                undocumented.isEmpty,
                """
                These registered routes are missing from openapi.yaml. Add them to \
                the spec, or (for WebSocket upgrades) to webSocketExceptions:
                \(undocumented.joined(separator: "\n"))
                """
            )

            // Reverse: every spec operation maps to a registered route.
            let missing =
                specKeys
                .subtracting(registeredKeys)
                .filter { !catchallCoversSpec($0) }
                .sorted()
            #expect(
                missing.isEmpty,
                """
                openapi.yaml describes operations with no matching registered route \
                (typo, or the route was removed):
                \(missing.joined(separator: "\n"))
                """
            )
        }
    }
}
