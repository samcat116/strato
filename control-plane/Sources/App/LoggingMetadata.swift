import Foundation
import Logging
import StratoShared

enum ControlPlaneLoggingMetadata {
    static func base(
        environmentName: String,
        environmentVariables: [String: String]
    ) -> Logger.Metadata {
        [
            LogMetadata.Key.serviceName: .string(
                nonEmpty(environmentVariables["OTEL_SERVICE_NAME"]) ?? "strato-control-plane"),
            LogMetadata.Key.serviceVersion: .string(
                nonEmpty(environmentVariables["STRATO_VERSION"]) ?? "dev"),
            LogMetadata.Key.deploymentEnvironmentName: .string(environmentName),
        ]
    }

    static func provider(
        environmentName: String,
        environmentVariables: [String: String]
    ) -> Logger.MetadataProvider {
        let metadata = base(
            environmentName: environmentName,
            environmentVariables: environmentVariables)
        return Logger.MetadataProvider { metadata }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
