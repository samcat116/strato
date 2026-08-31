import Foundation
import Vapor

extension Application {
    /// Resolves immutable startup configuration and installs process-wide
    /// facilities before any client or request pipeline is constructed.
    func bootstrapFoundation(environmentVariables: [String: String]) async throws {
        controlPlaneConfiguration = try await .load(
            environmentVariables: environmentVariables,
            for: environment)

        let identity = InstanceIdentity(environment: environment.name)
        instanceIdentity = identity
        logger.info(
            "Control plane booting",
            metadata: [
                "instanceId": .string(identity.instanceId.uuidString),
                "version": .string(BuildInfo.version(configuration: controlPlaneConfiguration)),
                "gitSHA": .string(BuildInfo.gitSHA(configuration: controlPlaneConfiguration)),
                "environment": .string(identity.environment),
            ])

        try bootstrapObservability()
        setUpBackgroundTaskRegistry()
        proxyTrust = .fromConfiguration(controlPlaneConfiguration)
        configureSharedHTTPClientPolicy()
        configureRequestBodyLimit()
    }

    private func configureSharedHTTPClientPolicy() {
        // Tenant-influenced destinations use GuardedHTTPClient. Refusing
        // redirects here prevents an operator-configured client from silently
        // following an unexpected redirect to an unvalidated address.
        http.client.configuration.redirectConfiguration = .disallow
    }

    private func configureRequestBodyLimit() {
        // Streaming upload routes enforce their own limits and do not collect
        // through this application-wide ceiling.
        routes.defaultMaxBodySize = "1mb"
    }
}
