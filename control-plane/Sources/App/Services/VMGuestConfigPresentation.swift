import Crypto
import Foundation
import StratoShared
import Vapor

struct VMGuestConfigurationItem: Content {
    enum State: String, Codable { case matched, drift, unknown, stale, failed }
    let section: String
    let identity: String
    let desired: String
    let observed: String?
    let state: State
    let error: String?
}

enum VMGuestConfigPresentation {
    static let failure = "Guest configuration failed. Repair the guest, then retry with a new generation."
    static let operationFailure =
        "Guest configuration did not complete for this request. Check the VM, then retry with a new generation."
    /// Only exact, source-defined diagnostics can leave the redacted report.
    /// Unrecognized guest text may contain arbitrary file/command content.
    static func safeFailure(_ reason: String?) -> String {
        switch reason {
        case "package operation budget exhausted (mirror or package manager unavailable)",
            "package operation failed (package manager or mirror unavailable)":
            return
                "Package operation failed or exceeded its budget. Check the package manager and mirror, then retry with a new generation."
        case "managed path contains a symlink":
            return "The managed file path contains a symlink. Repair the path, then retry with a new generation."
        case "guest convergence budget exhausted", "guest observation/operation budget exhausted":
            return "Guest configuration exceeded its budget. Repair the guest, then retry with a new generation."
        case "guest convergence interrupted; submit a new VM generation to retry":
            return "Guest configuration was interrupted. Repair the guest, then retry with a new generation."
        case "package read-back differs from desired state", "file read-back differs from desired state",
            "service read-back differs from desired state", "sysctl read-back differs from desired state":
            return
                "Guest read-back differs from desired configuration. Check the failed item, then retry with a new generation."
        case "guest convergence journal is unreadable", "guest convergence journal is corrupt",
            "guest convergence journal is oversized":
            return
                "The guest convergence journal is unavailable or invalid. Repair the journal, then retry with a new generation."
        default: return failure
        }
    }
    static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func whitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
    static func validate(_ report: GuestConfigObservation, config: GuestConfig, generation: Int64) throws {
        try report.validateProtocol()
        try config.validateProtocol()
        try report.validate(
            for: config, generation: generation,
            expectedFileSHA256: Dictionary(
                uniqueKeysWithValues: config.files.values.map { ($0.path, hash($0.content)) }))
        // Linux paths are byte identities. Canonical Unicode String equality
        // must not turn another path into a managed identity.
        guard
            report.files.values.allSatisfy({ fact in config.files.values.contains { sameBytes($0.path, fact.path) } }),
            (report.hasFailedItem ? report.failedItem : nil).map({ item in
                item.section != .files || config.files.values.contains { sameBytes($0.path, item.identity) }
            }) ?? true
        else { throw GuestConfigObservationError.invalid }
    }
    /// The shared validator checks identities and shape; compare file hashes
    /// here too, since a nonnil hash alone is not proof of desired contents.
    static func matches(_ observation: GuestConfigObservation, config: GuestConfig, generation: Int64) -> Bool {
        guard observation.status == .converged,
            (try? validate(observation, config: config, generation: generation)) != nil
        else { return false }
        return config.files.values.allSatisfy { item in
            observation.files.values.first(where: { sameBytes($0.path, item.path) }).map {
                $0.hasSha256 && $0.sha256 == hash(item.content)
            } == true
        }
            && config.sysctls.values.allSatisfy { item in
                observation.sysctls.values.first(where: { $0.key == item.key }).map {
                    $0.hasValue && sameBytes(whitespace($0.value), whitespace(item.value))
                } == true
            }
    }
    static func current(_ vm: VM) -> Bool {
        guard let evidence = vm.guestConfigEvidence else { return false }
        return evidence.available && evidence.agentID == vm.hypervisorId
            && evidence.observation.generation == vm.generation
    }
    static func converged(_ vm: VM) -> Bool {
        guard let config = vm.guestConfig, !config.isEmpty else { return true }
        guard current(vm), let evidence = vm.guestConfigEvidence else { return false }
        return matches(evidence.observation, config: config, generation: vm.generation)
            && vm.failedGeneration != vm.generation
    }
    static func failureGeneration(_ vm: VM) -> Int64? {
        vm.guestConfigFailedGeneration
            ?? (vm.guestConfigEvidence?.observation.status == .failed
                ? vm.guestConfigEvidence?.observation.generation : nil)
    }
    static func status(_ vm: VM, agentOnline: Bool) -> String {
        guard let config = vm.guestConfig, !config.isEmpty else { return "unmanaged" }
        if failureGeneration(vm) == vm.generation { return "failed" }
        if vm.desiredStatus != .running { return "deferred" }
        if !agentOnline || vm.guestAgentObservation?.reachable == false { return "unavailable" }
        if let evidence = vm.guestConfigEvidence,
            evidence.observation.generation != vm.generation || evidence.agentID != vm.hypervisorId
        {
            return "stale"
        }
        guard current(vm) else { return "pending" }
        return converged(vm) && vm.isConverged ? "converged" : "pending"
    }
    static func items(_ vm: VM, agentOnline: Bool) -> [VMGuestConfigurationItem] {
        guard let config = vm.guestConfig else { return [] }
        let report = vm.guestConfigEvidence?.observation
        let failedItem = report.flatMap { $0.hasFailedItem ? $0.failedItem : nil }
        let reportError = report.flatMap { $0.hasError ? $0.error : nil }
        let fresh =
            current(vm) && agentOnline && vm.guestAgentObservation?.reachable != false
            && vm.status == .running && vm.desiredStatus == .running
        func item(_ section: String, _ identity: String, _ desired: String, _ observed: String?, _ matches: Bool?)
            -> VMGuestConfigurationItem
        {
            let failed =
                report?.generation == vm.generation && report?.status == .failed
                && failedItem?.section.protocolValue == section
                && failedItem?.identity.utf8.elementsEqual(identity.utf8) == true
            let state: VMGuestConfigurationItem.State
            if failed {
                state = .failed
            } else if !fresh, observed != nil {
                state = .stale
            } else if !fresh || matches == nil {
                state = .unknown
            } else {
                state = matches == true ? .matched : .drift
            }
            return .init(
                section: section, identity: identity, desired: desired, observed: observed,
                state: state, error: failed ? safeFailure(reportError) : nil)
        }
        var rows: [VMGuestConfigurationItem] = []
        for desired in config.packages.values {
            let fact = report?.packages.values.first { $0.name == desired.name }
            rows.append(
                item(
                    "packages", desired.name, desired.state.protocolValue,
                    fact.map { $0.hasVersion ? $0.version : "absent" },
                    fact.map { $0.hasVersion == (desired.state == .present) }))
        }
        for desired in config.files.values {
            let fact = report?.files.values.first { sameBytes($0.path, desired.path) }
            let actual = fact.flatMap { value in
                !value.hasSha256 && !value.hasMode
                    ? nil
                    : "sha256 \(value.hasSha256 ? value.sha256 : "unknown"); mode \(value.hasMode ? value.mode : "unknown")"
            }
            rows.append(
                item(
                    "files", desired.path, "sha256 \(hash(desired.content)); mode \(desired.mode)", actual,
                    fact.flatMap {
                        $0.hasSha256 && $0.hasMode
                            ? $0.sha256 == hash(desired.content) && $0.mode == desired.mode : nil
                    }))
        }
        for desired in config.services.values {
            let fact = report?.services.values.first { $0.name == desired.name }
            let actual = fact.flatMap { value in
                !value.hasEnabled && !value.hasActiveState
                    ? nil
                    : "\(value.hasEnabled ? (value.enabled ? "enabled" : "disabled") : "unknown") at boot; active \(value.hasActiveState ? value.activeState : "unknown")"
            }
            rows.append(
                item(
                    "services", desired.name, desired.enabled ? "enabled at boot" : "disabled at boot", actual,
                    fact.flatMap { $0.hasEnabled ? $0.enabled == desired.enabled : nil }))
        }
        for desired in config.sysctls.values {
            let fact = report?.sysctls.values.first { $0.key == desired.key }
            rows.append(
                item(
                    "sysctls", desired.key, desired.value, fact.flatMap { $0.hasValue ? $0.value : nil },
                    fact.flatMap { $0.hasValue ? sameBytes(whitespace($0.value), whitespace(desired.value)) : nil }))
        }
        return rows
    }
}
