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
        let networkNames: Set<String>
        let authoritative: Bool
        let floatingIPAgentIDs: Set<String>
        /// VMs whose topology this agent authors. These are already loaded
        /// with NICs while deriving the network scope, so security-group
        /// assembly must reuse them rather than querying the same rows again.
        let coveredVMs: [VM]
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
            agentId: agentId, agent: agent, ownVMs: vms, ownSandboxes: sandboxes, on: db)

        // DHCP/DNS config lives on the logical-network row. Query exactly the
        // union used by local workload specs and authoritative topology.
        let ownVMNetworkNames = Set(vms.flatMap { $0.networkInterfaces.map(\.network) })
        let sandboxNetworkNames = Set(
            sandboxes.flatMap { $0.networkInterfaces.map(\.network) })
        let requiredNetworkNames =
            ownVMNetworkNames.union(sandboxNetworkNames).union(scope.networkNames)
        let networksByName = try await logicalNetworksByName(
            names: requiredNetworkNames, on: db)

        // NIC → security-group membership for the specs (and, below, the
        // group definitions the topology authority realizes). Omitted
        // entirely for pre-v20 agents: they would decode and silently ignore
        // the fields, so sending them only misstates what the sync achieved;
        // the attach API refuses new attachments against such agents.
        let sendSecurityGroups =
            agent.map { WireProtocol.supportsSecurityGroups($0.wireProtocolVersion ?? 0) } ?? true
        let securityGroupsByInterface: [UUID: [UUID]]
        if sendSecurityGroups {
            securityGroupsByInterface = try await nicSecurityGroupMemberships(
                interfaceIDs: vms.flatMap { $0.networkInterfaces.compactMap(\.id) }, on: db)
        } else {
            securityGroupsByInterface = [:]
        }

        var entries: [DesiredVMState] = []
        for vm in vms {
            guard let vmId = vm.id else { continue }
            let image = vm.sourceImage
            let spec = VMSpecBuilder.buildVMSpecWithVolumes(
                from: vm,
                image: image,
                volumes: vm.volumes,
                networkInterfaces: vm.networkInterfaces,
                networks: networksByName,
                securityGroupsByInterface: securityGroupsByInterface
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

            entries.append(
                DesiredVMState(
                    vmId: vmId,
                    hypervisorType: vm.hypervisorType,
                    spec: spec,
                    desiredStatus: vm.desiredStatus,
                    generation: vm.generation,
                    imageInfo: imageInfo
                ))
        }

        // First-class network desired state (issue #342): the logical networks
        // the agent should realize as level-triggered desired state (switches,
        // per-project routers, SNAT uplinks). Which networks — and whether this
        // agent may write topology at all — depends on its site membership
        // (issue #343); see `networkAssemblyScope`.
        // Floating IPs attached to NICs of VMs the receiving agent's topology
        // writes cover (issue #344): its own VMs for a site-less agent, every
        // site VM for the site's controller. Keyed by network name, matching
        // how the NAT rule lands on that network's router. Omitted entirely
        // for pre-v12 agents — they would decode and silently ignore the
        // field, so sending it only misstates what the sync achieved; the
        // attach API refuses new attachments against such agents.
        let floatingIPsByNetwork: [String: [DesiredFloatingIP]]
        if agent.map({ WireProtocol.supportsFloatingIPs($0.wireProtocolVersion ?? 0) }) ?? true {
            floatingIPsByNetwork = try await desiredFloatingIPs(
                forAgentIDs: scope.floatingIPAgentIDs, on: db)
        } else {
            floatingIPsByNetwork = [:]
        }
        let networkStates =
            scope.networkNames
            .sorted()
            .compactMap { name -> DesiredNetworkState? in
                guard let network = networksByName[name], let networkId = network.id else { return nil }
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
                    generation: Int64(network.generation),
                    floatingIPs: floatingIPsByNetwork[name]
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
        let restoreSnapshotIDs = Set(sandboxes.compactMap(\.restoredFromSnapshotId))
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
            // Nil until guest networking lands (see
            // SandboxSpecBuilder.guestNetworkingSupported) — agents reject
            // networked sandbox specs, so a NIC on the wire would fail every
            // create.
            let interface = sandbox.networkInterfaces.first
            let networkSpec = SandboxSpecBuilder.networkSpec(
                from: interface,
                network: interface.flatMap { networksByName[$0.network] })
            sandboxEntries.append(
                DesiredSandboxState(
                    sandboxId: sandboxId,
                    spec: sandbox.buildSpec(network: networkSpec, restoreFrom: restoreFrom),
                    desiredStatus: sandbox.desiredStatus,
                    generation: sandbox.generation,
                    registryCredential: registryCredential,
                    restoreFrom: restoreFrom
                ))
        }

        // The security groups the topology authority realizes as port groups
        // + ACLs: groups attached to NICs of VMs on the hosts whose topology
        // the receiving agent authors, plus the transitive closure of groups
        // their rules reference (so `$pg_…` address-set references always
        // resolve). Nil for non-authoritative agents — they only consume the
        // per-NIC membership above — and for pre-v20 agents.
        let securityGroups: [DesiredSecurityGroup]?
        if sendSecurityGroups && scope.authoritative {
            securityGroups = try await desiredSecurityGroups(
                forVMs: scope.coveredVMs, on: db)
        } else {
            securityGroups = nil
        }

        return DesiredStateMessage(
            vms: entries, sandboxes: sandboxEntries, networks: networkStates,
            networksAuthoritative: scope.authoritative,
            desiredAgentUpdate: await desiredAgentUpdateForSync(agent: agent),
            securityGroups: securityGroups)
    }

    /// The agent self-update this sync should carry (issue #434): the rollout
    /// sweep's assignment on the agent row, with its artifact re-resolved on
    /// every assembly, so a long-assigned update never carries a stale
    /// (possibly presigned) link. Nil whenever there is
    /// nothing actionable: not enrolled, not assigned, already converged, an
    /// agent too old to act on the field (a pre-v7 agent would wait out the
    /// rollout's health budget against silence), or an artifact that cannot
    /// currently be resolved (best effort — the sync also carries workload
    /// state and must not fail on the release host being down).
    private func desiredAgentUpdateForSync(agent: Agent?) async -> DesiredAgentUpdate? {
        guard let agent,
            agent.autoUpdate,
            let assigned = agent.updateDesiredVersion,
            AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: assigned),
            WireProtocol.supportsDesiredAgentUpdate(agent.wireProtocolVersion ?? 0),
            let operatingSystem = agent.hostOperatingSystem,
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

    /// Load a name-indexed logical-network slice without ever issuing an
    /// unbounded table scan. Empty scopes intentionally produce no query.
    private func logicalNetworksByName(
        names: Set<String>, on db: any Database
    ) async throws -> [String: LogicalNetwork] {
        guard !names.isEmpty else { return [:] }
        return Dictionary(
            try await LogicalNetwork.query(on: db)
                .filter(\.$name ~~ Array(names))
                .all()
                .map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
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

        // Tag→digest pinning.
        if sandbox.imageDigest == nil, let sandboxId = sandbox.id {
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
            } catch {
                // The agent then resolves the tag itself (accepting the
                // mutability) and the next sync retries the pin.
                app.logger.warning(
                    "Failed to resolve sandbox image tag to a digest; syncing unpinned",
                    metadata: [
                        "sandboxId": .string(sandboxId.uuidString),
                        "image": .string(sandbox.image),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

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

        do {
            if let token = try await app.registryClient.mintPullToken(for: ref, credential: basic) {
                let credential = RegistryCredential(
                    registry: ref.registry,
                    username: secretRow.username,
                    password: token.token,
                    expiresAt: token.expiresAt,
                    bearer: true)
                await app.registryCredentialCache.store(credential, for: cacheKey)
                return credential
            }
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
            app.logger.warning(
                "Failed to mint a registry pull token; falling back to the stored credential",
                metadata: [
                    "registry": .string(ref.registry),
                    "error": .string(error.localizedDescription),
                ])
        }

        // Basic-only registry, or its token service is unreachable from the
        // control plane: the stored credential is the only material that can
        // authorize the pull. Agents hold it in memory only (wire contract).
        return RegistryCredential(
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
        ownVMs: [VM],
        ownSandboxes: [Sandbox],
        on db: any Database
    ) async throws -> NetworkAssemblyScope {
        // A network referenced by either a VM or a sandbox on this host must be
        // realized here (issue #416).
        var ownReferences = Set(ownVMs.flatMap { $0.networkInterfaces.map(\.network) })
        ownReferences.formUnion(ownSandboxes.flatMap { $0.networkInterfaces.map(\.network) })

        guard let agent,
            let agentUUID = agent.id,
            let siteID = agent.$site.id,
            let site = try await Site.find(siteID, on: db)
        else {
            return NetworkAssemblyScope(
                networkNames: ownReferences,
                authoritative: true,
                floatingIPAgentIDs: [agentId],
                coveredVMs: ownVMs)
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
                networkNames: ownReferences,
                authoritative: true,
                floatingIPAgentIDs: [agentId],
                coveredVMs: ownVMs)
        }

        guard let controllerID = site.$networkControllerAgent.id else {
            // No designated controller: nobody may author topology, so the
            // site's networks are realized nowhere until one is set. Loud —
            // this is a misconfiguration, not a transient.
            app.logger.warning(
                "Site has no network controller; its networks will not be reconciled",
                metadata: ["site": .string(site.name), "agentName": .string(agent.name)])
            return NetworkAssemblyScope(
                networkNames: [],
                authoritative: false,
                floatingIPAgentIDs: [],
                coveredVMs: [])
        }
        guard controllerID == agentUUID else {
            return NetworkAssemblyScope(
                networkNames: [],
                authoritative: false,
                floatingIPAgentIDs: [],
                coveredVMs: [])
        }

        let siteAgentIDs = try await Agent.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
            .compactMap { $0.id?.uuidString }
        let siteVMs = try await VM.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .with(\.$networkInterfaces)
            .all()
        var names = Set(siteVMs.flatMap { $0.networkInterfaces.map(\.network) })
        // Sandboxes placed anywhere in the site reference networks the
        // controller must realize too (issue #416).
        let siteSandboxes = try await Sandbox.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .with(\.$networkInterfaces)
            .all()
        names.formUnion(siteSandboxes.flatMap { $0.networkInterfaces.map(\.network) })
        let pinned = try await LogicalNetwork.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
        names.formUnion(pinned.map(\.name))
        return NetworkAssemblyScope(
            networkNames: names,
            authoritative: true,
            floatingIPAgentIDs: Set(siteAgentIDs),
            coveredVMs: siteVMs)
    }

    /// NIC id → attached security-group ids (sorted for stable wire output)
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

    /// The security groups the desired-state sync should carry for a topology
    /// authority: every group attached to a NIC of a VM placed on `agentIDs`
    /// (the hosts whose topology the receiving agent authors), expanded to
    /// the transitive closure over rule references so every `$pg_…`
    /// address-set match resolves against an existing port group.
    private func desiredSecurityGroups(
        forVMs vms: [VM], on db: any Database
    ) async throws -> [DesiredSecurityGroup] {
        let interfaceIDs = vms.flatMap { $0.networkInterfaces.compactMap(\.id) }
        guard !interfaceIDs.isEmpty else { return [] }

        var groupIDs = Set(
            try await VMInterfaceSecurityGroup.query(on: db)
                .filter(\.$interface.$id ~~ interfaceIDs)
                .all()
                .map { $0.$securityGroup.id })

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
                        remoteGroupId: rule.$remoteGroup.id
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
    ) async throws -> [String: [DesiredFloatingIP]] {
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

        var byNetwork: [String: [DesiredFloatingIP]] = [:]
        for floatingIP in attached {
            guard let interface = floatingIP.interface,
                let vm = vmsByID[interface.$vm.id],
                let vmId = vm.id
            else { continue }
            let ordered = vm.networkInterfaces.sorted {
                ($0.orderIndex, $0.deviceName) < ($1.orderIndex, $1.deviceName)
            }
            guard let nicIndex = ordered.firstIndex(where: { $0.id == interface.id }),
                let logicalIP = ordered[nicIndex].ipv4Address?.address
            else {
                app.logger.warning(
                    "Floating IP attached to a NIC without an IPv4 address; skipping its NAT rule",
                    metadata: ["address": .string(floatingIP.address)])
                continue
            }
            byNetwork[interface.network, default: []].append(
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
