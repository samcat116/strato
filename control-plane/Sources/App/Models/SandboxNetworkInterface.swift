import Fluent
import Vapor

/// A NIC attached to a sandbox, the sandbox analogue of `VMNetworkInterface`
/// (issue #416). Deliberately its own slim table rather than a generalization
/// of the VM NIC — sandboxes are a parallel resource with their own lifecycle —
/// but the shape mirrors the VM path so `IPAMService`, MAC generation, and
/// stable device naming are reused. v1 gives each sandbox exactly one NIC.
final class SandboxNetworkInterface: Model, @unchecked Sendable {
    static let schema = "sandbox_network_interfaces"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "sandbox_id")
    var sandbox: Sandbox

    /// Logical network reference; agents use this to find or create the network.
    @Field(key: "network")
    var network: String

    @Field(key: "mac_address")
    var macAddress: String

    /// The addresses allocated to this NIC, one row per family (requires
    /// eager loading with `.with(\.$addresses)`).
    @Children(for: \.$interface)
    var addresses: [SandboxInterfaceAddress]

    @OptionalField(key: "mtu")
    var mtu: Int?

    /// Stable device identifier within the sandbox (e.g. "net0"). Single-NIC in
    /// v1, so always "net0", but kept for parity with the VM path.
    @Field(key: "device_name")
    var deviceName: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        sandboxID: UUID,
        network: String = "default",
        macAddress: String,
        mtu: Int? = nil,
        deviceName: String = "net0"
    ) {
        self.id = id
        self.$sandbox.id = sandboxID
        self.network = network
        self.macAddress = macAddress
        self.mtu = mtu
        self.deviceName = deviceName
    }
}

extension SandboxNetworkInterface: Content {}
