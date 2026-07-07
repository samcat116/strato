import Foundation

/// Agent configuration for the local OVN chassis (this host's `ovn-controller`).
///
/// OVN networking needs three `external_ids` on the local Open vSwitch record
/// before `ovn-controller` can do anything: `ovn-remote` (where the southbound
/// database is), `ovn-encap-type`, and `ovn-encap-ip` (this host's tunnel
/// endpoint). Historically the agent assumed an operator had set them by hand;
/// on a fresh host nothing had, so ports were created but no flows were ever
/// programmed — a silent no-dataplane failure (issue #328).
public struct OVNChassisConfig: Sendable, Equatable {
    /// Tunnel endpoint IP for this host (`external_ids:ovn-encap-ip`). When
    /// nil, an existing host value is kept, else the primary route source IP
    /// is auto-detected. Must be set explicitly on multi-homed hosts where
    /// the tunnel network is not the default-route network.
    public var encapIP: String?
    /// Tunnel encapsulation (`external_ids:ovn-encap-type`); defaults to geneve.
    public var encapType: String?
    /// Southbound database location (`external_ids:ovn-remote`). Defaults to
    /// the local unix socket, which matches the agent's northbound connection
    /// (a remote ovn-central needs an explicit `tcp:host:6642` here).
    public var remote: String?
    /// When false the agent never touches the chassis `external_ids` and an
    /// operator (or config management) owns them entirely.
    public var bootstrapEnabled: Bool

    public init(
        encapIP: String? = nil,
        encapType: String? = nil,
        remote: String? = nil,
        bootstrapEnabled: Bool = true
    ) {
        self.encapIP = encapIP
        self.encapType = encapType
        self.remote = remote
        self.bootstrapEnabled = bootstrapEnabled
    }
}

/// Pure logic for bootstrapping the OVN chassis configuration: parsing the
/// current `external_ids` off `ovs-vsctl`, and deciding which keys to set.
/// The Linux network service owns actually running the commands; keeping the
/// decisions here makes them unit-testable on any platform.
public enum OVNChassisBootstrap {

    public static let defaultRemote = "unix:/var/run/ovn/ovnsb_db.sock"
    public static let defaultEncapType = "geneve"

    /// One `external_ids` assignment the bootstrap wants to apply.
    public struct Setting: Sendable, Equatable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }

        /// The `ovs-vsctl set open_vswitch .` argument for this assignment.
        public var vsctlArgument: String { "external_ids:\(key)=\(value)" }
    }

    public struct Plan: Sendable, Equatable {
        /// Assignments to apply, in a stable order. Empty when the chassis is
        /// already fully configured.
        public let settings: [Setting]
        /// True when `ovn-encap-ip` is absent, not configured, and could not
        /// be auto-detected — tunnels cannot come up until an operator sets
        /// `ovn_encap_ip` in the agent configuration.
        public let encapIPUnresolved: Bool
    }

    /// Decides which chassis `external_ids` to set. Per key: an explicit agent
    /// config value always wins (idempotent — reapplied when the host drifts);
    /// otherwise an existing host value is respected; otherwise a default is
    /// applied. `generatedSystemID` is only used when the host has no
    /// `system-id` yet (the OVS packaging normally sets one).
    public static func plan(
        config: OVNChassisConfig,
        existing: [String: String],
        detectedEncapIP: String?,
        generatedSystemID: String
    ) -> Plan {
        var settings: [Setting] = []

        if existing["system-id"] == nil || existing["system-id"]?.isEmpty == true {
            settings.append(Setting(key: "system-id", value: generatedSystemID))
        }

        appendResolved(
            key: "ovn-remote", configured: config.remote, existing: existing,
            fallback: defaultRemote, into: &settings)
        appendResolved(
            key: "ovn-encap-type", configured: config.encapType, existing: existing,
            fallback: defaultEncapType, into: &settings)

        var encapIPUnresolved = false
        let existingEncapIP = nonEmpty(existing["ovn-encap-ip"])
        if let configured = nonEmpty(config.encapIP) {
            if configured != existingEncapIP {
                settings.append(Setting(key: "ovn-encap-ip", value: configured))
            }
        } else if existingEncapIP == nil {
            if let detected = nonEmpty(detectedEncapIP) {
                settings.append(Setting(key: "ovn-encap-ip", value: detected))
            } else {
                encapIPUnresolved = true
            }
        }

        return Plan(settings: settings, encapIPUnresolved: encapIPUnresolved)
    }

    private static func appendResolved(
        key: String, configured: String?, existing: [String: String],
        fallback: String, into settings: inout [Setting]
    ) {
        let current = nonEmpty(existing[key])
        if let configured = nonEmpty(configured) {
            if configured != current {
                settings.append(Setting(key: key, value: configured))
            }
        } else if current == nil {
            settings.append(Setting(key: key, value: fallback))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - ovs-vsctl output parsing

    /// Parses `ovs-vsctl get open_vswitch . external_ids` output, e.g.
    /// `{hostname=strato-dev, ovn-remote="unix:/var/run/ovn/ovnsb_db.sock", system-id="4b0e..."}`.
    /// Keys are bare words; values may be quoted (with `\"` and `\\` escapes)
    /// when they contain characters OVSDB considers special.
    public static func parseExternalIDs(_ raw: String) -> [String: String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), text.hasSuffix("}") else { return [:] }
        text = String(text.dropFirst().dropLast())

        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var inQuotes = false
        var escaped = false

        func commit() {
            let trimmedKey = key.trimmingCharacters(in: .whitespaces)
            if !trimmedKey.isEmpty {
                result[trimmedKey] = value.trimmingCharacters(in: .whitespaces)
            }
            key = ""
            value = ""
            readingValue = false
        }

        for character in text {
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                escaped = true
            case "\"" where readingValue:
                inQuotes.toggle()
            case "=" where !readingValue:
                readingValue = true
            case "," where !inQuotes:
                commit()
            default:
                if readingValue {
                    value.append(character)
                } else {
                    key.append(character)
                }
            }
        }
        commit()
        return result
    }

    // MARK: - encap IP auto-detection parsing

    /// Extracts the preferred source IP from `ip -j route get <probe>` output,
    /// e.g. `[{"dst":"1.1.1.1","gateway":"192.168.1.1","dev":"eth0","prefsrc":"192.168.1.10",...}]`.
    /// This is the address the kernel would use to reach off-host traffic —
    /// a sensible single-NIC default for the tunnel endpoint.
    public static func parseRouteSourceIP(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
            let routes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let source = routes.first?["prefsrc"] as? String,
            !source.isEmpty
        else {
            return nil
        }
        return source
    }
}
