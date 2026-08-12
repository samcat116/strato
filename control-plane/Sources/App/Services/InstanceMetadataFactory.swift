import Foundation
import StratoShared
import Vapor

extension InstanceMetadata {
    /// Assembles what one VM's link-local metadata service should tell the
    /// guest about itself (STR-51), for `DesiredVMState.metadata`.
    ///
    /// Everything here comes from rows the desired-state assembly has already
    /// loaded — the VM, its eager-loaded NICs with addresses, and the indexes
    /// the assembly builds once per sync — because this runs for every VM of
    /// every agent on every sync: a query added here is a fleet-wide load
    /// multiplier, not a per-VM cost. `region`/`availabilityZone` are passed in
    /// for the same reason; they describe the *receiving agent*, which the
    /// assembly resolves once.
    ///
    /// `resolvedInterfaces` is the VM's NICs already paired with their networks
    /// by `VMSpecBuilder.resolvedInterfaces` — taken rather than resolved here
    /// so the caller resolves once and hands the *same* list to the VM spec,
    /// which is what makes the two lists agree by construction instead of by
    /// both happening to pass the same network map. Nothing here is
    /// authorization input and nothing may expire: this is a publication
    /// boundary (any process in the guest that reaches the link-local address
    /// reads all of it) carried on a sync that must stay valid however long it
    /// takes to arrive.
    ///
    /// `vendorData` is passed explicitly at its empty value rather than
    /// defaulted because it is a decision about what the platform publishes to
    /// guests: Strato has no provisioning document of its own yet. Tags come
    /// directly from the VM row; they are ordinary mutable metadata, never an
    /// authorization input.
    ///
    /// `instanceSPIFFEID` is the VM's own instance identity (STR-55) —
    /// `spiffe://<trust-domain>/vm/<vm-id>`, the key its `workload_registrations`
    /// row is filed under. **Passed in, never looked up here**, for the reason
    /// above: the caller resolves the whole sync's worth in one query. It is a
    /// *name*, not a credential — no key, no token, nothing that expires —
    /// which is exactly what makes it publishable across this boundary at all;
    /// `docs/architecture/guest-identity.md` rejects the metadata service as a
    /// carrier of SVIDs for the same reason it endorses it as a carrier of the
    /// ID. The audience and TTL policy is copied from the control plane's
    /// issuance configuration so the agent can enforce it before any mint call.
    /// Nil means the VM has no registration —
    /// one an administrator revoked — and nothing is vended.
    static func build(
        vm: VM,
        vmId: UUID,
        resolvedInterfaces: [(interface: VMNetworkInterface, network: LogicalNetwork)],
        region: String?,
        availabilityZone: String?,
        instanceSPIFFEID: String?,
        identityAudiences: [String] = [],
        identityTTLSeconds: Int? = nil,
        siteResolverCapable: Bool? = nil
    ) -> InstanceMetadata {
        InstanceMetadata(
            instanceId: vmId,
            // Nil for VMs predating `VM.hostname` (issue #770). Deliberately
            // not derived from `name`: a slug is the lossy derivation the
            // stored column exists to avoid, and it would disagree with the
            // records the VM's DNS zone assembles from the same column.
            hostname: vm.hostname,
            projectId: vm.$project.id,
            // `VM.environment` is a non-optional column, but an empty string is
            // "unset", not an environment named "": the renderer decides what
            // an unset environment looks like and cannot if it is handed one.
            environment: vm.environment.isEmpty ? nil : vm.environment,
            region: region,
            availabilityZone: availabilityZone,
            // The very list the VM spec's NICs are built from, so the guest
            // matches an entry here to a link by MAC and an operator reading
            // both sees one list.
            nics: resolvedInterfaces.map {
                MetadataNIC.build(
                    interface: $0.interface, network: $0.network,
                    siteResolverCapable: siteResolverCapable)
            },
            // The same complete key list the spec carries. Duplicated deliberately
            // (see `InstanceMetadata.sshAuthorizedKeys`): the spec copy
            // provisions at boot, while this copy is what IMDS serves if a
            // guest re-reads metadata after an operator rotates it.
            sshAuthorizedKeys: vm.effectiveSSHAuthorizedKeys,
            userData: vm.userData,
            vendorData: nil,
            tags: vm.tags,
            identity: instanceSPIFFEID.map {
                IdentityPolicy(
                    spiffeId: $0, audiences: identityAudiences,
                    ttlSeconds: identityTTLSeconds)
            },
            // NoCloud cannot attach an IMDSv2 header while following
            // `seedfrom`, so IMDS-backed VMs receive a narrow capability that
            // authenticates only their bootstrap document paths. ISO-backed
            // VMs never publish one.
            noCloudSeedToken: vm.metadataSource == .imds ? vm.metadataSeedToken : nil,
            // The per-instance kill switch (STR-185). Sent as the column's
            // literal value rather than folded with the network's
            // `metadataEnabled`: the two are enforced at different layers — the
            // network's by whether the localport exists at all, this one by the
            // listener and the deny ACL — and folding them here would put a
            // network's setting into a per-VM field that outlives it, so
            // turning the network's switch back on would leave every VM on it
            // still refused.
            serviceEnabled: vm.metadataEnabled
        )
    }
}

extension MetadataNIC {
    /// One NIC as the guest is told about it. Addressing comes from the
    /// per-family address rows (`addresses` must be eager-loaded), carried as
    /// address + prefix length rather than the dotted netmask `NetworkSpec`
    /// still sends for old agents — that is the form both renderer targets
    /// want, and the dotted form is derivable from it.
    ///
    /// The DHCP/DNS fields come from the network row rather than the NIC
    /// because that is where they live; carrying them at all is what lets the
    /// IMDS tell a guest everything the seed ISO's static network config used
    /// to on networks where DHCP is off.
    static func build(
        interface: VMNetworkInterface, network: LogicalNetwork, siteResolverCapable: Bool? = nil
    ) -> MetadataNIC {
        let ipv4 = interface.ipv4Address
        let ipv6 = interface.ipv6Address
        return MetadataNIC(
            deviceName: interface.deviceName,
            macAddress: interface.macAddress,
            // From the NIC's foreign key, not `network.id`: the same value by
            // construction — the caller looked the row up by it — but
            // non-optional.
            networkId: interface.logicalNetworkID,
            networkName: network.name,
            ipAddress: ipv4?.address,
            prefixLength: ipv4?.prefixLength,
            // The allocation's gateway, the same source `NetworkSpec` uses, so
            // the two never disagree about a NIC's next hop.
            gateway: ipv4?.gateway,
            ipv6Address: ipv6?.address,
            ipv6PrefixLength: ipv6?.prefixLength,
            gateway6: ipv6?.gateway,
            mtu: interface.mtu,
            dnsServers: network.dnsServers,
            domainName: network.domainName,
            dhcpEnabled: network.dhcpEnabled,
            metadataEnabled: network.metadataEnabled,
            resolverAddresses: network.resolverAddressesIfEnabled(siteCapable: siteResolverCapable) ?? []
        )
    }
}
