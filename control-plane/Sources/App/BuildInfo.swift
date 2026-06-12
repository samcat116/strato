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
    static let version: String = Environment.get("STRATO_VERSION") ?? "dev"

    /// Git commit SHA the binary was built from. "unknown" when unset.
    static let gitSHA: String = Environment.get("STRATO_GIT_SHA") ?? "unknown"
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

    init(environment: String) {
        self.instanceId = UUID()
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
            self.storage[InstanceIdentityKey.self] = newValue
        }
    }
}

extension Request {
    var instanceIdentity: InstanceIdentity {
        self.application.instanceIdentity
    }
}
