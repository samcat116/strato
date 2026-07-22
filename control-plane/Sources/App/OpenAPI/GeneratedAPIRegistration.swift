import OpenAPIVapor
import Vapor

/// The route keys (`METHOD /path`, path parameters collapsed to `{}`) that were
/// registered by the generated OpenAPI transport rather than by a hand-written
/// controller.
///
/// Recorded at boot so `OpenAPISpecDriftTests` can assert the migrated surfaces
/// match the spec in both directions without having to guess which routes came
/// from where.
struct GeneratedAPIRouteKeys: StorageKey {
    typealias Value = Set<String>
}

extension Application {
    var generatedAPIRouteKeys: Set<String> {
        storage[GeneratedAPIRouteKeys.self] ?? []
    }
}

/// Registers every surface that has been migrated onto generated handlers
/// (issue #583). The set of operations served here is fixed by the `filter`
/// block in `openapi-generator-config.yaml`: the generator emits `APIProtocol`
/// from exactly those operations, so a surface is migrated by porting its
/// controller, listing its operations there, and conforming a service type.
func registerGeneratedAPIHandlers(on app: Application) throws {
    let before = Set(app.routes.all.map(generatedRouteKey))

    // The injection middleware must be the innermost one: it publishes the
    // request as a task local that the handlers read.
    let transport = VaporTransport(routesBuilder: app.grouped(OpenAPIRequestInjectionMiddleware()))
    try ProjectsAPIService().registerHandlers(on: transport)

    let after = Set(app.routes.all.map(generatedRouteKey))
    app.storage[GeneratedAPIRouteKeys.self] = after.subtracting(before)
}

/// `METHOD /path` with every path parameter collapsed to `{}`, so Vapor's
/// `:projectID` and the spec's `{projectID}` compare equal.
func generatedRouteKey(_ route: Route) -> String {
    let path = route.path.map { component -> String in
        if case .constant(let value) = component { return value }
        return "{}"
    }
    return "\(route.method.rawValue) /\(path.joined(separator: "/"))"
}
