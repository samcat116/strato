import Logging
import StratoShared

enum ControlPlaneLoggingMetadata {
    static func base(
        serviceName: String,
        serviceInstanceID: String,
        environmentName: String,
        serviceVersion: String
    ) -> Logger.Metadata {
        [
            LogMetadata.Key.serviceName: .string(
                nonEmpty(serviceName) ?? "strato-control-plane"),
            LogMetadata.Key.serviceInstanceID: .string(serviceInstanceID),
            LogMetadata.Key.serviceVersion: .string(
                nonEmpty(serviceVersion) ?? "dev"),
            LogMetadata.Key.deploymentEnvironmentName: .string(environmentName),
        ]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
