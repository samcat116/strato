/// Shared names for identifiers that travel through Strato's console and OTLP logs.
///
/// These keys follow OpenTelemetry semantic conventions where one exists and use
/// dot-separated Strato namespaces for product-specific resources.
public enum LogMetadata {
    public enum Key {
        public static let serviceName = "service.name"
        public static let serviceInstanceID = "service.instance.id"
        public static let deploymentEnvironmentName = "deployment.environment.name"
        public static let serviceVersion = "service.version"

        public static let requestID = "strato.request.id"
        public static let operationID = "strato.operation.id"
        public static let agentID = "strato.agent.id"
        public static let agentName = "strato.agent.name"
        public static let agentIdentity = "strato.agent.identity"
        public static let vmID = "strato.vm.id"
        public static let sandboxID = "strato.sandbox.id"
        public static let projectID = "strato.project.id"
        public static let sessionID = "strato.session.id"
        public static let sessionKind = "strato.session.kind"
    }

    /// Legacy spellings accepted at log-handler boundaries during the STR-284
    /// migration. Producers should emit only the canonical keys above.
    public static let legacyAliases: [String: String] = [
        "requestID": Key.requestID,
        "requestId": Key.requestID,
        "request_id": Key.requestID,
        "request-id": Key.requestID,
        "vmID": Key.vmID,
        "vmId": Key.vmID,
        "vm_id": Key.vmID,
        "sandboxID": Key.sandboxID,
        "sandboxId": Key.sandboxID,
        "sandbox_id": Key.sandboxID,
        "projectID": Key.projectID,
        "projectId": Key.projectID,
        "project_id": Key.projectID,
    ]

    /// The producer-compatibility window is intentionally time-bounded. Remove
    /// the aliases after this date once every producer emits canonical names.
    public static let legacyAliasRemovalDate = "2026-12-01"

    public static func canonicalKey(for key: String) -> String {
        legacyAliases[key] ?? key
    }

    /// Select the canonical entity key for the two guest-exec resource kinds.
    public static func guestResourceIDKey(for kind: GuestResourceKind) -> String {
        switch kind {
        case .virtualMachine: Key.vmID
        case .sandbox: Key.sandboxID
        }
    }
}
