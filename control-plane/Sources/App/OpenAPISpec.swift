import Foundation

/// Access to the spec-first OpenAPI document (`Sources/App/openapi.yaml`, issue
/// #557). The same file feeds the swift-openapi-generator build plugin and is
/// shipped as a bundle resource so the control plane can serve it verbatim at
/// `GET /api/openapi.yaml`.
enum OpenAPISpec {
    /// The raw YAML, loaded once from the App bundle. `nil` only if the resource
    /// was not bundled into the build (the route-drift test asserts otherwise).
    static let yaml: String? = {
        guard let url = Bundle.module.url(forResource: "openapi", withExtension: "yaml"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }()
}
