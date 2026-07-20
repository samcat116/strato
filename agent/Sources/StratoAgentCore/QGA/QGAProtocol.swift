import Foundation
import StratoShared

/// The QEMU guest agent (qga) JSON vocabulary (issue #563).
///
/// qga speaks the same newline-friendly JSON-RPC as QMP — `{"execute": "..."}`
/// requests, `{"return": ...}` / `{"error": {...}}` replies — but over the
/// guest's `org.qemu.guest_agent.0` virtio-serial port instead of a monitor
/// socket, and *without* QMP's greeting or `qmp_capabilities` handshake. Stream
/// resynchronization is done with `guest-sync-delimited` instead (see
/// `QGAClient`).
///
/// These types are deliberately plain `Codable` against qga's own hyphenated
/// field names — this is the guest agent's wire format, not Strato's, so it
/// does not go through `WireProtocol`'s pinned coder pair.
enum QGA {
    /// A qga request: `{"execute": "<command>", "arguments": {...}}`.
    struct Request<Arguments: Encodable>: Encodable {
        let execute: String
        let arguments: Arguments?

        init(execute: String, arguments: Arguments? = nil) {
            self.execute = execute
            self.arguments = arguments
        }
    }

    /// A qga reply carrying a typed `return` value, or an `error`.
    struct Response<Value: Decodable>: Decodable {
        let `return`: Value?
        let error: ResponseError?
    }

    /// The `error` object qga returns when a command fails (e.g. an unsupported
    /// command, or fs-freeze on a guest with no freezable filesystems).
    struct ResponseError: Decodable, Error, CustomStringConvertible {
        let `class`: String?
        let desc: String?

        var description: String {
            "qga error (\(`class` ?? "unknown")): \(desc ?? "no description")"
        }
    }

    /// `guest-sync-delimited` / `guest-sync` carry a caller-chosen numeric token
    /// echoed back in the reply so a resync can confirm it read *its own* reply
    /// rather than stale buffered data.
    struct SyncArguments: Encodable {
        let id: Int
    }

    /// Empty-arguments placeholder for commands that take none, so `Request`'s
    /// generic argument has a concrete type at the call site.
    struct NoArguments: Encodable {}

    // MARK: - Command payloads

    /// `guest-shutdown` mode: qga defaults to `powerdown`, which is what a
    /// graceful shutdown wants (an ACPI-equivalent clean poweroff from inside
    /// the guest).
    struct ShutdownArguments: Encodable {
        let mode: String
        init(mode: String = "powerdown") { self.mode = mode }
    }

    /// `guest-get-host-name` → `{"host-name": "..."}`.
    struct HostName: Decodable {
        let hostName: String
        enum CodingKeys: String, CodingKey {
            case hostName = "host-name"
        }
    }

    /// One entry of `guest-network-get-interfaces`.
    struct NetworkInterface: Decodable {
        let name: String
        let hardwareAddress: String?
        let ipAddresses: [IPAddress]?

        enum CodingKeys: String, CodingKey {
            case name
            case hardwareAddress = "hardware-address"
            case ipAddresses = "ip-addresses"
        }
    }

    /// One address of a `guest-network-get-interfaces` entry.
    struct IPAddress: Decodable {
        let ipAddressType: String
        let ipAddress: String
        let prefix: Int?

        enum CodingKeys: String, CodingKey {
            case ipAddressType = "ip-address-type"
            case ipAddress = "ip-address"
            case prefix
        }
    }
}

// MARK: - Mapping qga output to the shared GuestInfo DTO

extension GuestInfo {
    /// Builds the shared `GuestInfo` from qga's raw query results. `qgaAvailable`
    /// is passed explicitly because a positive liveness signal (the sync
    /// handshake succeeded) is worth reporting even when the detail queries came
    /// back empty or failed.
    static func from(
        qgaAvailable: Bool,
        hostName: String?,
        interfaces: [QGA.NetworkInterface]
    ) -> GuestInfo {
        GuestInfo(
            qgaAvailable: qgaAvailable,
            hostname: hostName.flatMap { $0.isEmpty ? nil : $0 },
            interfaces: interfaces.map { iface in
                GuestNetworkInterface(
                    name: iface.name,
                    hardwareAddress: GuestInfo.normalizeMAC(iface.hardwareAddress),
                    addresses: (iface.ipAddresses ?? []).compactMap { GuestIPAddress.from(qga: $0) }
                )
            }
        )
    }

    /// Lowercases a MAC so control-plane matching against a `VMNetworkInterface`
    /// MAC is case-insensitive, and drops an empty/whitespace-only value to nil
    /// (some guests report loopback with no hardware address).
    static func normalizeMAC(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

extension GuestIPAddress {
    /// Maps a qga address to the shared type, dropping entries whose
    /// `ip-address-type` is neither `ipv4` nor `ipv6` (qga only ever emits
    /// those two, but decoding tolerantly avoids crashing on a future value).
    static func from(qga address: QGA.IPAddress) -> GuestIPAddress? {
        let family: IPFamily
        switch address.ipAddressType.lowercased() {
        case "ipv4": family = .ipv4
        case "ipv6": family = .ipv6
        default: return nil
        }
        let text = address.ipAddress.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return GuestIPAddress(family: family, address: text, prefixLength: address.prefix)
    }
}
