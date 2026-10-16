import Foundation

/// Frozen update-only v1 contract. It has no workload DTOs or envelope routing.
/// Keep this shape across workload wire changes; a new exchange needs a new path.
public struct AgentUpdateBridgeResponse: Codable, Sendable {
    public static let path = "/agent/update/v1"
    public static let wireVersionHeader = "Strato-Workload-Wire-Version"
    public let exchangeVersion: Int
    public let workloadWireVersion: Int
    public let update: Artifact?

    public struct Artifact: Codable, Sendable {
        public let targetVersion: String
        public let artifactURL: String
        public let sha256: String
        public let artifactKind: String
        public let tarballMember: String?

        public init(_ update: DesiredAgentUpdate) {
            targetVersion = update.targetVersion
            artifactURL = update.artifactURL
            sha256 = update.sha256
            artifactKind = update.artifactKind.rawValue
            tarballMember = update.tarballMember
        }

        public func desiredUpdate() throws -> DesiredAgentUpdate {
            guard let kind = AgentUpdateArtifactKind(rawValue: artifactKind) else {
                throw BridgeError.unsupportedArtifact
            }
            return DesiredAgentUpdate(
                targetVersion: targetVersion, artifactURL: artifactURL, sha256: sha256,
                artifactKind: kind, tarballMember: tarballMember)
        }
    }

    public enum BridgeError: Error { case unsupportedExchange, unsupportedArtifact }

    public init(workloadWireVersion: Int, update: DesiredAgentUpdate?) {
        exchangeVersion = 1
        self.workloadWireVersion = workloadWireVersion
        self.update = update.map(Artifact.init)
    }

    /// Matching versions continue through ordinary registration and sync.
    /// Skew can deliver only the deliberately small update artifact contract.
    public func skewUpdate(agentWireVersion: Int) throws -> DesiredAgentUpdate? {
        guard exchangeVersion == 1 else { throw BridgeError.unsupportedExchange }
        guard workloadWireVersion != agentWireVersion else { return nil }
        return try update?.desiredUpdate()
    }
}
