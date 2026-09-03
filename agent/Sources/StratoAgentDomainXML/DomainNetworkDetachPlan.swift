/// The independently mutable libvirt definitions that can contain a NIC.
public enum DomainNetworkDetachScope: Sendable, Equatable {
    case live
    case config
}

/// Plans a network hot-unplug from libvirt's current live and persistent XML.
///
/// A running domain has two definitions and libvirt does not update them
/// atomically. Treating `LIVE|CONFIG` as one operation can therefore leave one
/// side changed when the other side rejects or has not completed the detach.
/// Planning each present side independently makes every partial state directly
/// replayable. Live comes first so QEMU releases the TAP before host networking
/// teardown can begin.
public struct DomainNetworkDetachPlan: Sendable, Equatable {
    public let scopes: [DomainNetworkDetachScope]

    public init(
        macAddress: String,
        liveDomainXML: String?,
        inactiveDomainXML: String
    ) throws {
        let macAddress = macAddress.lowercased()
        var scopes: [DomainNetworkDetachScope] = []
        if let liveDomainXML,
            try DomainNetworkInventory.macAddresses(inDomainXML: liveDomainXML)
                .contains(macAddress)
        {
            scopes.append(.live)
        }
        if try DomainNetworkInventory.macAddresses(inDomainXML: inactiveDomainXML)
            .contains(macAddress)
        {
            scopes.append(.config)
        }
        self.scopes = scopes
    }
}
