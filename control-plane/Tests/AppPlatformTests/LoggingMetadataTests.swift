import Logging
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Logging metadata")
struct LoggingMetadataTests {
    @Test("Control-plane base metadata uses stable canonical keys")
    func baseMetadata() {
        let metadata = ControlPlaneLoggingMetadata.base(
            serviceName: "strato-api",
            serviceInstanceID: "replica-284",
            environmentName: "production",
            serviceVersion: "v1.2.3")

        #expect(metadata["service.name"] == "strato-api")
        #expect(metadata["service.instance.id"] == "replica-284")
        #expect(metadata["service.version"] == "v1.2.3")
        #expect(metadata["deployment.environment.name"] == "production")
    }

    @Test("Empty base metadata overrides fall back to deployment defaults")
    func emptyOverridesFallBack() {
        let metadata = ControlPlaneLoggingMetadata.base(
            serviceName: "",
            serviceInstanceID: "replica-284",
            environmentName: "development",
            serviceVersion: "")

        #expect(metadata["service.name"] == "strato-control-plane")
        #expect(metadata["service.version"] == "dev")
    }

    @Test("Request log metadata retains Vapor's key and adds the canonical key")
    func requestMetadataTransition() async throws {
        let app = try await Application.make(.testing)
        do {
            app.middleware.use(RequestLogMetadataMiddleware())
            app.get("metadata") { request -> String in
                let legacy = metadataString(request.logger[metadataKey: "request-id"])
                let canonical = metadataString(
                    request.logger[metadataKey: "strato.request.id"])
                return "\(legacy ?? "missing")|\(canonical ?? "missing")"
            }

            try await app.test(.GET, "/metadata", headers: ["X-Request-ID": "request-284"]) {
                response async throws in
                #expect(response.status == .ok)
                #expect(response.body.string == "request-284|request-284")
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

private func metadataString(_ value: Logger.Metadata.Value?) -> String? {
    guard case .string(let value) = value else { return nil }
    return value
}
