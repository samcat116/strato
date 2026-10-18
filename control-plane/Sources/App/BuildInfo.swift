import Foundation
import Vapor

/// Build-time identity of this control-plane binary.
///
/// Values are injected as environment variables by the Dockerfile / Helm chart
/// (`STRATO_VERSION`, `STRATO_GIT_SHA`). When unset — e.g. a local `swift run`
/// dev build — they fall back to sentinel values so the health endpoint never
/// returns an empty identity.
enum BuildInfo {
    /// Human-readable version (e.g. a git tag or chart appVersion). "dev" when unset.
    static func version(configuration: ControlPlaneConfiguration) -> String {
        configuration.requiredString(.stratoVersion)
    }

    /// Git commit SHA the binary was built from. "unknown" when unset.
    static func gitSHA(configuration: ControlPlaneConfiguration) -> String {
        configuration.requiredString(.stratoGitSHA)
    }
}

/// The version agents are expected to run, compared against each agent's
/// reported build version to surface `updateAvailable` on `AgentResponse`.
///
/// Defaults to the control plane's own build version — in a released
/// deployment the control-plane and agent images share a tag, so "matches my
/// version" is the right baseline. `AGENT_TARGET_VERSION` overrides it for
/// deployments that pin agents separately. A "dev" target (local builds with
/// no injected identity) means there is nothing meaningful to compare
/// against, so no update is ever flagged.
enum AgentVersionTarget {
    /// Nil when no meaningful target exists (dev builds without an override).
    static func version(configuration: ControlPlaneConfiguration) -> String? {
        normalize(
            configuration.string(.agentTargetVersion)
                ?? BuildInfo.version(configuration: configuration))
    }

    static func normalize(_ raw: String) -> String? {
        raw == "dev" ? nil : raw
    }

    /// Release tags also travel as bare semver image tags. Main builds carry
    /// their commit in both binary and image identity; never discard it or a
    /// different main build would incorrectly satisfy an update assignment.
    static func canonical(_ version: String) -> String {
        if version.first == "v", version.dropFirst().first?.isNumber == true {
            return String(version.dropFirst())
        }
        return version
    }

    static func updateAvailable(agentVersion: String, target: String?) -> Bool {
        guard let target else { return false }
        return canonical(agentVersion) != canonical(target)
    }
}

/// Per-process runtime identity captured once at boot.
///
/// The motivating incident: a stale duplicate control plane silently intercepted
/// port 8080 and was indistinguishable from the real one. A per-boot `instanceId`
/// makes two processes answering the same port trivially distinguishable, and
/// `startedAt` ties a response back to a specific process start.
struct InstanceIdentity: Sendable {
    /// Unique to this process boot. Changes on every restart.
    let instanceId: UUID
    /// When this process captured its identity (≈ process start).
    let startedAt: Date
    /// Vapor environment name (development, production, testing, …).
    let environment: String

    init(instanceId: UUID = UUID(), environment: String) {
        self.instanceId = instanceId
        self.startedAt = Date()
        self.environment = environment
    }
}

// MARK: - Application Extension

extension Application {
    struct InstanceIdentityKey: StorageKey {
        typealias Value = InstanceIdentity
    }

    /// The control plane's per-boot identity. Configured once in `configure.swift`.
    var instanceIdentity: InstanceIdentity {
        get {
            guard let identity = self.storage[InstanceIdentityKey.self] else {
                fatalError("InstanceIdentity not configured. Set app.instanceIdentity in configure.swift")
            }
            return identity
        }
        set {
            self.setStorageValue(InstanceIdentityKey.self, to: newValue)
        }
    }
}

extension Request {
    var instanceIdentity: InstanceIdentity {
        self.application.instanceIdentity
    }
}
