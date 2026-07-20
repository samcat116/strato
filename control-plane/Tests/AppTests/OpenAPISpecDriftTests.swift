import Foundation
import Testing
import Vapor

@testable import App

/// Route-drift guard for the spec-first OpenAPI adoption (issue #557).
///
/// The OpenAPI document (`Sources/App/openapi.yaml`) describes a growing subset
/// of the API — the "documented surface." This suite boots the app, enumerates
/// every registered route, and enforces two invariants so the documented
/// controllers can't silently drift from the spec:
///
///   1. **Forward** — every registered route that belongs to a documented
///      controller must appear in the spec (or be an explicitly listed
///      streaming/WebSocket exception).
///   2. **Reverse** — every operation the spec describes must map to a real
///      registered route (catches typos and removed routes).
///
/// Controllers that have not been documented yet (IAM/org, agents, users,
/// OIDC/SCIM/SSF, audit, …) are outside the documented surface and are ignored;
/// they land in later phases of #557.
struct OpenAPISpecDriftTests {
    /// Path prefixes whose controllers are described in the spec. A registered
    /// route under one of these (or under an image subtree — images are nested
    /// beneath `/api/projects`) is expected to be documented.
    private static let documentedPrefixes: [String] = [
        "/health",
        "/api/vms",
        "/api/operations",
        "/api/sandboxes",
        "/api/volumes",
        "/api/networks",
        "/api/floating-ip-pools",
        "/api/floating-ips",
        "/api/openapi.yaml",
        "/api/docs",
    ]

    /// Routes inside the documented surface that are deliberately **not** modeled
    /// as OpenAPI operations: WebSocket/streaming endpoints and log queries
    /// (documented as prose in the spec's "Out of scope" section). Normalized as
    /// `METHOD /path` with `{}` for every path parameter.
    private static let documentedSurfaceExceptions: Set<String> = [
        "GET /api/vms/{}/console",
        "GET /api/vms/{}/logs",
        "GET /api/sandboxes/{}/logs",
        "POST /api/sandboxes/{}/exec",
        "GET /api/sandboxes/{}/exec/{}/attach",
    ]

    private static func isDocumentedSurface(_ path: String) -> Bool {
        // Image routes are nested under /api/projects/{projectID}/images.
        if path.contains("/images") { return true }
        return documentedPrefixes.contains { path.hasPrefix($0) }
    }

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

    private static func routeKey(_ route: Route) -> (key: String, path: String) {
        let components = route.path.map { component -> String in
            switch component {
            case .constant(let value): return value
            default: return "{}"
            }
        }
        let path = "/" + components.joined(separator: "/")
        return ("\(route.method.rawValue) \(path)", path)
    }

    /// Extract `METHOD /normalized/path` keys from the raw YAML by scanning the
    /// `paths:` block. Deliberately dependency-free (no YAML library in the test
    /// target); relies on the document's 2-space indentation.
    private static func specOperationKeys(from yaml: String) -> Set<String> {
        let httpMethods: Set<String> = [
            "get", "put", "post", "delete", "patch", "options", "head", "trace",
        ]
        var keys: Set<String> = []
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
                    keys.insert("\(token.uppercased()) \(path)")
                }
            }
        }
        return keys
    }

    @Test("openapi.yaml is bundled and served from the App resources")
    func specResourceIsBundled() async throws {
        let yaml = try #require(OpenAPISpec.yaml, "openapi.yaml was not bundled into the App target")
        #expect(yaml.contains("openapi: 3.0.3"))
    }

    @Test("Documented controllers stay in sync with openapi.yaml")
    func routesMatchSpec() async throws {
        let yaml = try #require(OpenAPISpec.yaml)
        let specKeys = Self.specOperationKeys(from: yaml)
        #expect(!specKeys.isEmpty, "Failed to parse any operations out of openapi.yaml")

        try await withApp { app in
            let routes = app.routes.all.map { Self.routeKey($0) }
            let registeredKeys = Set(routes.map { $0.key })

            // Forward: no undocumented routes on a documented controller.
            let undocumented =
                routes
                .filter { Self.isDocumentedSurface($0.path) }
                .filter { !specKeys.contains($0.key) }
                .filter { !Self.documentedSurfaceExceptions.contains($0.key) }
                .map { $0.key }
                .sorted()
            #expect(
                undocumented.isEmpty,
                """
                These routes are on a documented controller but missing from openapi.yaml. \
                Add them to the spec, or (for streaming/WebSocket routes) to \
                documentedSurfaceExceptions:
                \(undocumented.joined(separator: "\n"))
                """
            )

            // Reverse: every spec operation maps to a registered route.
            let missing = specKeys.subtracting(registeredKeys).sorted()
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
