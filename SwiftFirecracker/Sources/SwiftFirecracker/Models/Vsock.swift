import Foundation

/// Virtio-vsock device configuration.
/// Maps to the `PUT /vsock` API endpoint.
///
/// A single vsock device backs host↔guest control traffic: the guest reaches
/// the host over a well-known context ID, and the host reaches guest-listening
/// ports through the Unix-domain socket at `udsPath` using Firecracker's
/// `CONNECT <port>` handshake (see ``VsockConnection``).
public struct VsockConfig: Codable, Sendable {
    /// Guest context identifier (CID). Must be >= 3 — CIDs 0-2 are reserved
    /// (0 hypervisor, 1 local, 2 host) by the vsock address family.
    public let guestCid: UInt32

    /// Path to the host Unix-domain socket that multiplexes the vsock device.
    /// Firecracker creates this socket for host-initiated connections and
    /// derives `\(udsPath)_\(port)` sockets for guest-initiated ones.
    public let udsPath: String

    /// Optional device identifier. Deprecated by Firecracker (a VM has at most
    /// one vsock device) and omitted from the request when `nil`.
    public let vsockId: String?

    enum CodingKeys: String, CodingKey {
        case guestCid = "guest_cid"
        case udsPath = "uds_path"
        case vsockId = "vsock_id"
    }

    public init(guestCid: UInt32, udsPath: String, vsockId: String? = nil) {
        self.guestCid = guestCid
        self.udsPath = udsPath
        self.vsockId = vsockId
    }
}
