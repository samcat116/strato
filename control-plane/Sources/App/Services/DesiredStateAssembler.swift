import Fluent
import Foundation
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
/// assembly performs is recording image-download grants (issue #562) — done
/// here, at the single point where a sync's download URLs are produced, so
/// the grant can never be tighter or later than what the agent is handed.
struct DesiredStateAssembler {
    let app: Application

    private struct NetworkAssemblyScope {
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
        // Capability, site, and rollout decisions all read the same agent
        // row. Load it once instead of issuing four point queries during one
        // assembly. Unknown ids retain the legacy permissive behavior used by
        // empty/backstop syncs.
        let agent: Agent?
        if let agentUUID = UUID(uuidString: agentId) {
            agent = try await Agent.find(agentUUID, on: db)
        } else {
            agent = nil
        }
        // The agent's site, loaded here rather than inside
        // `networkAssemblyScope` because two things need it now: topology
        // authority, and the `region` every VM's instance metadata carries. One
        // row read either way — `find` of a nil id queries nothing, so a
        // site-less agent still reads none.
        let site = try await Site.find(agent?.$site.id, on: db)
        let vms = try await VM.query(on: db)
            .filter(\.$hypervisorId == agentId)
            .with(\.$volumes)
            .with(\.$networkInterfaces) { $0.with(\.$addresses) }
            // Artifacts loaded too so buildImageInfo emits the typed artifact
            // set (kernel/rootfs distribution, issue #214) rather than the
            // legacy single-file fallback.
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

        // NIC → security-group membership for the specs (and, below, the
        // group definitions the topology authority realizes). Omitted
        // entirely for pre-v20 agents: they would decode and silently ignore
        // the fields, so sending them only misstates what the sync achieved;
        // the attach API refuses new attachments against such agents.
        let sendSecurityGroups =
            agent.map { WireProtocol.supportsSecurityGroups($0.wireProtocolVersion ?? 0) } ?? true
        // Whether this agent understands the metadata port (STR-49). Omitted
        // for older agents rather than sent-and-ignored, so a nil on the wire
        // means exactly one thing on the receiving side: "the sender has no
        // opinion", which is what keeps a rollback from sweeping live ports.
        let sendMetadataPort =
            agent.map { WireProtocol.supportsMetadataPort($0.wireProtocolVersion ?? 0) } ?? true
        let securityGroupsByInterface: [UUID: [UUID]]
        let sandboxSecurityGroupsByInterface: [UUID: [UUID]]
        if sendSecurityGroups {
            securityGroupsByInterface = try await nicSecurityGroupMemberships(
                interfaceIDs: vms.flatMap { $0.networkInterfaces.compactMap(\.id) }, on: db)
            sandboxSecurityGroupsByInterface = try await sandboxNICSecurityGroupMemberships(
                interfaceIDs: sandboxes.flatMap { $0.networkInterfaces.compactMap(\.id) }, on: db)
        } else {
            securityGroupsByInterface = [:]
            sandboxSecurityGroupsByInterface = [:]
        }

        // Instance metadata (STR-51): what each VM's link-local metadata
        // service *serves*, as distinct from `sendMetadataPort` above, which is
        // whether the agent can realize the port it is served *on* (STR-49).
        // Two protocol versions because they shipped separately, and an agent
        // can speak either without the other. Omitted entirely for pre-v26
        // agents — they decode and discard it — following the v20
        // `securityGroups` pattern, and unlike v18/v23 this gates only the
        // field, never placement: an old agent still provisions its guests from
        // the seed ISO, so a VM there loses mutable metadata, not its ability
        // to boot.
        let sendInstanceMetadata =
            agent.map { WireProtocol.supportsInstanceMetadata($0.wireProtocolVersion ?? 0) } ?? true
        // Placement describes the receiving agent, not the VM, so it is
        // resolved once for the whole sync. The site's *name* names the coarse
        // half, not its advisory `regionCode`: that slug is operator-optional,
        // so falling back to the name would make the field's namespace depend
        // on whether someone filled it in. A site-less agent (the legacy
        // single-node model) simply has no region to report; whether a guest is
        // *told* either half is the renderer's call, not this one.
        let region = site?.name
        let availabilityZone = agent?.name

        // The VMs' instance identities (STR-55), resolved in one query for the
        // whole sync — mirroring `securityGroupsByInterface` above, and for the
        // same reason: this runs for every agent on every sync, so a per-VM
        // lookup would be a fleet-wide load multiplier. Skipped entirely for an
        // agent that will not be sent metadata at all.
        let spiffeIDsByVM =
            sendInstanceMetadata
            ? try await GuestIdentity.spiffeIDs(forVMs: vms.compactMap(\.id), on: db)
            : [:]

        // Edge nonces (ADR 0001 stage 9, STR-151). Omitted for pre-v34 agents
        // following the v20 `securityGroups` pattern — they decode and discard
        // them — which costs nothing here, because the admission gate has
        // already refused the mutation that would set one.
        let sendEdgeNonces =
            agent.map { WireProtocol.supportsEdgeNonces($0.wireProtocolVersion ?? 0) } ?? true

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
            let spec = VMSpecBuilder.buildVMSpecWithVolumes(
                from: vm,
                image: image,
                volumes: vm.volumes,
                resolvedInterfaces: resolvedInterfaces,
                securityGroupsByInterface: securityGroupsByInterface,
                sendsMetadataPort: sendMetadataPort
            )

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
                            "vmId": .string(vmId.uuidString),
                            "imageId": .string(image.id?.uuidString ?? ""),
                            "error": .string(error.localizedDescription),
                        ])
                }
            } else if vm.$sourceImage.id != nil {
                app.logger.warning(
                    "VM references an image that is missing or not ready; syncing without image info",
                    metadata: ["vmId": .string(vmId.uuidString)])
            }

            let metadata =
                sendInstanceMetadata
                ? InstanceMetadata.build(
                    vm: vm, vmId: vmId, resolvedInterfaces: resolvedInterfaces,
                    region: region, availabilityZone: availabilityZone,
                    instanceSPIFFEID: spiffeIDsByVM[vmId])
                : nil

            // A zero nonce is "never asked for", and sending it would be a
            // slightly different claim than sending nothing — so both are
            // omitted until the first request, which also keeps them out of the
            // sync's digest for every VM that has never been restarted or
            // restored (STR-151).
            let rebootGeneration = sendEdgeNonces && vm.rebootGeneration > 0 ? vm.rebootGeneration : nil
            var restore: DesiredRestore?
            if sendEdgeNonces, vm.restoreGeneration > 0, let snapshotID = vm.restoreSnapshotID {
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
        // writes cover (issue #344): its own VMs for a site-less agent, every
        // site VM for the site's controller. Keyed by network id, matching
        // how the NAT rule lands on that network's router. Omitted entirely
        // for pre-v12 agents — they would decode and silently ignore the
        // field, so sending it only misstates what the sync achieved; the
        // attach API refuses new attachments against such agents.
        let floatingIPsByNetwork: [UUID: [DesiredFloatingIP]]
        if agent.map({ WireProtocol.supportsFloatingIPs($0.wireProtocolVersion ?? 0) }) ?? true {
            floatingIPsByNetwork = try await desiredFloatingIPs(
                forAgentIDs: scope.floatingIPAgentIDs, on: db)
        } else {
            floatingIPsByNetwork = [:]
        }
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
                    metadataEnabled: sendMetadataPort ? network.metadataEnabled : nil,
                    generation: Int64(network.generation),
                    floatingIPs: floatingIPsByNetwork[networkId]
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
                                "sandboxId": .string(sandboxId.uuidString),
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
            // DHCP/DNS config), reusing the networks index gathered above.
            //
            // Still nil in every deployment: agents can realize a sandbox NIC
            // end to end since STR-100/101, but
            // `SandboxSpecBuilder.guestNetworkingSupported` is fleet-wide while
            // the capability is per-agent, and STR-103 is what replaces it. The
            // security-group ids are resolved and passed anyway (STR-102), so
            // that flip is a one-line change rather than a new code path — and
            // so a reader can see that a sandbox NIC, when it does reach the
            // wire, arrives filtered rather than unmanaged.
            let interface = sandbox.networkInterfaces.first
            let networkSpec = SandboxSpecBuilder.networkSpec(
                from: interface,
                network: interface.flatMap { networksByID[$0.logicalNetworkID] },
                securityGroupIds: interface?.id.flatMap { sandboxSecurityGroupsByInterface[$0] },
                sendsMetadataPort: sendMetadataPort)
            // The restore *edge* (STR-151), as distinct from the fork create
            // strategy above. Its artifacts follow the same rule for the same
            // reason: a sandbox that has moved off the agent that captured the
            // snapshot restores from the exported copy, and the descriptors are
            // minted here rather than stored, so a nonce that sits in the
            // desired state for a week still carries usable locators.
            var restore: DesiredRestore?
            if sendEdgeNonces, sandbox.restoreGeneration > 0, let snapshotID = sandbox.restoreSnapshotID {
                var artifacts: [SandboxSnapshotArtifactDescriptor]?
                if let snapshot = restoreSnapshots[snapshotID], snapshot.agentId != agentId {
                    artifacts = try? snapshot.exportedArtifactDescriptors()
                    if artifacts == nil {
                        app.logger.warning(
                            "Sandbox restore targets a snapshot on another agent whose exported copy is unavailable",
                            metadata: [
                                "sandboxId": .string(sandboxId.uuidString),
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
                    restoreFrom: restoreFrom,
                    restore: restore
                ))
        }

        // The security groups the topology authority realizes as port groups
        // + ACLs: groups attached to NICs of VMs and sandboxes on the hosts
        // whose topology the receiving agent authors, plus the transitive
        // closure of groups their rules reference (so `$pg_…` address-set
        // references always resolve). Nil for non-authoritative agents — they
        // only consume the per-NIC membership above — and for pre-v20 agents.
        let securityGroups: [DesiredSecurityGroup]?
        if sendSecurityGroups && scope.authoritative {
            securityGroups = try await desiredSecurityGroups(
                forVMs: scope.coveredVMs, sandboxes: scope.coveredSandboxes, on: db)
        } else {
            securityGroups = nil
        }

        // The agent's authoritative volume set (STR-148). Nil — not `[]` — for
        // an agent that does not speak volume sync, and the query is skipped
        // entirely for one: assembling entries a receiver will discard costs a
        // join and, worse, records image-download grants for a fetch that will
        // never happen.
        let volumes: [DesiredVolumeState]?
        if agent.map({ WireProtocol.supportsVolumeSync($0.wireProtocolVersion ?? 0) }) ?? true {
            volumes = try await desiredVolumes(agentId: agentId, on: db)
        } else {
            volumes = nil
        }

        // The agent's authoritative snapshot-artifact set (STR-150), with the
        // same nil-versus-empty contract and the same skip-the-query reasoning
        // as volumes above.
        let snapshots: [DesiredSnapshotState]?
        if agent.map({ WireProtocol.supportsSnapshotSync($0.wireProtocolVersion ?? 0) }) ?? true {
            snapshots = try await desiredSnapshots(agentId: agentId, on: db)
        } else {
            snapshots = nil
        }

        // The DNS zones the topology authority realizes into the OVN `DNS`
        // table (STR-39). Nil — not `[]` — for a non-authoritative agent, on
        // `securityGroups`' terms and one sharper one: these rows are
        // switch-scoped, so an empty list sent to a peer would have it read the
        // controller's live rows as garbage to sweep. Skipped entirely for an
        // agent that would discard the field, which is worth more here than
        // elsewhere: assembling a zone reads every VM registered in it.
        let dnsZones: [DesiredDNSZone]?
        if scope.authoritative,
            agent.map({ WireProtocol.supportsDNSZones($0.wireProtocolVersion ?? 0) }) ?? true
        {
            dnsZones = try await desiredDNSZones(networkIDs: scope.networkIDs, on: db)
        } else {
            dnsZones = nil
        }

        return DesiredStateMessage(
            vms: entries, sandboxes: sandboxEntries, networks: networkStates,
            networksAuthoritative: scope.authoritative,
            desiredAgentUpdate: await desiredAgentUpdateForSync(agent: agent),
            securityGroups: securityGroups,
            tombstones: try await tombstones(agentId: agentId, on: db),
            volumes: volumes,
            snapshots: snapshots,
            dnsZones: dnsZones)
    }

    /// The DNS zones this sync's topology authority should realize (STR-39):
    /// every zone attached to a network whose topology the receiving agent
    /// authors, with the zone's full effective contents.
    ///
    /// **The records are assembled fleet-wide, not from the receiving agent's
    /// own VMs.** That is the load-bearing difference between this and every
    /// other list in the sync. A zone's names span every VM on every network
    /// that registers into it — a VM created on agent A changes a zone realized
    /// by agent B — and `DNSZoneAssembler` reads those rows directly rather
    /// than from anything scoped to `agentId`. What the scope decides here is
    /// only *which zones* this agent is responsible for, never whose records
    /// they contain.
    ///
    /// A consequence worth naming: a zone attached to networks in two sites is
    /// realized identically in both, so site A answers for site B's VMs. That
    /// is DNS behaving as DNS — a name resolving is not a claim that the
    /// address is reachable — and the alternative (per-site subsets of one
    /// zone) would make a zone's contents depend on where you asked, which is
    /// what split-horizon views exist to express deliberately.
    private func desiredDNSZones(networkIDs: Set<UUID>, on db: any Database) async throws
        -> [DesiredDNSZone]
    {
        guard !networkIDs.isEmpty else { return [] }
        let attachments = try await DNSZoneNetwork.query(on: db)
            .filter(\.$logicalNetwork.$id ~~ Array(networkIDs))
            .all()
        guard !attachments.isEmpty else { return [] }

        var networksByZone: [UUID: [UUID]] = [:]
        for attachment in attachments {
            networksByZone[attachment.$zone.id, default: []].append(attachment.$logicalNetwork.id)
        }
        var names: [UUID: String] = [:]
        for zone in try await DNSZone.query(on: db).filter(\.$id ~~ Array(networksByZone.keys)).all() {
            guard let zoneID = zone.id else { continue }
            names[zoneID] = zone.name
        }

        // Batched, not one assembly per zone: this runs on *every* poll of the
        // authority agent, and each zone's derivation reads every NIC and VM on
        // its networks. `assemble(zones:)` is a fixed number of queries however
        // many zones a site's networks attach.
        return try await DNSZoneAssembler.assemble(zones: names, on: db)
            .map { DNSZoneAssembler.desiredZone($0, networkIDs: networksByZone[$0.zoneId] ?? []) }
            .sorted { $0.zoneId.uuidString < $1.zoneId.uuidString }
    }

    /// Every snapshot artifact this agent holds, as desired entries (STR-150).
    ///
    /// Three queries into one kind-tagged list, because that is the shape the
    /// agent's reconciler wants: one inventory to diff, with the entry's own
    /// `kind` routing the capture or the delete to a backend.
    ///
    /// Like volumes, nothing here carries a path or a size. The agent owns
    /// artifact layout and is the only party that can measure what it wrote, so
    /// both travel the other way, on the observed report.
    private func desiredSnapshots(agentId: String, on db: any Database) async throws
        -> [DesiredSnapshotState]
    {
        var entries: [DesiredSnapshotState] = []

        let volumeSnapshots = try await VolumeSnapshot.placed(onAgent: agentId, on: db)
        // One query for every parent volume's current attachment rather than
        // one per snapshot: assembly runs on every poll of every agent, so an
        // N+1 here is a per-sync cost that grows with the host's snapshot count.
        var attachedVMIds: [UUID: UUID] = [:]
        if !volumeSnapshots.isEmpty {
            let volumeIDs = Set(volumeSnapshots.map(\.$volume.id))
            for volume in try await Volume.query(on: db).filter(\.$id ~~ Array(volumeIDs)).all() {
                guard let volumeID = volume.id, let vmID = volume.$vm.id else { continue }
                attachedVMIds[volumeID] = vmID
            }
        }
        for snapshot in volumeSnapshots {
            guard let snapshotId = snapshot.id else { continue }
            entries.append(
                DesiredSnapshotState(
                    snapshotId: snapshotId,
                    kind: .volumeSnapshot,
                    parentId: snapshot.$volume.id,
                    desiredStatus: snapshot.desiredStatus,
                    generation: snapshot.generation,
                    // The capture strategy, read by the agent only when the
                    // overlay does not exist yet. Naming the holder is what lets
                    // the agent refuse rather than write a snapshot that is not
                    // point-in-time (issue #747), even though the API refused
                    // the same thing at admission: a level-triggered entry
                    // outlives the request that made it, and the volume may have
                    // been attached since.
                    capture: DesiredSnapshotCapture(
                        attachedVMId: attachedVMIds[snapshot.$volume.id])))
        }

        for snapshot in try await VMSnapshot.placed(onAgent: agentId, on: db) {
            guard let snapshotId = snapshot.id else { continue }
            entries.append(
                DesiredSnapshotState(
                    snapshotId: snapshotId,
                    kind: .vmCheckpoint,
                    parentId: snapshot.$vm.id,
                    desiredStatus: snapshot.desiredStatus,
                    generation: snapshot.generation))
        }

        for snapshot in try await SandboxSnapshot.placed(onAgent: agentId, on: db) {
            guard let snapshotId = snapshot.id else { continue }
            // The export placement fact: "this snapshot should also exist in
            // the control plane's object store". Upload slots are
            // control-plane-relative paths presented with the agent's SVID, so
            // — like image downloads since v13 — nothing here expires and the
            // entry is safe to sit in a sync indefinitely.
            var export: DesiredSnapshotExport?
            if snapshot.exportDesired {
                export = DesiredSnapshotExport(
                    uploads: SandboxSnapshotArtifactKind.allCases.map { kind in
                        SandboxSnapshotArtifactUploadTarget(
                            kind: kind,
                            uploadURL: SandboxSnapshot.artifactTransferPath(
                                sandboxId: snapshot.$sandbox.id, snapshotId: snapshotId, kind: kind))
                    })
            }
            entries.append(
                DesiredSnapshotState(
                    snapshotId: snapshotId,
                    kind: .sandboxSnapshot,
                    parentId: snapshot.$sandbox.id,
                    desiredStatus: snapshot.desiredStatus,
                    generation: snapshot.generation,
                    capture: DesiredSnapshotCapture(sandboxMode: snapshot.captureMode),
                    export: export))
        }

        return entries
    }

    /// Every volume placed on this agent, as desired entries (STR-148).
    ///
    /// Two things are worth noting about what this does *not* do. It does not
    /// carry a storage path: the agent owns path layout and reports it back, so
    /// a path here would be the control plane telling the agent something the
    /// agent told it. And it does not carry a pool: placement is expressed by
    /// *which agent's sync the entry appears in*, and a second encoding of the
    /// same fact is a thing that can drift.
    private func desiredVolumes(agentId: String, on db: any Database) async throws -> [DesiredVolumeState] {
        let volumes = try await Volume.query(on: db)
            .filter(\.$hypervisorId == agentId)
            .with(\.$sourceImage) { $0.with(\.$artifacts) }
            .all()

        var entries: [DesiredVolumeState] = []
        for volume in volumes {
            guard let volumeId = volume.id else { continue }

            // The create strategy, read by the agent only when it does not
            // already hold the volume. `sourceVolume` beats `sourceImage` when
            // both are set, because a clone's bytes come from the source volume
            // and its image lineage is only provenance.
            var source: DesiredVolumeSource?
            if let sourceVolumeID = volume.$sourceVolume.id {
                source = .clone(from: sourceVolumeID, format: volume.format.rawValue)
            } else if let image = volume.sourceImage, image.status == .ready, let imageId = image.id {
                do {
                    source = .image(try VMSpecBuilder.buildImageInfo(from: image))
                    // Emitting the URLs is what authorizes the fetch, exactly as
                    // it does for a VM's boot image (issue #562). This grant
                    // moved here from the old create RPC's dispatch: with no
                    // dispatch left, assembly is the only place that knows which
                    // agent is about to be asked to download what.
                    await app.coordination.grantImageDownload(agentId: agentId, imageId: imageId)
                } catch {
                    app.logger.warning(
                        "Failed to build image info for a volume's desired state; syncing without it",
                        metadata: [
                            "volumeId": .string(volumeId.uuidString),
                            "imageId": .string(imageId.uuidString),
                            "error": .string(error.localizedDescription),
                        ])
                }
            } else if volume.$sourceImage.id != nil {
                app.logger.warning(
                    "Volume references an image that is missing or not ready; syncing without image info",
                    metadata: ["volumeId": .string(volumeId.uuidString)])
            }

            // The attachment is projected from the same columns
            // `VMSpecBuilder.volumeSpecs` reads, so the two projections of one
            // fact cannot disagree — which is what used to let a volume be
            // `attached` in the VM's spec and detached in its own record.
            //
            // A name outside `VolumeDeviceName`'s charset cannot be stored (the
            // API validates it and the schema's check constraint plus unique
            // index hold the column to it), so the failed initializer below is
            // unreachable. Where `VMSpecBuilder.volumeSpecs` answers the same
            // impossible case by omitting the volume, this cannot: a desired
            // entry with no attachment reads as *detach*, and dropping the
            // entry entirely reads as a volume this agent should not hold. An
            // attachment the agent would refuse is the worse of the three, so
            // it is the one not sent — loudly, because a row that reached this
            // state is a broken invariant, not a routine skip.
            var attachment: DesiredVolumeAttachment?
            if let vmID = volume.$vm.id, let raw = volume.deviceName {
                if let deviceName = VolumeDeviceName(raw) {
                    attachment = DesiredVolumeAttachment(
                        vmId: vmID, deviceName: deviceName, readonly: volume.readonly,
                        bootOrder: volume.bootOrder)
                } else {
                    app.logger.error(
                        "Volume stores a device name no hypervisor accepts; syncing it detached",
                        metadata: [
                            "volumeId": .string(volumeId.uuidString),
                            "deviceName": .string(raw),
                        ])
                }
            }

            entries.append(
                DesiredVolumeState(
                    volumeId: volumeId,
                    desiredStatus: volume.desiredStatus,
                    generation: volume.generation,
                    sizeBytes: volume.size,
                    format: volume.format.rawValue,
                    source: source,
                    attachment: attachment,
                    // Emitted whether or not the volume is attached: a ceiling
                    // is a property of the volume, latent while it is detached
                    // and realized by the attach. `Volume.ioLimits` normalizes,
                    // so an uncapped volume omits the field entirely.
                    ioLimits: volume.ioLimits))
        }
        return entries
    }

    /// The teardowns this sync authorizes (STR-98).
    ///
    /// Every entry is the second half of a round trip: the agent reported
    /// holding a workload this assembly does not list, and
    /// `ObservedStateApplier` confirmed no row describes it. Nothing here is
    /// derived from the assembly's own queries, which is the point — a sync
    /// that under-lists an agent produces no tombstones at all, so a scoping
    /// bug can no longer authorize its own cleanup.
    private func tombstones(agentId: String, on db: any Database) async throws
        -> [DesiredWorkloadTombstone]
    {
        try await AgentWorkloadClaim.query(on: db)
            .filter(\.$agentId == agentId)
            .filter(\.$disposition == .tombstoned)
            .all()
            .compactMap { claim in
                guard let generation = claim.tombstoneGeneration else { return nil }
                return DesiredWorkloadTombstone(
                    kind: claim.resourceKind.workloadKind,
                    workloadId: claim.resourceID,
                    generation: generation)
            }
            .sorted { $0.workloadId.uuidString < $1.workloadId.uuidString }
    }

    /// The agent self-update this sync should carry (issue #434): whatever
    /// version the agent row has been assigned — by the fleet rollout sweep or
    /// by an operator's "update now", which since STR-145 is the same field —
    /// with its artifact re-resolved on every assembly, so a long-assigned
    /// update never carries a stale (possibly presigned) link. An operator's
    /// explicit artifact override has no release to re-resolve from and rides
    /// the row instead.
    ///
    /// Deliberately keyed on the assignment rather than on `autoUpdate`:
    /// enrollment governs whether the *sweep* may assign this agent, not
    /// whether an assignment is delivered — and withdrawing enrollment clears
    /// the assignment anyway. Nil whenever there is nothing actionable: not
    /// assigned, already converged, an agent too old to act on the field (a
    /// pre-v7 agent would wait out the health budget against silence), or an
    /// artifact that cannot currently be resolved (best effort — the sync also
    /// carries workload state and must not fail on the release host being
    /// down).
    private func desiredAgentUpdateForSync(agent: Agent?) async -> DesiredAgentUpdate? {
        guard let agent,
            let assigned = agent.updateDesiredVersion,
            AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: assigned),
            WireProtocol.supportsDesiredAgentUpdate(agent.wireProtocolVersion ?? 0)
        else { return nil }

        if let override = agent.updateArtifactOverride {
            return DesiredAgentUpdate(
                targetVersion: assigned,
                artifactURL: override.url,
                sha256: override.sha256,
                artifactKind: override.kind,
                tarballMember: override.kind == .tarball ? override.tarballMember : nil
            )
        }

        guard let operatingSystem = agent.hostOperatingSystem,
            let architecture = agent.cpuArchitecture
        else { return nil }

        do {
            let artifact = try await app.agentArtifactResolver.resolve(
                version: assigned, operatingSystem: operatingSystem, architecture: architecture)
            return DesiredAgentUpdate(
                targetVersion: assigned,
                artifactURL: artifact.url,
                sha256: artifact.sha256,
                artifactKind: artifact.kind,
                tarballMember: artifact.kind == .tarball ? artifact.tarballMember : nil
            )
        } catch {
            app.logger.warning(
                "Could not resolve the agent update artifact for the sync; omitting it",
                metadata: [
                    "agentName": .string(agent.name),
                    "targetVersion": .string(assigned),
                    "error": .string(String(describing: error)),
                ])
            return nil
        }
    }

    /// Load an id-indexed logical-network slice without ever issuing an
    /// unbounded table scan. Empty scopes intentionally produce no query.
    private func logicalNetworks(
        ids: Set<UUID>, on db: any Database
    ) async throws -> [UUID: LogicalNetwork] {
        guard !ids.isEmpty else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: try await LogicalNetwork.query(on: db)
                .filter(\.$id ~~ Array(ids))
                .all()
                .compactMap { network in network.id.map { ($0, network) } })
    }

    /// Per-sandbox registry work at sync assembly (issue #414): pins an
    /// unpinned tag to its manifest digest and derives the short-lived pull
    /// credential the sync carries. Best effort throughout — a registry that
    /// is down must not block the sync, which also carries state changes for
    /// already-materialized workloads.
    ///
    /// Digest pinning happens at most once per sandbox: the resolved digest is
    /// persisted (a targeted column update, so concurrent observed-state
    /// writes on the row are untouched) and never re-resolved, which is what
    /// makes convergence immutable — a re-tagged image cannot change a sandbox
    /// out from under its generation. Deliberately no generation bump: the pin
    /// matters to agents that have not materialized the sandbox yet, and must
    /// not re-converge ones that have.
    private func sandboxRegistryMaterial(
        _ sandbox: Sandbox,
        secrets: [RegistryPullSecret],
        on db: any Database
    ) async -> RegistryCredential? {
        // A sandbox on its way out pulls nothing: no digest pin, no
        // credential material toward the agent tearing it down.
        guard sandbox.desiredStatus != .absent else { return nil }

        guard let ref = OCIImageReference.parse(sandbox.image) else {
            app.logger.warning(
                "Sandbox image reference is unparseable; syncing without digest or credential",
                metadata: [
                    "sandboxId": .string(sandbox.id?.uuidString ?? ""),
                    "image": .string(sandbox.image),
                ])
            return nil
        }

        let secretRow = secrets.first { $0.registry == ref.registry }
        var basic: RegistryBasicCredential?
        if let secretRow {
            do {
                basic = RegistryBasicCredential(
                    username: secretRow.username,
                    password: try app.secretsEncryption.decrypt(secretRow.secret))
            } catch {
                app.logger.error(
                    "Failed to decrypt registry pull secret; treating the image as public",
                    metadata: [
                        "registry": .string(secretRow.registry),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        // Tag→digest pinning. Gated on the failure backoff: a pin that cannot
        // succeed (registry down, anonymous rate limit, a pull secret that no
        // longer authenticates) leaves `imageDigest` nil, so without the gate
        // every subsequent assembly would retry it. That retry used to be
        // bounded by the 10-minute forced sync pass; since STR-146 it would be
        // bounded by the poll rate instead, which would have the control plane
        // hammering the registry hardest for exactly the sandbox whose registry
        // is already unhealthy.
        if sandbox.imageDigest == nil, let sandboxId = sandbox.id {
            let backoffKey = RegistryOperationBackoff.Key(
                operation: .resolveDigest, registry: ref.registry, repository: ref.repository)
            guard await app.registryOperationBackoff.shouldAttempt(backoffKey) else {
                return await registryCredential(ref: ref, secretRow: secretRow, basic: basic)
            }
            do {
                if let digest = try await app.registryClient.resolveDigest(for: ref, credential: basic) {
                    sandbox.imageDigest = digest
                    try await Sandbox.query(on: db)
                        .filter(\.$id == sandboxId)
                        .set(\.$imageDigest, to: digest)
                        .update()
                    app.logger.info(
                        "Pinned sandbox image tag to digest",
                        metadata: [
                            "sandboxId": .string(sandboxId.uuidString),
                            "image": .string(sandbox.image),
                            "digest": .string(digest),
                        ])
                }
                await app.registryOperationBackoff.recordSuccess(backoffKey)
            } catch {
                // The agent then resolves the tag itself (accepting the
                // mutability) and a later sync retries the pin — after the
                // cooldown, not on the very next assembly.
                await app.registryOperationBackoff.recordFailure(backoffKey)
                app.logger.warning(
                    "Failed to resolve sandbox image tag to a digest; syncing unpinned",
                    metadata: [
                        "sandboxId": .string(sandboxId.uuidString),
                        "image": .string(sandbox.image),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        return await registryCredential(ref: ref, secretRow: secretRow, basic: basic)
    }

    /// The pull credential half of `sandboxRegistryMaterial`, split out so the
    /// digest-pin backoff can skip straight to it.
    private func registryCredential(
        ref: OCIImageReference,
        secretRow: RegistryPullSecret?,
        basic: RegistryBasicCredential?
    ) async -> RegistryCredential? {
        guard let secretRow, let basic else { return nil }
        let cacheKey = RegistryCredentialCache.Key(
            secretID: secretRow.id,
            registry: ref.registry,
            repository: ref.repository,
            username: secretRow.username,
            encryptedSecret: secretRow.secret)
        if let cached = await app.registryCredentialCache.credential(for: cacheKey) {
            return cached
        }

        // Only *successful* mints are cached, so without a backoff a token
        // service that is down would be re-dialed on every assembly — the same
        // hammering the digest pin above avoids, and on the same trigger.
        let backoffKey = RegistryOperationBackoff.Key(
            operation: .mintPullToken, registry: ref.registry, repository: ref.repository)
        guard await app.registryOperationBackoff.shouldAttempt(backoffKey) else {
            return Self.storedCredential(ref: ref, secretRow: secretRow, basic: basic)
        }

        do {
            if let token = try await app.registryClient.mintPullToken(for: ref, credential: basic) {
                let credential = RegistryCredential(
                    registry: ref.registry,
                    username: secretRow.username,
                    password: token.token,
                    expiresAt: token.expiresAt,
                    bearer: true)
                await app.registryCredentialCache.store(credential, for: cacheKey)
                await app.registryOperationBackoff.recordSuccess(backoffKey)
                return credential
            }
            // A registry with no token service is a permanent property of the
            // registry, not a failure — recording success keeps it off the
            // backoff so the (cheap) probe stays on its normal path.
            await app.registryOperationBackoff.recordSuccess(backoffKey)
        } catch let error as RegistryClientError {
            // Policy refusal (e.g. plaintext token realm), not transience:
            // a Basic fallback would hand the agent the stored secret to
            // present to the very endpoint the client just refused. Send
            // nothing; the pull fails loudly agent-side instead.
            app.logger.warning(
                "Refusing to send registry credential for sandbox image",
                metadata: [
                    "registry": .string(ref.registry),
                    "error": .string(error.localizedDescription),
                ])
            return nil
        } catch {
            await app.registryOperationBackoff.recordFailure(backoffKey)
            app.logger.warning(
                "Failed to mint a registry pull token; falling back to the stored credential",
                metadata: [
                    "registry": .string(ref.registry),
                    "error": .string(error.localizedDescription),
                ])
        }

        return Self.storedCredential(ref: ref, secretRow: secretRow, basic: basic)
    }

    /// Basic-only registry, or its token service is unreachable from the
    /// control plane: the stored credential is the only material that can
    /// authorize the pull. Agents hold it in memory only (wire contract).
    private static func storedCredential(
        ref: OCIImageReference,
        secretRow: RegistryPullSecret,
        basic: RegistryBasicCredential
    ) -> RegistryCredential {
        RegistryCredential(
            registry: ref.registry,
            username: secretRow.username,
            password: basic.password,
            expiresAt: nil,
            bearer: false)
    }

    /// Which networks an agent's sync should carry, and whether the agent is
    /// the topology authority for the NB it writes to (issue #343).
    ///
    /// - Site-less agent (legacy single-node model): it owns a private local
    ///   NB, so it is always authoritative, scoped to the networks its own
    ///   VMs reference — a network with no VM on the host needn't exist there.
    /// - Sited agent designated as the site's network controller: the whole
    ///   site shares one NB and this agent is its single topology writer, so
    ///   it gets every network referenced by any VM in the site plus every
    ///   network pinned to the site (pinned-but-unused networks are realized
    ///   ahead of their first VM).
    /// - Any other sited agent: non-authoritative and empty. It still binds
    ///   its own VMs' ports to the shared NB, but topology belongs to the
    ///   controller — two level-triggered writers would fight over teardown.
    private func networkAssemblyScope(
        agentId: String,
        agent: Agent?,
        site: Site?,
        ownVMs: [VM],
        ownSandboxes: [Sandbox],
        on db: any Database
    ) async throws -> NetworkAssemblyScope {
        // A network referenced by either a VM or a sandbox on this host must be
        // realized here (issue #416).
        var ownReferences = Set(ownVMs.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        ownReferences.formUnion(ownSandboxes.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })

        // `site` is loaded by the caller, which also names the metadata's
        // region. Today's only caller resolves it from this same `$site.id`, so
        // the equality below cannot fail; it is here so a future caller that
        // resolves a site some other way can't grant this agent topology
        // authority over a site that isn't its own. A mismatch falls through to
        // the legacy per-node scope, which is what a missing row already does.
        guard let agent,
            let agentUUID = agent.id,
            let siteID = agent.$site.id,
            let site, site.id == siteID
        else {
            return NetworkAssemblyScope(
                networkIDs: ownReferences,
                authoritative: true,
                floatingIPAgentIDs: [agentId],
                coveredVMs: ownVMs,
                coveredSandboxes: ownSandboxes)
        }

        // A pre-v4 agent doesn't know `networksAuthoritative` and would read
        // the non-authoritative shape (networks: [] + false) as an
        // authoritative teardown of its whole L3 topology. Keep it on the
        // legacy per-node scoping — its binary predates `ovn_northbound`, so
        // it is writing its own local NB anyway, not the site's shared one.
        guard WireProtocol.supportsSiteAuthority(agent.wireProtocolVersion ?? 0) else {
            app.logger.warning(
                "Sited agent registered with a pre-site-authority protocol; syncing legacy per-node networks",
                metadata: [
                    "agentName": .string(agent.name),
                    "site": .string(site.name),
                    "protocolVersion": .stringConvertible(agent.wireProtocolVersion ?? 0),
                ])
            return NetworkAssemblyScope(
                networkIDs: ownReferences,
                authoritative: true,
                floatingIPAgentIDs: [agentId],
                coveredVMs: ownVMs,
                coveredSandboxes: ownSandboxes)
        }

        guard let controllerID = site.$networkControllerAgent.id else {
            // No designated controller: nobody may author topology, so the
            // site's networks are realized nowhere until one is set. Loud —
            // this is a misconfiguration, not a transient.
            app.logger.warning(
                "Site has no network controller; its networks will not be reconciled",
                metadata: ["site": .string(site.name), "agentName": .string(agent.name)])
            return NetworkAssemblyScope(
                networkIDs: [],
                authoritative: false,
                floatingIPAgentIDs: [],
                coveredVMs: [],
                coveredSandboxes: [])
        }
        guard controllerID == agentUUID else {
            return NetworkAssemblyScope(
                networkIDs: [],
                authoritative: false,
                floatingIPAgentIDs: [],
                coveredVMs: [],
                coveredSandboxes: [])
        }

        let siteAgentIDs = try await Agent.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
            .compactMap { $0.id?.uuidString }
        let siteVMs = try await VM.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .with(\.$networkInterfaces)
            .all()
        var ids = Set(siteVMs.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        // Sandboxes placed anywhere in the site reference networks the
        // controller must realize too (issue #416) — and, since STR-102, the
        // security groups whose port groups it must author. Both come off this
        // one query: it already loads the NICs, so `coveredSandboxes` below is
        // a reuse of these rows, not a second read of them.
        let siteSandboxes = try await Sandbox.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .with(\.$networkInterfaces)
            .all()
        ids.formUnion(siteSandboxes.flatMap { $0.networkInterfaces.map(\.logicalNetworkID) })
        let pinned = try await LogicalNetwork.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
        ids.formUnion(pinned.compactMap(\.id))
        return NetworkAssemblyScope(
            networkIDs: ids,
            authoritative: true,
            floatingIPAgentIDs: Set(siteAgentIDs),
            coveredVMs: siteVMs,
            coveredSandboxes: siteSandboxes)
    }

    /// VM NIC id → attached security-group ids (sorted for stable wire output)
    /// for the given interfaces.
    private func nicSecurityGroupMemberships(
        interfaceIDs: [UUID], on db: any Database
    ) async throws -> [UUID: [UUID]] {
        guard !interfaceIDs.isEmpty else { return [:] }
        let memberships = try await VMInterfaceSecurityGroup.query(on: db)
            .filter(\.$interface.$id ~~ interfaceIDs)
            .all()
        var byInterface: [UUID: [UUID]] = [:]
        for membership in memberships {
            byInterface[membership.$interface.id, default: []].append(membership.$securityGroup.id)
        }
        return byInterface.mapValues { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    /// The sandbox twin (STR-102), reading the sandbox NICs' own join table.
    ///
    /// Its result is **discarded on every sync today**, and deliberately: the
    /// only consumer is `SandboxSpecBuilder.networkSpec`, which returns nil
    /// under a closed `guestNetworkingSupported`. That is one `IN` query per
    /// sync per agent that hosts sandbox NICs (the `isEmpty` guard means agents
    /// without them pay nothing), bought so the STR-103 flip is a one-line
    /// change rather than a new code path — and so nobody has to prove, at
    /// flip time, that a sandbox port comes up filtered. Named here so it is
    /// not later rediscovered as a mystery and optimized into a gap.
    ///
    /// Kept as a separate query and a separate dictionary rather than merged
    /// with the VM map: the two ids could only share a keyspace because they
    /// come from different tables and so cannot collide, which is true but
    /// unstated — and the cost of not relying on it is one local. Generalizing
    /// the two queries behind a protocol is worse still: the join models'
    /// `@Parent` fields are differently typed, so it would buy two call sites a
    /// layer of Fluent generics.
    private func sandboxNICSecurityGroupMemberships(
        interfaceIDs: [UUID], on db: any Database
    ) async throws -> [UUID: [UUID]] {
        guard !interfaceIDs.isEmpty else { return [:] }
        let memberships = try await SandboxInterfaceSecurityGroup.query(on: db)
            .filter(\.$interface.$id ~~ interfaceIDs)
            .all()
        var byInterface: [UUID: [UUID]] = [:]
        for membership in memberships {
            byInterface[membership.$interface.id, default: []].append(membership.$securityGroup.id)
        }
        return byInterface.mapValues { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    /// The security groups the desired-state sync should carry for a topology
    /// authority: every group attached to a NIC of a VM *or sandbox* placed on
    /// the hosts whose topology the receiving agent authors, expanded to the
    /// transitive closure over rule references so every `$pg_…` address-set
    /// match resolves against an existing port group.
    ///
    /// The sandbox arm (STR-102) runs even though a sandbox's `NetworkSpec` —
    /// and with it the per-NIC membership — is still withheld from the wire by
    /// `SandboxSpecBuilder.guestNetworkingSupported`. That is the point: the
    /// authority realizes a sandbox's port groups and ACLs *before* any sandbox
    /// port exists, so STR-103's flip is not also the moment those groups are
    /// first created, which would park every first sandbox create on
    /// `DependencyPendingError`. A port group with no members matches nothing,
    /// so realizing it early costs an OVN row and changes no traffic.
    private func desiredSecurityGroups(
        forVMs vms: [VM], sandboxes: [Sandbox], on db: any Database
    ) async throws -> [DesiredSecurityGroup] {
        let vmInterfaceIDs = vms.flatMap { $0.networkInterfaces.compactMap(\.id) }
        let sandboxInterfaceIDs = sandboxes.flatMap { $0.networkInterfaces.compactMap(\.id) }
        // Both seeds, not just the VM one: an agent (or a whole site) hosting
        // sandboxes and no VM NICs would otherwise silently receive no groups
        // at all, and nothing downstream would report the omission.
        guard !vmInterfaceIDs.isEmpty || !sandboxInterfaceIDs.isEmpty else { return [] }

        var groupIDs: Set<UUID> = []
        if !vmInterfaceIDs.isEmpty {
            groupIDs.formUnion(
                try await VMInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id ~~ vmInterfaceIDs)
                    .all()
                    .map { $0.$securityGroup.id })
        }
        if !sandboxInterfaceIDs.isEmpty {
            groupIDs.formUnion(
                try await SandboxInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id ~~ sandboxInterfaceIDs)
                    .all()
                    .map { $0.$securityGroup.id })
        }

        // Reference closure: rules pointing at groups outside the attached
        // set pull those groups in (definitions only — their ACLs matter for
        // the address set, and membership comes from whatever NICs attach
        // them). Bounded by the per-project group cap.
        var frontier = groupIDs
        while !frontier.isEmpty {
            let referenced = Set(
                try await SecurityGroupRule.query(on: db)
                    .filter(\.$securityGroup.$id ~~ Array(frontier))
                    .all()
                    .compactMap { $0.$remoteGroup.id })
            frontier = referenced.subtracting(groupIDs)
            groupIDs.formUnion(frontier)
        }
        guard !groupIDs.isEmpty else { return [] }

        let groups = try await SecurityGroup.query(on: db)
            .filter(\.$id ~~ Array(groupIDs))
            .with(\.$rules)
            .all()
        return
            groups
            .compactMap { group -> DesiredSecurityGroup? in
                guard let groupId = group.id else { return nil }
                let rules = group.rules.compactMap { rule -> DesiredSecurityGroupRule? in
                    guard let ruleId = rule.id else { return nil }
                    return DesiredSecurityGroupRule(
                        id: ruleId,
                        direction: rule.direction.rawValue,
                        ethertype: rule.ethertype.rawValue,
                        protocolName: rule.protocolName,
                        portRangeMin: rule.portRangeMin,
                        portRangeMax: rule.portRangeMax,
                        remoteCIDR: rule.remoteCIDR,
                        remoteGroupId: rule.$remoteGroup.id,
                        log: rule.log
                    )
                }
                .sorted { $0.id.uuidString < $1.id.uuidString }
                return DesiredSecurityGroup(id: groupId, generation: group.generation, rules: rules)
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Floating IPs (issue #344) the desired-state sync should carry, keyed by
    /// the attached NIC's network name: each becomes a `dnat_and_snat` rule on
    /// that network's router. Only attachments to VMs placed on `agentIDs` —
    /// the hosts whose topology the receiving agent authors — so a site-less
    /// agent never NATs for a VM on some other node's private NB.
    private func desiredFloatingIPs(
        forAgentIDs agentIDs: Set<String>, on db: any Database
    ) async throws -> [UUID: [DesiredFloatingIP]] {
        guard !agentIDs.isEmpty else { return [:] }
        let attached = try await FloatingIP.query(on: db)
            .filter(\.$interface.$id != nil)
            .with(\.$interface)
            .all()
        guard !attached.isEmpty else { return [:] }

        // Load the owning VMs (scoped to the covered agents) with their full
        // NIC lists: the NAT rule's `nicIndex` is the NIC's position in the
        // same (orderIndex, deviceName) order the spec builder uses, which
        // takes the sibling interfaces to compute.
        let vmIDs = Set(attached.compactMap { $0.interface?.$vm.id })
        let vmsByID = try await Dictionary(
            VM.query(on: db)
                .filter(\.$id ~~ vmIDs)
                .filter(\.$hypervisorId ~~ agentIDs)
                .with(\.$networkInterfaces) { $0.with(\.$addresses) }
                .all()
                .compactMap { vm in vm.id.map { ($0, vm) } },
            uniquingKeysWith: { first, _ in first }
        )

        var byNetwork: [UUID: [DesiredFloatingIP]] = [:]
        for floatingIP in attached {
            guard let interface = floatingIP.interface,
                let vm = vmsByID[interface.$vm.id],
                let vmId = vm.id
            else { continue }
            let ordered = vm.networkInterfaces.inDeviceOrder
            guard let nicIndex = ordered.firstIndex(where: { $0.id == interface.id }),
                let logicalIP = ordered[nicIndex].ipv4Address?.address
            else {
                app.logger.warning(
                    "Floating IP attached to a NIC without an IPv4 address; skipping its NAT rule",
                    metadata: ["address": .string(floatingIP.address)])
                continue
            }
            byNetwork[interface.logicalNetworkID, default: []].append(
                DesiredFloatingIP(
                    externalIP: floatingIP.address,
                    logicalIP: logicalIP,
                    vmId: vmId,
                    nicIndex: nicIndex))
        }
        return byNetwork.mapValues { $0.sorted { $0.externalIP < $1.externalIP } }
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
