import Fluent
import Foundation
import Metrics
import SQLKit
import StratoShared
import Vapor

/// Assembles the full, authoritative desired-state sync for one agent (issues
/// #260, #261): the level-triggered `DesiredStateMessage` carrying every VM,
/// sandbox, and logical network the agent should converge on, straight from
/// Postgres — no in-memory VM-to-agent map involved.
///
/// This is pure assembly. *When* to sync, *which* socket carries it, and how a
/// sync reaches an agent on another replica all stay with the socket owner
/// (`AgentService`); tests exercise the assembly through this interface
/// without an agent socket in sight. The one write the otherwise read-only
/// assembly performs are recording image-download grants (issue #562) and a
/// VM-local assembly failure (STR-287). Both belong here: this is the single
/// point that knows what was handed to the agent and which one entry could not
/// be projected without withholding unrelated workloads.
struct DesiredStateAssembler {
    let app: Application
    let metricsFactory: (any MetricsFactory)?

    init(app: Application, metricsFactory: (any MetricsFactory)? = nil) {
        self.app = app
        self.metricsFactory = metricsFactory
    }

    struct NetworkAssemblyScope {
        let networkIDs: Set<UUID>
        let authoritative: Bool
        let floatingIPAgentIDs: Set<String>
        /// VMs whose topology this agent authors. These are already loaded
        /// with NICs while deriving the network scope, so security-group
        /// assembly must reuse them rather than querying the same rows again.
        let coveredVMs: [VM]
        /// Sandboxes whose topology this agent authors (STR-102), on the same
        /// terms and for the same reason as `coveredVMs`: the network scope
        /// already loads them with NICs to union their logical-network
        /// references, so seeding the group closure from them costs no query.
        let coveredSandboxes: [Sandbox]
    }

    /// The full authoritative sync for an agent. Image download URLs are
    /// mTLS-authenticated relative paths (issue #493), so nothing in the
    /// assembly expires or needs re-signing. Safe to call redundantly:
    /// identical syncs diff to nothing on the agent.
    func assemble(agentId: String) async throws -> DesiredStateMessage {
        let db = app.db
        guard let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db)
        else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        let site = try await agent.$site.get(on: db)
        let vms = try await VM.query(on: db)
            .filter(\.$hypervisorId == agentId)
            .with(\.$volumes)
            .with(\.$networkInterfaces) { $0.with(\.$addresses) }
            // Artifacts are required so buildImageInfo can emit the explicit
            // typed set each hypervisor selects from.
            .with(\.$sourceImage) { image in
                image.with(\.$artifacts)
            }
            .all()

        // The agent's authoritative sandbox set (issue #413). Loaded before
        // network scope so sandbox-only network references are included.
        let sandboxes = try await Sandbox.query(on: db)
            .filter(\.$hypervisorId == agentId)
            .with(\.$networkInterfaces) { $0.with(\.$addresses) }
            .all()

        let scope = try await networkAssemblyScope(
            agentId: agentId, agent: agent, site: site, ownVMs: vms, ownSandboxes: sandboxes, on: db)

        // DHCP/DNS config lives on the logical-network row. Query exactly the
        // union used by local workload specs and authoritative topology.
        let ownVMNetworkIDs = Set(vms.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        let sandboxNetworkIDs = Set(
            sandboxes.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        let requiredNetworkIDs =
            ownVMNetworkIDs.union(sandboxNetworkIDs).union(scope.networkIDs)
        let networksByID = try await logicalNetworks(ids: requiredNetworkIDs, on: db)

        // Whether this agent can realize a sandbox NIC at all (STR-103), which
        // is what decides if `SandboxSpec.network` goes on the wire to it.
        //
        let sendSandboxNetwork = agent.sandboxNetworkingCapable

        // The per-network resolver (STR-40). Nil when the agent row is missing;
        // otherwise, whether this agent's *site* can answer on the resolver
        // address at all.
        //
        // The site, not the agent, because the two halves of this feature have
        // different reach: the DHCP option pointing guests at the resolver is
        // one row per network, authored by the site's topology authority, while
        // the process answering on the address runs on each chassis. Enabling
        // it while one host in the site lacks CoreDNS would give that network
        // DNS that works until a VM lands on the wrong hypervisor — a failure
        // that looks like a flaky network rather than a missing dependency. So
        // the whole site converges or none of it does.
        let siteResolverCapable = try await resolverCapableSiteWide(site: site, on: db)
        let securityGroupsByInterface: [UUID: [UUID]]
        let sandboxSecurityGroupsByInterface: [UUID: [UUID]]
        securityGroupsByInterface = try await nicSecurityGroupMemberships(
            interfaceIDs: vms.flatMap { $0.networkInterfaces.compactMap(\.id) }, on: db)
        sandboxSecurityGroupsByInterface = try await sandboxNICSecurityGroupMemberships(
            interfaceIDs: sandboxes.flatMap { $0.networkInterfaces.compactMap(\.id) }, on: db)

        // Placement describes the receiving agent, not the VM, so it is
        // resolved once for the whole sync. The site's *name* names the coarse
        // half, not its advisory `regionCode`: that slug is operator-optional,
        // so falling back to the name would make the field's namespace depend
        // on whether someone filled it in. Whether a guest is *told* either
        // half is the renderer's call, not this one.
        let region = site.name
        let availabilityZone = agent.name

        // The VMs' instance identities (STR-55), resolved in one query for the
        // whole sync — mirroring `securityGroupsByInterface` above, and for the
        // same reason: this runs for every agent on every sync, so a per-VM
        // lookup would be a fleet-wide load multiplier.
        let spiffeIDsByVM = try await GuestIdentity.spiffeIDs(forVMs: vms.compactMap(\.id), on: db)
        let identityIssuance = app.guestIdentityIssuanceConfig
        let identityAudiences = identityIssuance.allowedAudiences.sorted()
        // STR-57 may permit longer lifetimes for other trusted agent callers;
        // the guest-facing IMDS surface has the tighter 15-minute ceiling.
        let identityTTLSeconds =
            identityAudiences.isEmpty
            ? nil : min(900, max(1, identityIssuance.maximumTTLSeconds))
        let volumeDiskAttachments = try await VolumeService.diskAttachments(
            for: vms.flatMap(\.volumes), accessibleFrom: agentId, on: db)

        var entries: [DesiredVMState] = []
        for vm in vms {
            guard let vmId = vm.id else { continue }
            let image = vm.sourceImage
            // Resolved once and handed to both consumers: the spec's NIC list
            // and the metadata the guest reads are then the same list, and an
            // under-fetched NIC is logged once for this VM rather than once per
            // consumer — which would read as two NICs having gone missing.
            let resolvedInterfaces = VMSpecBuilder.resolvedInterfaces(
                from: vm.networkInterfaces, networks: networksByID, logger: app.logger)
            let spec: VMSpec
            do {
                spec = try VMSpecBuilder.buildVMSpec(
                    from: vm,
                    image: image,
                    volumes: vm.volumes,
                    diskAttachmentsByVolumeID: volumeDiskAttachments,
                    resolvedInterfaces: resolvedInterfaces,
                    securityGroupsByInterface: securityGroupsByInterface,
                    siteResolverCapable: siteResolverCapable
                )
            } catch {
                await recordVMAssemblyFailure(vm: vm, vmId: vmId, error: error, on: db)
                continue
            }
            // A repair is visible as soon as this VM can be projected again;
            // it does not have to wait for the agent's next observed-state
            // heartbeat to clear a control-plane-owned condition.
            if vm.desiredStateAssemblyError != nil {
                await clearVMAssemblyFailure(vm: vm, vmId: vmId, on: db)
            }

            // Image download info lets the agent materialize a VM it doesn't
            // have yet. Best effort: a VM whose image is missing/not-ready can
            // still be synced for status changes on its existing disks — but
            // loudly, because for a not-yet-created VM a nil imageInfo means
            // the agent will refuse the diskless create and fail the pending
            // operation with that reason.
            var imageInfo: ImageInfo?
            if let image, image.status == .ready {
                do {
                    imageInfo = try VMSpecBuilder.buildImageInfo(from: image)
                    // Emitting the URLs is what authorizes the fetch: the
                    // download route serves an agent only the images it has a
                    // grant for (issue #562).
                    if let imageId = image.id {
                        await app.coordination.grantImageDownload(agentId: agentId, imageId: imageId)
                    }
                } catch {
                    app.logger.warning(
                        "Failed to build image info for desired-state sync",
                        metadata: [
                            "strato.vm.id": .string(vmId.uuidString),
                            "imageId": .string(image.id?.uuidString ?? ""),
                            "error": .string(error.localizedDescription),
                        ])
                }
            } else if vm.$sourceImage.id != nil {
                app.logger.warning(
                    "VM references an image that is missing or not ready; syncing without image info",
                    metadata: ["strato.vm.id": .string(vmId.uuidString)])
            }

            let metadata = InstanceMetadata.build(
                vm: vm, vmId: vmId, resolvedInterfaces: resolvedInterfaces,
                region: region, availabilityZone: availabilityZone,
                instanceSPIFFEID: spiffeIDsByVM[vmId],
                identityAudiences: identityAudiences,
                identityTTLSeconds: identityTTLSeconds,
                siteResolverCapable: siteResolverCapable)

            // A zero nonce is "never asked for", and sending it would be a
            // slightly different claim than sending nothing — so both are
            // omitted until the first request, which also keeps them out of the
            // sync's digest for every VM that has never been restarted or
            // restored (STR-151).
            let rebootGeneration = vm.rebootGeneration > 0 ? vm.rebootGeneration : nil
            var restore: DesiredRestore?
            if vm.restoreGeneration > 0, let snapshotID = vm.restoreSnapshotID {
                // A VM checkpoint lives inside the VM's own disks, so it never
                // moves between hosts and there is nothing to stage: no
                // artifacts, ever.
                restore = DesiredRestore(generation: vm.restoreGeneration, snapshotId: snapshotID)
            }

            entries.append(
                DesiredVMState(
                    vmId: vmId,
                    hypervisorType: vm.hypervisorType,
                    spec: spec,
                    desiredStatus: vm.desiredStatus,
                    generation: vm.generation,
                    imageInfo: imageInfo,
                    metadata: metadata,
                    rebootGeneration: rebootGeneration,
                    restore: restore
                ))
        }

        // First-class network desired state (issue #342): the logical networks
        // the agent should realize as level-triggered desired state (switches,
        // per-project routers, SNAT uplinks). Which networks — and whether this
        // agent may write topology at all — depends on its site membership
        // (issue #343); see `networkAssemblyScope`.
        // Floating IPs attached to NICs of VMs the receiving agent's topology
        // writes cover (issue #344): every site VM for the site's controller.
        // Keyed by network id, matching how the NAT rule lands on that
        // network's router.
        let floatingIPsByNetwork = try await desiredFloatingIPs(
            forAgentIDs: scope.floatingIPAgentIDs,
            networkIDs: scope.networkIDs,
            on: db)
        let loadBalancersByNetwork = try await desiredLoadBalancers(
            networkIDs: scope.networkIDs, on: db)
        let networkACLsByNetwork = try await desiredNetworkACLs(
            networkIDs: scope.networkIDs, on: db)
        // Sorted by id: names are no longer unique, so only the id gives the
        // topology list a stable, total order.
        let networkStates =
            scope.networkIDs
            .sorted { $0.uuidString < $1.uuidString }
            .compactMap { networkId -> DesiredNetworkState? in
                guard let network = networksByID[networkId] else { return nil }
                return DesiredNetworkState(
                    networkId: networkId,
                    name: network.name,
                    subnet: network.subnet,
                    gateway: network.gateway,
                    subnet6: network.subnet6,
                    gateway6: network.gateway6,
                    routerKey: network.routerKey,
                    externalAccess: network.externalAccess,
                    dhcpEnabled: network.dhcpEnabled,
                    dnsServers: network.dnsServers,
                    domainName: network.domainName,
                    leaseTime: network.leaseTime,
                    metadataEnabled: network.metadataEnabled,
                    resolverEnabled: siteResolverCapable && network.resolverEnabled,
                    resolverAddresses: network.resolverAddressesIfEnabled(
                        siteCapable: siteResolverCapable),
                    generation: Int64(network.generation),
                    floatingIPs: floatingIPsByNetwork[networkId] ?? [],
                    loadBalancers: loadBalancersByNetwork[networkId] ?? [],
                    // The current lockstep wire always carries an
                    // authoritative opinion: [] tears down managed switch
                    // ACLs, while the schema limits this list to one entry.
                    networkACLs: networkACLsByNetwork[networkId].map { [$0] } ?? []
                )
            }

        // Registry material is refreshed here (issue #414), mirroring signed
        // image URLs: unpinned tags resolve to digests exactly once, and a
        // short-lived pull credential is minted for private images.
        //
        // One credential fetch for all the sandboxes' projects; matched per
        // sandbox by the image's registry host.
        let sandboxProjectIDs = Set(sandboxes.map { $0.$project.id })
        let pullSecretsByProject: [UUID: [RegistryPullSecret]]
        if sandboxProjectIDs.isEmpty {
            pullSecretsByProject = [:]
        } else {
            let rows = try await RegistryPullSecret.query(on: db)
                .filter(\.$project.$id ~~ sandboxProjectIDs)
                .all()
            pullSecretsByProject = Dictionary(grouping: rows) { $0.$project.id }
        }

        var sandboxEntries: [DesiredSandboxState] = []
        // Both snapshot references a sandbox entry can carry, fetched together:
        // the create-strategy `restoredFromSnapshotId` (a fork's lineage) and the
        // edge-nonce `restoreSnapshotID` (a rewind of a sandbox that already
        // exists, STR-151). Different fields with different meanings, but the
        // same row and the same reason to read it — the exported artifacts'
        // descriptors, resolved fresh here so nothing in the sync can go stale.
        let restoreSnapshotIDs = Set(
            sandboxes.compactMap(\.restoredFromSnapshotId) + sandboxes.compactMap(\.restoreSnapshotID))
        let restoreSnapshots: [UUID: SandboxSnapshot]
        if restoreSnapshotIDs.isEmpty {
            restoreSnapshots = [:]
        } else {
            let rows = try await SandboxSnapshot.query(on: db)
                .filter(\.$id ~~ restoreSnapshotIDs)
                .all()
            restoreSnapshots = Dictionary(
                uniqueKeysWithValues: rows.compactMap { snapshot in
                    snapshot.id.map { ($0, snapshot) }
                })
        }
        for sandbox in sandboxes {
            guard let sandboxId = sandbox.id else { continue }
            let restoreFrom = sandbox.restoredFromSnapshotId.flatMap { snapshotID -> SandboxSnapshotRef? in
                guard let snapshot = restoreSnapshots[snapshotID] else { return nil }
                // A fork placed off the snapshot's agent restores from the
                // exported copy: relative download paths + the recorded
                // integrity material, fetched by the agent over SVID mTLS
                // (issue #428). Placement guaranteed the export exists; if it
                // has since been invalidated (re-export in flight), the
                // descriptors are nil and the agent reports the miss instead
                // of mis-converging.
                var artifacts: [SandboxSnapshotArtifactDescriptor]?
                if snapshot.agentId != agentId {
                    artifacts = try? snapshot.exportedArtifactDescriptors()
                    if artifacts == nil {
                        app.logger.warning(
                            "Fork is placed off its snapshot's agent but the exported copy is unavailable",
                            metadata: [
                                "strato.sandbox.id": .string(sandboxId.uuidString),
                                "snapshotId": .string(snapshotID.uuidString),
                            ])
                    }
                }
                return SandboxSnapshotRef(
                    snapshotId: snapshotID, sourceSandboxId: snapshot.$sandbox.id, artifacts: artifacts)
            }
            // Registry material first: digest pinning mutates the in-memory
            // model that buildSpec() reads. A fork already has its rootfs in
            // the checkpoint archive and must not depend on registry access.
            let registryCredential: RegistryCredential?
            if restoreFrom == nil {
                registryCredential = await sandboxRegistryMaterial(
                    sandbox,
                    secrets: pullSecretsByProject[sandbox.$project.id] ?? [],
                    on: db)
            } else {
                registryCredential = nil
            }
            // The sandbox's single NIC spec (issue #416), built from its
            // eager-loaded interface + the interface's logical network (for
            // DHCP/DNS config), reusing the networks index gathered above, and
            // gated on this agent's advertised sandbox-networking capability
            // (STR-103) rather than on a wire version — the guest image that
            // has to configure the interface ships separately from the agent.
            //
            // Placement already refuses to put a networked sandbox on a host
            // without the capability, so a `nil` here means one of two things:
            // a network-free sandbox, or a host that lost the capability under
            // a sandbox already placed on it (a guest-image rollback, OVN down,
            // the jailer deconfigured). The second is reported: the sandbox's
            // `securityGroupsEnforced` reads false for exactly this reason,
            // since a NIC that never reaches the wire has no port to filter.
            let interface = sandbox.networkInterfaces.first
            let networkSpec = SandboxSpecBuilder.networkSpec(
                from: interface,
                network: interface.flatMap { networksByID[$0.logicalNetworkID] },
                securityGroupIds: interface?.id.flatMap { sandboxSecurityGroupsByInterface[$0] },
                siteResolverCapable: siteResolverCapable,
                agentRealizesSandboxNICs: sendSandboxNetwork)
            // Debug, not warning, despite being worth knowing: assembly runs on
            // every sync for every agent, so during a fleet upgrade this is one
            // line per networked sandbox per poll — thousands of them, all
            // saying the same thing. The operator-facing signals are the ones
            // that fire once: the agent's own warning at registration naming
            // the specific blocker, and `securityGroupsEnforced` reading false
            // on the sandbox itself.
            if interface != nil && !sendSandboxNetwork {
                app.logger.debug(
                    "Withholding a sandbox's NIC: its host does not advertise sandbox networking",
                    metadata: [
                        "strato.sandbox.id": .string(sandboxId.uuidString),
                        "strato.agent.id": .string(agentId),
                    ])
            }
            // The restore *edge* (STR-151), as distinct from the fork create
            // strategy above. Its artifacts follow the same rule for the same
            // reason: a sandbox that has moved off the agent that captured the
            // snapshot restores from the exported copy, and the descriptors are
            // minted here rather than stored, so a nonce that sits in the
            // desired state for a week still carries usable locators.
            var restore: DesiredRestore?
            if sandbox.restoreGeneration > 0, let snapshotID = sandbox.restoreSnapshotID {
                var artifacts: [SandboxSnapshotArtifactDescriptor]?
                if let snapshot = restoreSnapshots[snapshotID], snapshot.agentId != agentId {
                    artifacts = try? snapshot.exportedArtifactDescriptors()
                    if artifacts == nil {
                        app.logger.warning(
                            "Sandbox restore targets a snapshot on another agent whose exported copy is unavailable",
                            metadata: [
                                "strato.sandbox.id": .string(sandboxId.uuidString),
                                "snapshotId": .string(snapshotID.uuidString),
                            ])
                    }
                }
                restore = DesiredRestore(
                    generation: sandbox.restoreGeneration, snapshotId: snapshotID, artifacts: artifacts)
            }

            sandboxEntries.append(
                DesiredSandboxState(
                    sandboxId: sandboxId,
                    spec: sandbox.buildSpec(network: networkSpec, restoreFrom: restoreFrom),
                    desiredStatus: sandbox.desiredStatus,
                    generation: sandbox.generation,
                    registryCredential: registryCredential,
                    restore: restore
                ))
        }

        // The security groups the topology authority realizes as port groups
        // + ACLs: groups attached to NICs of VMs and sandboxes on the hosts
        // whose topology the receiving agent authors, plus the transitive
        // closure of groups their rules reference (so `$pg_…` address-set
        // references always resolve). Nil for non-authoritative agents; they
        // only consume the per-NIC membership above.
        let securityGroups: [DesiredSecurityGroup]?
        if scope.authoritative {
            securityGroups = try await desiredSecurityGroups(
                forVMs: scope.coveredVMs, sandboxes: scope.coveredSandboxes,
                siteID: try site.requireID(), on: db)
        } else {
            securityGroups = nil
        }

        // The agent's authoritative volume set (STR-148) and snapshot-artifact
        // set (STR-150).
        let volumes = try await desiredVolumes(agentId: agentId, on: db)
        let snapshots = try await desiredSnapshots(agentId: agentId, on: db)
        // Credential revocations are scoped to the site's lifetime, not its
        // current cluster registration. Replay every row forever so an agent
        // that was offline, re-enrolled, or newly added still removes stale
        // Ceph keyrings, configs, and libvirt secrets.
        let siteID = try site.requireID()
        let cephCredentialRevocations = try await CephCredentialRevocation.query(on: db)
            .filter(\.$site.$id == siteID)
            .sort(\.$createdAt)
            .sort(\.$id)
            .all()
            .map {
                DesiredCephCredentialRevocation(
                    clusterId: $0.clusterID, credentialId: $0.credentialID)
            }

        // The DNS zones this agent realizes. Two backends read one list:
        //
        //  - the OVN `DNS` table (STR-39), written only by the topology
        //    authority because those rows are switch-scoped, and
        //  - the per-network resolver (STR-40), run by every agent with a local
        //    NIC on the network, because CoreDNS answers where the guests are.
        //
        // So the zone selection is the union of "networks I author" and
        // "networks I run something on". A non-authority agent with no local
        // NIC on an attached network is still sent nil, which keeps
        // `[]`-as-teardown from ever reaching a peer of the controller. An
        // agent that *is* sent zones without authority realizes only the
        // resolver half — it already knows which half it may write from
        // `networksAuthoritative`.
        //
        // Local NICs only count toward zone selection once the agent can
        // actually run a resolver for them; without that this would widen
        // the fan-out of a query that reads every VM in a zone, for nothing.
        let resolverNetworkIDs = siteResolverCapable ? ownVMNetworkIDs.union(sandboxNetworkIDs) : []
        let zoneNetworkIDs =
            (scope.authoritative ? scope.networkIDs : []).union(resolverNetworkIDs)
        let dnsZones: [DesiredDNSZone]? =
            zoneNetworkIDs.isEmpty && !scope.authoritative
            ? nil
            : try await desiredDNSZones(networkIDs: zoneNetworkIDs, on: db)

        return DesiredStateMessage(
            vms: entries, sandboxes: sandboxEntries, networks: networkStates,
            networksAuthoritative: scope.authoritative,
            desiredAgentUpdate: await desiredAgentUpdateForSync(agent: agent),
            securityGroups: securityGroups,
            tombstones: try await tombstones(agentId: agentId, on: db),
            volumes: volumes,
            snapshots: snapshots,
            cephCredentialRevocations: cephCredentialRevocations,
            dnsZones: dnsZones)
    }

    /// Omit one bad VM while making the omission visible on that VM. The
    /// condition write is deliberately fail-open: an unavailable telemetry
    /// write must not recreate the host-wide assembly failure this path exists
    /// to prevent. The generation guard keeps an assembly of stale rows from
    /// attaching its failure to newer desired state.
    func recordVMAssemblyFailure(
        vm: VM, vmId: UUID, error: any Error, on db: any Database
    ) async {
        let assemblyError = error as? VMSpecBuilder.AssemblyError
        let reasonCode = assemblyError?.code ?? "unexpected"
        let detail = error.localizedDescription
        let conditionReason = "VM desired state cannot be assembled: \(detail)"

        app.logger.error(
            "Omitting an unassemblable VM from desired state",
            metadata: [
                "strato.vm.id": .string(vmId.uuidString),
                "reason": .string(reasonCode),
                "error": .string(detail),
            ])
        Telemetry.desiredStateAssemblyFailed(
            kind: "vm", reason: reasonCode, factory: metricsFactory)

        // The counter records every failed projection, but an unchanged poison
        // row must not also generate an UPDATE on every long poll.
        guard
            vm.desiredStateAssemblyError != conditionReason
                || vm.desiredStateAssemblyErrorGeneration != vm.generation
                || vm.desiredStateAssemblyErrorAt == nil
        else { return }

        guard let sql = db as? any SQLDatabase else {
            app.logger.error(
                "Could not record the VM desired-state assembly failure: SQL database required",
                metadata: ["strato.vm.id": .string(vmId.uuidString)])
            return
        }
        do {
            let now = Date()
            try await sql.raw(
                """
                UPDATE vms
                SET desired_state_assembly_error = \(bind: conditionReason),
                    desired_state_assembly_error_generation = \(bind: vm.generation),
                    desired_state_assembly_error_at = CASE
                        WHEN desired_state_assembly_error IS DISTINCT FROM \(bind: conditionReason)
                          OR desired_state_assembly_error_generation IS DISTINCT FROM \(bind: vm.generation)
                          OR desired_state_assembly_error_at IS NULL
                        THEN \(bind: now)
                        ELSE desired_state_assembly_error_at
                    END
                WHERE id = \(bind: vmId)
                  AND generation = \(bind: vm.generation)
                  AND (
                    desired_state_assembly_error IS DISTINCT FROM \(bind: conditionReason)
                    OR desired_state_assembly_error_generation IS DISTINCT FROM \(bind: vm.generation)
                    OR desired_state_assembly_error_at IS NULL
                  )
                """
            ).run()
        } catch {
            app.logger.error(
                "Could not record the VM desired-state assembly failure",
                metadata: [
                    "strato.vm.id": .string(vmId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    func clearVMAssemblyFailure(vm: VM, vmId: UUID, on db: any Database) async {
        guard let sql = db as? any SQLDatabase else { return }
        do {
            try await sql.raw(
                """
                UPDATE vms
                SET desired_state_assembly_error = NULL,
                    desired_state_assembly_error_generation = NULL,
                    desired_state_assembly_error_at = NULL
                WHERE id = \(bind: vmId)
                  AND generation = \(bind: vm.generation)
                  AND desired_state_assembly_error IS NOT NULL
                """
            ).run()
        } catch {
            // The VM is safe to send; retaining a stale diagnostic is less
            // severe than withholding the whole host's desired state.
            app.logger.error(
                "Could not clear a repaired VM desired-state assembly failure",
                metadata: [
                    "strato.vm.id": .string(vmId.uuidString),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

}

extension Application {
    private struct RegistryCredentialCacheKey: StorageKey, LockKey {
        typealias Value = RegistryCredentialCache
    }

    /// The desired-state sync assembler. Stateless and cheap to construct (it
    /// holds a reference), so it is materialized per access rather than
    /// stored — the same idiom as `resourceOperationCoordinator`.
    var desiredStateAssembler: DesiredStateAssembler {
        DesiredStateAssembler(app: self)
    }

    /// Bearer material is shared across all assemblies on this replica and
    /// retained only until shortly before the registry's own expiry.
    var registryCredentialCache: RegistryCredentialCache {
        lazyService(RegistryCredentialCacheKey.self) { RegistryCredentialCache() }
    }

    private struct RegistryOperationBackoffKey: StorageKey, LockKey {
        typealias Value = RegistryOperationBackoff
    }

    /// Cooldowns for outbound registry calls that failed, shared across all
    /// assemblies on this replica.
    var registryOperationBackoff: RegistryOperationBackoff {
        lazyService(RegistryOperationBackoffKey.self) { RegistryOperationBackoff() }
    }
}

/// Cooldown for outbound registry calls that sync assembly retries on failure.
///
/// Both registry calls in assembly are naturally self-limiting on success — a
/// resolved digest is persisted on the sandbox row, a minted token is cached —
/// but neither is on *failure*, so a failing call is retried by every assembly.
/// That was tolerable when a converged agent assembled once per forced sync
/// pass (10 minutes). Since desired state moved to a long-poll (STR-146) every
/// poll assembles, so an unreachable registry would be re-dialed once per hold
/// window per sandbox — the control plane retrying hardest against the registry
/// that is already failing.
///
/// Keyed by operation and repository rather than by sandbox: two sandboxes on
/// the same image share one failure, and it is the *registry* being spared.
/// Replica-local and lossy by design — a restart simply retries sooner.
actor RegistryOperationBackoff {
    enum Operation: String, Hashable, Sendable {
        case resolveDigest
        case mintPullToken
    }

    struct Key: Hashable, Sendable {
        let operation: Operation
        let registry: String
        let repository: String
    }

    /// Long enough to be slower than the poll hold window (so a failing call
    /// costs at most one attempt per poll cycle), short enough that a registry
    /// coming back is picked up well inside a sandbox create's patience. Also
    /// the cadence the pre-STR-146 dirty-agent sync pass produced, so this is
    /// no more registry load than before the transport changed.
    static let cooldown: Duration = .seconds(60)

    private var retryAfter: [Key: ContinuousClock.Instant] = [:]

    /// Whether the call should be attempted now, or is still cooling down.
    func shouldAttempt(_ key: Key) -> Bool {
        guard let after = retryAfter[key] else { return true }
        guard ContinuousClock.now >= after else { return false }
        retryAfter[key] = nil
        return true
    }

    func recordFailure(_ key: Key) {
        retryAfter[key] = ContinuousClock.now + Self.cooldown
    }

    func recordSuccess(_ key: Key) {
        retryAfter[key] = nil
    }
}

/// Sync-level bearer cache. The distribution client also caches its raw
/// tokens, but keeping the wire credential here means an assembly can avoid
/// calling the registry client at all while the credential remains valid,
/// including for test doubles and alternate registry clients.
actor RegistryCredentialCache {
    struct Key: Hashable, Sendable {
        let secretID: UUID?
        let registry: String
        let repository: String
        let username: String
        /// The stored secret representation (ciphertext when encryption is
        /// configured). Including it invalidates the key immediately when a
        /// pull secret rotates.
        let encryptedSecret: String
    }

    private static let expiryMargin: TimeInterval = 30
    private var credentials: [Key: RegistryCredential] = [:]

    func credential(for key: Key) -> RegistryCredential? {
        guard let credential = credentials[key] else { return nil }
        guard
            let expiresAt = credential.expiresAt,
            expiresAt.timeIntervalSinceNow > Self.expiryMargin
        else {
            credentials[key] = nil
            return nil
        }
        return credential
    }

    func store(_ credential: RegistryCredential, for key: Key) {
        credentials[key] = credential
    }
}
