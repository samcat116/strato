import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import StratoShared
import StratoAgentCore
import StratoAgentSPIFFE

#if os(Linux)
// One shared Firecracker client backs both VMs and sandboxes (issue #421).
import SwiftFirecracker
// geteuid(): the jailer needs root, so the start-time jailer resolution
// (issue #425) checks the effective uid.
import Glibc
#endif

// MARK: - Message Handling

extension Agent {
    /// Start the single consumer that drains the ordered inbound stream. Idempotent, so
    /// repeated calls (e.g. across reconnects) reuse the existing consumer.
    func startMessageConsumer() {
        guard messageConsumerTask == nil else { return }
        let stream = inboundMessages
        messageConsumerTask = Task { [weak self] in
            for await frame in stream {
                await self?.routeInboundMessage(frame)
            }
        }
    }

    private func routeInboundMessage(_ frame: InboundWebSocketFrame) async {
        await routeInboundMessage(frame.envelope, wireByteCount: frame.byteCount)
    }

    /// Route a decoded inbound frame onto its per-resource serial lane. Frames for the same
    /// resource run in arrival order; frames for unrelated resources run concurrently.
    func routeInboundMessage(_ envelope: MessageEnvelope, wireByteCount: Int? = nil) async {
        await messageQueue.enqueue(keys: envelope.serializationKeys) { [weak self] in
            await self?.handleMessage(envelope, wireByteCount: wireByteCount)
        }
    }

    /// Decode once for normal handling, then derive transport metadata from the
    /// typed value. HTTP-polled desired state has no WebSocket byte count and is
    /// deliberately omitted from the WebSocket transport log.
    private func decodeInboundMessage<T: WebSocketMessage>(
        _ envelope: MessageEnvelope,
        as type: T.Type,
        wireByteCount: Int?
    ) throws -> T {
        let message = try envelope.decode(as: type)
        if let wireByteCount {
            WireMessageLogger.log(
                message: message,
                direction: .inbound,
                byteCount: wireByteCount,
                logger: logger)
        }
        return message
    }

    func handleMessage(_ envelope: MessageEnvelope, wireByteCount: Int? = nil) async {
        do {
            switch envelope.type {
            case .agentRegisterResponse:
                let message: AgentRegisterResponseMessage
                do {
                    message = try decodeInboundMessage(
                        envelope,
                        as: AgentRegisterResponseMessage.self,
                        wireByteCount: wireByteCount)
                } catch DecodingError.keyNotFound(let key, _)
                    where key.stringValue == "protocolVersion"
                {
                    let reason =
                        "Control plane registration response omitted the required wire protocol version; "
                        + "this agent requires exactly v\(WireProtocol.currentVersion). Deploy a matching "
                        + "control-plane build."
                    logger.error("Registration rejected: \(reason)")
                    if let continuation = takeRegistrationContinuation() {
                        continuation.resume(throwing: AgentError.registrationRejected(reason))
                    }
                    return
                }
                await handleRegistrationResponse(message)
            // No VM frames remain: reboot and restore became edge-nonces on the
            // desired entry at wire v34 (STR-151), joining capture and delete,
            // which became desired artifacts at v33 (STR-150).
            case .desiredState:
                let message = try decodeInboundMessage(
                    envelope,
                    as: DesiredStateMessage.self,
                    wireByteCount: wireByteCount)
                // Realize logical networks (per-project routers, SNAT uplinks)
                // before converging VMs, so a VM's switch and L3 gateway exist
                // before its NIC attaches (issue #342). Level-triggered and
                // idempotent, like the VM reconcile that follows.
                //
                // `metadataNetworks` is declared out here because the
                // guest-facing listeners below are driven from the same list,
                // after the reconciler has run.
                let metadataNetworks: [UUID]
                do {
                    // This host's own workload ports' desired security-group
                    // membership, derived from each NIC's stable slot (with
                    // compact array position only for legacy specs). Converged
                    // on every agent; port groups + ACLs themselves are
                    // authored only by the topology authority from
                    // `message.securityGroups`.
                    var portMemberships = VMPortMembershipPlanner.memberships(for: message.vms)
                    // The sandbox arm (STR-102). Three things here are exact
                    // rather than approximate, and each fails silently if it
                    // drifts — `reconcileMembership` says nothing about a port
                    // name `observeMembership` didn't return:
                    //
                    // - `nicIndex: 0` because a sandbox has exactly one NIC:
                    //   `sandboxReconcileCreate` builds its attachment list as
                    //   `spec.network.map { [$0] } ?? []`.
                    // - `uuidString` (uppercase) because that is the string the
                    //   reconciler's work item carried into `createVMNetwork`
                    //   as `vmId`, and therefore what the LSP is named after.
                    // - `sandboxPortName`, not `vmPortName`: `sbx-` and `vm-`
                    //   are deliberately separate namespaces (see OVNNaming).
                    //
                    // Membership convergence never removes a port it wasn't
                    // given, so an empty sandbox list is inert here — unlike
                    // `metadataNetworks` below, where an empty list is an
                    // instruction.
                    //
                    // No `metadataDenied` either: the kill switch is per VM
                    // because the document is, and a sandbox has none — the
                    // listener serves `InstanceMetadata`, which only
                    // `DesiredVMState` carries. A sandbox's port is left out of
                    // the deny group because there is nothing on the other end
                    // of the address for it to be denied.
                    portMemberships += message.sandboxes.compactMap { sandbox in
                        sandbox.spec.network.map { spec in
                            DesiredPortMembership(
                                portName: OVNNaming.sandboxPortName(
                                    sandboxId: sandbox.sandboxId.uuidString, nicIndex: 0),
                                securityGroupIds: spec.securityGroupIds)
                        }
                    }
                    // The networks this host must materialize the metadata
                    // address on (STR-49), derived from our own workload specs
                    // rather than `message.networks`: a sited agent that is not
                    // its site's network controller receives an empty topology
                    // list by design, yet its guests need the service just the
                    // same. Same derivation as `portMemberships` above, and the
                    // same "this host owns it without topology authority"
                    // reason.
                    var ids = Set(
                        message.vms.flatMap { $0.spec.networks }
                            .filter { $0.metadataEnabled == true }.map(\.networkId))
                    ids.formUnion(
                        message.sandboxes.compactMap { $0.spec.network }
                            .filter { $0.metadataEnabled == true }.map(\.networkId))
                    metadataNetworks = ids.sorted { $0.uuidString < $1.uuidString }
                    // The resolver's twin of the list above (STR-40), derived
                    // the same way from the same specs. Kept separate rather
                    // than merged here because the two gates are different
                    // versions and the receiving service is what folds them
                    // into one per-network service set — a network wanting only
                    // one of the two still gets exactly one namespace.
                    // Carries the network's upstream forwarders and search
                    // domain alongside the id, because the resolver itself needs
                    // them and `message.networks` is empty on a non-authority
                    // agent. Two NICs on one network describe the same resolver,
                    // so the first wins — they are two copies of one row's
                    // columns, not two opinions.
                    //
                    // **Field presence decides here, and that is the
                    // difference from `metadataNetworks` above.** The sender
                    // always emits `metadataEnabled`, so its per-NIC nil never
                    // arises; `resolverEnabled` genuinely can be nil on every
                    // spec of a sync — the control plane withholds it for a
                    // host it cannot describe, precisely so as not to disable a
                    // live service. Reading that silence as a non-nil *empty*
                    // list would be an instruction `ResolverSupervisionPolicy`
                    // obeys: every CoreDNS stopped and every resolver address
                    // dropped, restored on the next sync. A DNS outage per
                    // occurrence, on the one path built to stay quiet.
                    //
                    // One exception has to stay an opinion. A host running *no
                    // workloads* has no specs to carry the field, and that is a
                    // statement rather than a silence: it serves nothing, so it
                    // should serve no resolvers either. Without that arm the
                    // last VM leaving a host would leak its resolvers forever.
                    let resolverNetworks: [ResolverNetworkConfig]?
                    let specs =
                        message.vms.flatMap { $0.spec.networks }
                        + message.sandboxes.compactMap { $0.spec.network }
                    if !specs.isEmpty, specs.allSatisfy({ $0.resolverEnabled == nil }) {
                        resolverNetworks = nil
                    } else {
                        var byNetwork: [UUID: ResolverNetworkConfig] = [:]
                        for spec in specs
                        where spec.resolverEnabled == true
                            && !(spec.resolverAddresses ?? []).isEmpty
                        {
                            guard byNetwork[spec.networkId] == nil else { continue }
                            byNetwork[spec.networkId] = ResolverNetworkConfig(
                                networkId: spec.networkId,
                                addresses: spec.resolverAddresses ?? [],
                                upstreams: spec.dnsServers,
                                searchDomain: spec.domainName)
                        }
                        resolverNetworks = byNetwork.values.sorted {
                            $0.networkId.uuidString < $1.networkId.uuidString
                        }
                    }
                    // DNS zones (STR-39): nil means this agent is not the
                    // topology authority — leave every managed `DNS` row
                    // alone. Only an explicit list is an instruction.
                    let dnsZones = message.dnsZones
                    await networkService?.reconcileNetworks(
                        message.networks, authoritative: message.networksAuthoritative,
                        securityGroups: message.securityGroups,
                        portMemberships: portMemberships,
                        metadataNetworks: metadataNetworks,
                        resolverNetworks: resolverNetworks,
                        dnsZones: dnsZones)
                }
                // One belt survives the version gates' retirement inside
                // `apply`: a nil `volumes` field skips the volume half
                // entirely, because misreading silence there destroys the only
                // copy of user data (STR-148). Snapshots carry the same nil
                // contract.
                await reconciler?.apply(message)
                // The guest-facing listeners, after the reconciler rather than
                // beside the network reconcile above (STR-56). Both orderings
                // are needed and only this one has both: `reconcileNetworks`
                // has already realized the namespaces a listener binds in, and
                // `apply` has already written this sync's metadata to the store
                // the snapshot is built from. Driven off the same
                // `metadataNetworks` list, so there is no second derivation to
                // drift.
                await reconcileMetadataServers(networks: metadataNetworks)
                // Firecracker has no listener reading `MetadataStore`: MMDS is
                // a snapshot held by each VMM. Refresh managed microVMs from
                // the generation-guarded store after `apply`, including
                // equal-generation metadata-only edits and withdrawals.
                await refreshFirecrackerMetadata(for: message.vms)
                // Declarative agent self-update (issue #434), after the
                // reconciler so freshly enqueued work items are visible to the
                // precondition gate — the update only runs on a sync that
                // arrives with the lanes already drained.
                await handleDesiredAgentUpdate(message.desiredAgentUpdate)
            case .consoleConnect:
                let message = try decodeInboundMessage(
                    envelope,
                    as: ConsoleConnectMessage.self,
                    wireByteCount: wireByteCount)
                await handleConsoleConnect(message)
            case .consoleDisconnect:
                let message = try decodeInboundMessage(
                    envelope,
                    as: ConsoleDisconnectMessage.self,
                    wireByteCount: wireByteCount)
                await handleConsoleDisconnect(message)
            case .consoleData:
                let message = try decodeInboundMessage(
                    envelope,
                    as: ConsoleDataMessage.self,
                    wireByteCount: wireByteCount)
                await handleConsoleData(message)
            // Guest exec sessions (STR-78).
            case .guestExecStart:
                let message = try decodeInboundMessage(
                    envelope,
                    as: GuestExecStartMessage.self,
                    wireByteCount: wireByteCount)
                await handleGuestExecStart(message)
            case .guestExecInput:
                let message = try decodeInboundMessage(
                    envelope,
                    as: GuestExecInputMessage.self,
                    wireByteCount: wireByteCount)
                await handleGuestExecInput(message)
            case .guestExecResize:
                let message = try decodeInboundMessage(
                    envelope,
                    as: GuestExecResizeMessage.self,
                    wireByteCount: wireByteCount)
                await handleGuestExecResize(message)
            case .guestExecClose:
                let message = try decodeInboundMessage(
                    envelope,
                    as: GuestExecCloseMessage.self,
                    wireByteCount: wireByteCount)
                await handleGuestExecClose(message)
            // No sandbox lifecycle frames remain either: `sandbox_restore`
            // became `DesiredSandboxState.restore` at wire v34 (STR-151), and
            // capture/delete/export became desired artifacts at v33 (STR-150).
            // No volume frames remain: create/delete/attach/detach/resize/clone
            // became desired state at wire v31 (STR-148), `volume_info` was
            // deleted at v32 as a read that was never an action (STR-149), and
            // both snapshot verbs became desired artifacts at v33 (STR-150).
            case .success:
                // ACK to an agent-initiated request (including every heartbeat).
                // It needs no action; the transport record already carries its
                // type, request id and size without exposing `message`.
                _ = try decodeInboundMessage(
                    envelope,
                    as: SuccessMessage.self,
                    wireByteCount: wireByteCount)
            case .error:
                let message = try decodeInboundMessage(
                    envelope,
                    as: ErrorMessage.self,
                    wireByteCount: wireByteCount)
                await handleErrorResponse(message)
            default:
                logger.warning("Received unknown message type: \(envelope.type)")
            }
        } catch {
            WireMessageLogger.logMessageHandlingFailure(envelope: envelope, logger: logger)
        }
    }

    /// Resolves VM network attachments before hypervisor drivers run and tears
    /// them down after VMs are deleted. Rebuilt per use because `networkService`
    /// is only set once the agent has started.
    var networkOrchestrator: NetworkOrchestrator {
        NetworkOrchestrator(networkService: networkService, logger: logger)
    }

    /// Get the hypervisor service for a VM based on its type. A missing
    /// registry entry means no driver for that backend runs on this host
    /// (e.g. Firecracker on macOS). No silent fallback to another driver: the
    /// scheduler should never place such a VM here, so surface the mismatch
    /// as an error instead of booting the VM under a different hypervisor
    /// than requested.
    func getHypervisorService(for hypervisorType: HypervisorType) -> (any HypervisorService)? {
        guard let service = hypervisorServices[hypervisorType] else {
            logger.error(
                "No \(hypervisorType.displayName) driver on this host; rejecting request for unsupported hypervisor")
            return nil
        }
        return service
    }

    /// Get the hypervisor service for an existing VM
    func getHypervisorServiceForVM(vmId: String) -> (any HypervisorService)? {
        guard let entry = managedVMs[vmId] ?? orphanedVMs[vmId] else {
            // No silent QEMU fallback: routing a VM to a backend that never created
            // it can only yield misleading vmNotFound errors (or operate on the
            // wrong VM). An unknown vmId means this agent has no record of the VM.
            logger.error(
                "No hypervisor backend recorded for VM; rejecting operation", metadata: ["strato.vm.id": .string(vmId)])
            return nil
        }
        return getHypervisorService(for: entry.hypervisorType)
    }

    /// Persists managed + orphaned workloads (VMs and sandboxes) to the on-disk
    /// manifest so they can be detected as orphaned after an agent restart.
    /// Orphaned entries are carried over (active entries win on ID collision)
    /// so a second restart still knows about them.
    ///
    /// A write failure does not fail the operation that triggered it — the
    /// hypervisor-level change has already happened, so failing the response
    /// would diverge control-plane state from reality worse than a stale
    /// manifest does. Instead the failure is flagged and the write retried on
    /// every heartbeat (each write covers the full VM set, so one success
    /// heals all missed updates). The stale manifest only matters if the agent
    /// restarts before a retry succeeds.
    func persistManifest() {
        // Never write over a manifest we could not read (STR-138). The first
        // write after a failed load is what turns "unreadable, but the bytes
        // are still there" into an unrecoverable loss — and what it would
        // write is the empty in-memory set, i.e. a confident claim that this
        // host runs nothing. There is nothing worth persisting in that state
        // anyway: the agent converges nothing while quarantined.
        if let failure = manifestReadFailure {
            logger.warning(
                "Refusing to write the VM manifest: the existing file could not be read and must not be overwritten",
                metadata: [
                    "path": .string(failure.path),
                    "preservedCopy": .string(failure.preservedCopyPath ?? "none"),
                ])
            return
        }

        // One flat map for every workload kind; ids cannot collide across kinds
        // (both sides are UUIDs minted by the control plane), so the only real
        // collisions are orphaned-vs-active within a kind — active wins.
        var manifest = orphanedVMs.merging(managedVMs) { _, active in active }
        manifest.merge(orphanedSandboxes.merging(managedSandboxes) { _, active in active }) { _, sandbox in sandbox }
        // Quarantined entries are re-emitted exactly as they were read: their
        // routing field is what a build that understands them needs, and this
        // one rewriting it in a shape it prefers would destroy that.
        capacityManifestRevision &+= 1
        manifestPersistFailed = !manifestStore.save(manifest, preserving: quarantinedWorkloads)
    }

    /// Fold a manifest read into the agent's view of the host.
    ///
    /// The three outcomes are three different facts, and the whole point of
    /// STR-138 is that they stay that way: a fresh host has nothing on it, a
    /// loaded manifest names what a previous incarnation was running, and an
    /// unreadable one means the contents are unknown — which must never be
    /// spelled the same way as "empty".
    func applyManifestLoad(_ load: ManifestLoad) {
        switch load {
        case .fresh:
            manifestReadFailure = nil

        case .loaded(let entries, let quarantined):
            manifestReadFailure = nil
            quarantinedWorkloads = quarantined
            reserveVsockCIDs(entries: entries, quarantined: quarantined)
            // Anything already managed by *this* incarnation stays managed: a
            // recovery re-read must not demote live workloads to orphans.
            var recovered: [String] = []
            for (id, entry) in entries where managedVMs[id] == nil && managedSandboxes[id] == nil {
                if entry.kind == .sandbox {
                    orphanedSandboxes[id] = entry
                } else {
                    orphanedVMs[id] = entry
                }
                recovered.append(id)
            }
            if !recovered.isEmpty {
                logger.warning(
                    "Found \(recovered.count) workload(s) managed before restart; their processes are now unmanaged but their resources stay reserved",
                    metadata: ["workloadIds": .string(recovered.sorted().joined(separator: ","))])
            }

        case .unreadable(let failure):
            // The store has already logged this loudly and preserved a copy.
            manifestReadFailure = failure
        }
    }

    /// Re-claim every vsock CID the manifest records, so an agent that just
    /// started cannot hand a running VM's CID to a new one (STR-72).
    ///
    /// Quarantined entries are claimed too. This build cannot route them, but
    /// something is running under them, and a CID is exactly the kind of fact
    /// worth honoring from an entry that is otherwise unreadable — the whole
    /// reason the entry is kept is that its workload is still consuming host
    /// resources, and this is one of them.
    ///
    /// A conflict means the manifest itself lists one CID twice, which this
    /// agent cannot repair: both VMs may be running, and a running VM's CID is
    /// programmed into the host kernel, not into anything the agent can
    /// rewrite. It is logged at error and the loser keeps no allocation — the
    /// CID stays reserved by the winner either way, so nothing new can take it,
    /// and the duplicate stays in the manifest (and re-logs on every start)
    /// until that VM is re-created, which is what the message asks for.
    ///
    /// The reserving itself lives in `VsockCIDAllocator.reserveAll`, where it
    /// is unit-testable; this is only the reporting.
    func reserveVsockCIDs(
        entries: [String: VMManifestEntry], quarantined: [String: QuarantinedManifestEntry]
    ) {
        for refusal in vsockCIDs.reserveAll(entries: entries, quarantined: quarantined) {
            switch refusal.reason {
            case .conflict(let holder):
                logger.error(
                    "Two workloads in the VM manifest claim one vsock context ID; the later one keeps no allocation and must be re-created to get its own",
                    metadata: [
                        "vsockCID": .stringConvertible(refusal.cid),
                        "holder": .string(holder),
                        "workloadId": .string(refusal.workloadId),
                    ])
            case .notAssignable:
                logger.error(
                    "Ignoring an unusable vsock context ID in the VM manifest; the workload keeps no allocation",
                    metadata: [
                        "vsockCID": .stringConvertible(refusal.cid),
                        "workloadId": .string(refusal.workloadId),
                    ])
            case .reserved, .unchanged:
                continue  // not a refusal; `reserveAll` never reports these
            }
        }
    }

    /// Give back a vsock CID whose VM is gone from the manifest (STR-72).
    ///
    /// Called from every path that removes a VM's entry, including the ones
    /// that find it already absent: the manifest is what makes an allocation
    /// durable, so an allocation nothing in the manifest refers to is a leak
    /// and releasing it is always right.
    func releaseVsockCID(_ vmId: String) {
        guard let cid = vsockCIDs.release(vmId) else { return }
        logger.debug(
            "Released vsock context ID", metadata: ["strato.vm.id": .string(vmId), "vsockCID": .stringConvertible(cid)])
    }

    /// Re-read a manifest that was unreadable, so a transient cause — a
    /// storage volume that mounted late, an EIO, a permissions fix — clears
    /// the quarantine without an agent restart.
    ///
    /// Only a successful *read* clears it. A manifest that has since vanished
    /// reads as `.fresh`, and a missing file is not evidence of an empty host:
    /// somebody deleted it. Accepting that would hand every running guest's
    /// capacity straight back to the scheduler, so deciding this host is empty
    /// stays a deliberate act — restart the agent.
    func retryManifestLoadIfQuarantined() {
        guard manifestReadFailure != nil else { return }
        let load = manifestStore.load()
        guard case .loaded = load else { return }

        applyManifestLoad(load)
        logger.warning(
            "VM manifest became readable again; this host is no longer quarantined and will converge and advertise capacity normally"
        )
    }

    /// Self-update (issue #434): converge on the desired agent build carried by
    /// the sync — download, verify, swap, restart — gated on local
    /// preconditions. Since wire v28 this is the only update path there is: an
    /// operator's "update now" reaches the agent as this same field, assigned
    /// by the control plane rather than dispatched as a command, so the
    /// preconditions below hold for it too. Level-triggered: a blocked update
    /// is re-evaluated on every sync and the current reason is reported back on
    /// observed-state reports; a failed artifact is not retried within this
    /// process lifetime.
    func handleDesiredAgentUpdate(_ update: DesiredAgentUpdate?) async {
        guard let update else {
            // No opinion from the control plane (rollout not reached us,
            // auto-update off, or an older control plane). Clear any stale
            // status so a withdrawn rollout stops surfacing old reasons.
            autoUpdateStatus = nil
            return
        }
        guard !updateRestartPending else { return }
        guard update.targetVersion != BuildInfo.version else {
            // Already converged; the control plane's canonical comparison
            // normally stops the field before this, so this is a cheap no-op
            // guard against redundant syncs racing the restart.
            autoUpdateStatus = nil
            return
        }
        if attemptedAutoUpdateArtifacts.contains(update.sha256) {
            // Keep the failure status recorded at attempt time; the control
            // plane halts the rollout on it rather than waiting out silence.
            return
        }

        // Restarting mid-convergence is equally disruptive for either
        // workload kind, so the gate counts VM and sandbox items alike.
        var inFlightReconcileItems = 0
        if let reconciler {
            inFlightReconcileItems += await reconciler.inFlightWorkloads(kind: .vm).count
            inFlightReconcileItems += await reconciler.inFlightWorkloads(kind: .sandbox).count
        }
        let conditions = AutoUpdateGate.Conditions(
            installMode: installMode,
            inFlightReconcileItems: inFlightReconcileItems
        )
        if let reason = AutoUpdateGate.blockedReason(conditions) {
            let changed = autoUpdateStatus?.reason != reason
            autoUpdateStatus = ObservedAgentUpdateStatus(
                targetVersion: update.targetVersion,
                disposition: ObservedAgentUpdateStatus.dispositionBlocked,
                reason: reason
            )
            if changed {
                logger.notice(
                    "Desired agent update is blocked",
                    metadata: [
                        "targetVersion": .string(update.targetVersion),
                        "reason": .string(reason),
                    ])
                await sendObservedStateReport()
            }
            return
        }

        logger.notice(
            "Converging on desired agent update",
            metadata: [
                "targetVersion": .string(update.targetVersion),
                "currentVersion": .string(BuildInfo.version),
                // Redacted: the URL's query string may be a presigned credential.
                "artifactURL": .string(update.redactedArtifactURL),
            ])
        attemptedAutoUpdateArtifacts.insert(update.sha256)

        let outcome: AgentUpdateOutcome
        do {
            let updater = AgentUpdater(logger: logger, download: makeUpdateArtifactDownload())
            outcome = try await updater.applyUpdate(
                artifactURL: update.artifactURL,
                sha256: update.sha256,
                artifactKind: update.artifactKind,
                tarballMember: update.tarballMember
            )
        } catch {
            let reason = (error as? AgentUpdateError)?.description ?? "\(error)"
            logger.error(
                "Desired agent update failed",
                metadata: [
                    "targetVersion": .string(update.targetVersion),
                    "error": .string(reason),
                ])
            autoUpdateStatus = ObservedAgentUpdateStatus(
                targetVersion: update.targetVersion,
                disposition: ObservedAgentUpdateStatus.dispositionFailed,
                reason: reason
            )
            // Push the failure immediately so the rollout halts on the real
            // error instead of waiting out its health budget.
            await sendObservedStateReport()
            return
        }

        updateRestartPending = true
        autoUpdateStatus = nil
        // stop() from a separate task (this handler runs on the inbound
        // pipeline stop() tears down), then launchAgent exits with the restart
        // code for the supervisor. The new binary proves the update by
        // re-registering with its version.
        logger.notice(
            "Desired agent update applied; shutting down for supervisor restart",
            metadata: [
                "targetVersion": .string(update.targetVersion),
                "binaryPath": .string(outcome.binaryPath),
                "previousBinaryPath": .string(outcome.previousBinaryPath),
            ])
        Task {
            try? await Task.sleep(for: .seconds(1))
            await self.stop()
        }
    }

    // The agent sends no `success`/`error` frames at all since STR-152.
    // `sendSuccess` had already lost its last caller when the imperative verbs
    // converted, and `sendError`'s two remaining console call sites wrote into
    // a control plane with nothing to correlate against, so both were dropped
    // rather than left as protocol symmetry that delivers nothing. Console
    // failures route as `ConsoleDisconnectedMessage`, keyed by `sessionId`.

    /// Send a VM log message to the control plane for storage in Loki
    func sendVMLog(
        vmId: String,
        level: VMLogLevel,
        eventType: VMEventType,
        message: String,
        operation: String? = nil
    ) async {
        let logMessage = VMLogMessage(
            vmId: vmId,
            level: level,
            source: .agent,
            eventType: eventType,
            message: message,
            operation: operation
        )
        do {
            try await websocketClient?.sendMessage(logMessage)
        } catch {
            logger.error("Failed to send VM log: \(error)")
        }
    }

    // MARK: - Console Message Handlers

    /// Report a console that could not be opened.
    ///
    /// One frame, not two: this used to also send a correlated `ErrorMessage`,
    /// which never reached the browser — console connects are fire-and-forget,
    /// so the control plane had no pending request to match a `requestId`
    /// against and dropped it (and since STR-152 has no correlation at all).
    /// `ConsoleDisconnectedMessage` is a stream event keyed by `sessionId`,
    /// which does route, and is what stops the tab waiting on a console that is
    /// never going to open.
    func failConsoleConnect(_ message: ConsoleConnectMessage, reason: String) async {
        await sendConsoleDisconnected(vmId: message.vmId, sessionId: message.sessionId, reason: reason)
    }

    /// Tell the control plane a console session is over, and why, so it can
    /// close the browser's socket instead of leaving it attached to nothing.
    func sendConsoleDisconnected(vmId: String, sessionId: String, reason: String) async {
        do {
            try await websocketClient?.sendMessage(
                ConsoleDisconnectedMessage(vmId: vmId, sessionId: sessionId, reason: reason))
        } catch {
            logger.error("Failed to send console disconnected message: \(error)")
        }
    }

    func handleConsoleConnect(_ message: ConsoleConnectMessage) async {
        let stream = message.effectiveStream
        logger.info(
            "Console connect request received",
            metadata: [
                "strato.vm.id": .string(message.vmId),
                "strato.session.kind": .string("console"), "strato.session.id": .string(message.sessionId),
                "strato.request.id": .string(message.requestId),
                "stream": .string(stream.rawValue),
            ])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            logger.error(
                "Hypervisor service not available for console connect",
                metadata: ["strato.vm.id": .string(message.vmId)])
            await failConsoleConnect(message, reason: "Hypervisor service not available for VM")
            return
        }

        // Try serial socket first, then fall back to virtio-console if connect fails.
        logger.debug("Looking up console endpoint", metadata: ["strato.vm.id": .string(message.vmId)])
        let endpoint: ConsoleEndpoint?
        do {
            endpoint = try await service.consoleEndpoint(vmId: message.vmId)
        } catch {
            logger.error(
                "Console not available",
                metadata: [
                    "strato.vm.id": .string(message.vmId),
                    "error": .string(error.localizedDescription),
                ])
            await failConsoleConnect(
                message,
                reason: "Console not available for VM \(message.vmId): \(error.localizedDescription)")
            return
        }

        // The text console has two candidate sockets and tries them in order;
        // the graphics console has exactly one and no fallback, because serial
        // bytes are not an RFB stream — handing them to noVNC would hang its
        // handshake instead of reporting anything (issue #566).
        let candidatePaths: [String]
        switch stream {
        case .serial:
            candidatePaths = [endpoint?.serialSocketPath, endpoint?.consoleSocketPath].compactMap { $0 }
            guard !candidatePaths.isEmpty else {
                logger.error(
                    "No console socket found (tried serial and virtio-console)",
                    metadata: ["strato.vm.id": .string(message.vmId)])
                await failConsoleConnect(message, reason: "Console socket not found for VM \(message.vmId)")
                return
            }
        case .vnc:
            guard let vncPath = endpoint?.vncSocketPath else {
                logger.error("No VNC socket found", metadata: ["strato.vm.id": .string(message.vmId)])
                // The display device is fixed in the QEMU process's arguments,
                // so this is not something a restart fixes — say so rather than
                // leaving the operator to guess.
                await failConsoleConnect(
                    message,
                    reason: "VM \(message.vmId) has no graphics console: it was created without a display. "
                        + "Recreate the VM with the display enabled.")
                return
            }
            candidatePaths = [vncPath]
        }

        guard let consoleManager = consoleSocketManager else {
            logger.error("Console manager not available")
            await failConsoleConnect(message, reason: "Console manager not available")
            return
        }

        // Clean up existing sessions on *this* stream to prevent stale data
        // routing. Scoped by stream so opening the graphics console does not
        // tear down a serial session on the same VM, or the reverse.
        //
        // Not done for VNC at all: QEMU multiplexes RFB clients on one socket,
        // so two viewers of the same framebuffer is a supported case rather
        // than a stale one.
        if stream != .vnc {
            let existingSessions = await consoleManager.getSessionsForVM(vmId: message.vmId, stream: stream)
            if !existingSessions.isEmpty {
                logger.info(
                    "Cleaning up existing console sessions for VM",
                    metadata: [
                        "strato.vm.id": .string(message.vmId),
                        "stream": .string(stream.rawValue),
                        "sessionCount": .stringConvertible(existingSessions.count),
                    ])
                await consoleManager.disconnectAllForVM(vmId: message.vmId, stream: stream)
            }
        }

        var connectedPath: String?
        var lastError: Error?

        for candidatePath in candidatePaths {
            do {
                try await consoleManager.connect(
                    vmId: message.vmId, sessionId: message.sessionId, stream: stream, socketPath: candidatePath)
                connectedPath = candidatePath
                logger.debug(
                    "Connected to console socket",
                    metadata: ["stream": .string(stream.rawValue), "socketPath": .string(candidatePath)])
                break
            } catch {
                lastError = error
                logger.warning(
                    "Failed to connect to console socket",
                    metadata: [
                        "strato.vm.id": .string(message.vmId),
                        "strato.session.kind": .string("console"), "strato.session.id": .string(message.sessionId),
                        "socketPath": .string(candidatePath),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        guard connectedPath != nil else {
            let errorMessage = "Failed to connect to console: \(lastError?.localizedDescription ?? "unknown error")"
            await failConsoleConnect(message, reason: errorMessage)
            logger.error(
                "Failed to connect to console",
                metadata: [
                    "strato.vm.id": .string(message.vmId),
                    "strato.session.kind": .string("console"), "strato.session.id": .string(message.sessionId),
                    "error": .string(lastError?.localizedDescription ?? "unknown"),
                ])
            return
        }

        // Send connected confirmation
        let connectedMessage = ConsoleConnectedMessage(
            requestId: message.requestId,
            vmId: message.vmId,
            sessionId: message.sessionId
        )
        do {
            try await websocketClient?.sendMessage(connectedMessage)
        } catch {
            logger.error("Failed to send console connected message: \(error)")
        }

        logger.info(
            "Console connected",
            metadata: [
                "strato.vm.id": .string(message.vmId),
                "strato.session.kind": .string("console"),
                "strato.session.id": .string(message.sessionId),
                "socketPath": .string(connectedPath ?? "unknown"),
            ])
    }

    func handleConsoleDisconnect(_ message: ConsoleDisconnectMessage) async {
        logger.info(
            "Console disconnect request",
            metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
            ])

        guard let consoleManager = consoleSocketManager else {
            // No manager means no session to tear down, so the disconnect the
            // browser asked for has already happened. Confirm it on the stream
            // rather than on a correlated `error` nothing reads (STR-152) —
            // otherwise the tab waits out a socket that will never close.
            await sendConsoleDisconnected(
                vmId: message.vmId, sessionId: message.sessionId, reason: "Console manager not available")
            return
        }

        await consoleManager.disconnect(sessionId: message.sessionId)

        // Send disconnected confirmation
        let disconnectedMessage = ConsoleDisconnectedMessage(
            requestId: message.requestId,
            vmId: message.vmId,
            sessionId: message.sessionId,
            reason: "User requested disconnect"
        )
        do {
            try await websocketClient?.sendMessage(disconnectedMessage)
        } catch {
            logger.error("Failed to send disconnected message: \(error)")
        }

        logger.info(
            "Console disconnected",
            metadata: [
                "strato.vm.id": .string(message.vmId),
                "strato.session.kind": .string("console"), "strato.session.id": .string(message.sessionId),
            ])
    }

    func handleConsoleData(_ message: ConsoleDataMessage) async {
        // User input from frontend - write to console socket
        guard let consoleManager = consoleSocketManager else {
            logger.warning("Console manager not available for data write")
            return
        }

        guard let data = message.rawData else {
            logger.warning("Invalid console data received (failed to decode base64)")
            return
        }

        do {
            try await consoleManager.write(sessionId: message.sessionId, data: data)
        } catch {
            logger.error(
                "Failed to write to console",
                metadata: [
                    "strato.session.kind": .string("console"), "strato.session.id": .string(message.sessionId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    /// Called by ConsoleSocketManager when data arrives from VM console
    func sendConsoleData(vmId: String, sessionId: String, data: Data) async {
        let message = ConsoleDataMessage(
            vmId: vmId,
            sessionId: sessionId,
            rawData: data
        )
        do {
            try await websocketClient?.sendMessage(message)
        } catch {
            logger.error("Failed to send console data: \(error)")
        }
    }

    // MARK: - Guest Exec Message Handlers (STR-78)

    /// Start the pumps that drain the runtime's exec events and workload log
    /// lines into outbound WebSocket messages. Idempotent.
    func startSandboxPumps() {
        if sandboxExecPumpTask == nil {
            let events = sandboxExecEvents
            sandboxExecPumpTask = Task { [weak self] in
                for await (sessionId, kind, event) in events {
                    await self?.sendGuestExecEvent(
                        sessionId: sessionId, resourceKind: kind, event: event)
                }
            }
        }
        if sandboxLogPumpTask == nil {
            let lines = sandboxLogLines
            sandboxLogPumpTask = Task { [weak self] in
                for await (sandboxId, stream, line) in lines {
                    await self?.sendSandboxLogLine(sandboxId: sandboxId, stream: stream, line: line)
                }
            }
        }
    }

    // MARK: - Hypervisor lifecycle events (STR-135)

    /// Attach to every backend that pushes lifecycle transitions and start it.
    /// Idempotent.
    ///
    /// Routed through the driver registry rather than a downcast to
    /// `LibvirtService`, for the same reason `refreshGuestInfoCacheIfDue` is:
    /// which backend a VM runs under is not this loop's business. A backend
    /// with nothing to push (Firecracker, the mock, and every
    /// backend on macOS) reports nil and is skipped before a task is spawned or
    /// its subscription is ever started.
    func startLifecycleObservation() async {
        if observedStateTrigger == nil {
            observedStateTrigger = CoalescingTrigger(
                interval: CoalescingTrigger.observedStateInterval, logger: logger
            ) { [weak self] in
                await self?.sendObservedStateReport()
            }
        }
        for (type, service) in hypervisorServices {
            guard lifecyclePumpTasks[type] == nil, let changes = service.lifecycleChanges else { continue }

            // The slot is claimed *before* the first suspension, which is what
            // makes the idempotence above real rather than incidental: the
            // guard is read and written in one actor step, so two concurrent
            // callers cannot both pass it and attach two iterators to one
            // `AsyncStream`, which is single-consumer and would split the
            // events arbitrarily between them. `LibvirtService.connecting`
            // exists for the same reason one file over.
            //
            // Pumping before the subscription starts loses nothing: the stream
            // is created in the driver's `init` and buffered, so anything
            // yielded in the gap either way is held for whoever attaches.
            lifecyclePumpTasks[type] = Task { [weak self] in
                for await change in changes {
                    await self?.handleLifecycleChange(change, from: type)
                }
            }
            await service.startObservingLifecycle()
            logger.info(
                "Observing hypervisor lifecycle events",
                metadata: ["hypervisor": .string(type.rawValue)])
        }
    }

    /// Turn one pushed transition into a request for an observed-state report.
    ///
    /// The change itself is never applied to anything: the report the trigger
    /// schedules re-reads every VM, which is what `ObservedStateReport`'s
    /// full-list semantics require and what keeps events an accelerant rather
    /// than a second, racing source of truth.
    func handleLifecycleChange(_ change: VMLifecycleChange, from type: HypervisorType) async {
        // Before registration there is no agent id to send a report under,
        // and the post-registration baseline report covers whatever happened
        // in the meantime.
        guard assignedAgentID != nil else { return }

        // And not while the socket is down. `assignedAgentID` is set once at
        // registration and never cleared, so it does not answer this on its
        // own — without the second check a guest that flaps during a
        // control-plane outage would drive a full O(VMs) re-reading of the host
        // every coalescing window, for a report that can only throw
        // `notConnected`. Reconnection re-registers, and registration sends the
        // baseline report that covers the gap.
        guard await websocketClient?.isConnected == true else { return }

        switch change {
        case .vm(let id, let reason):
            logger.debug(
                "Hypervisor reported a VM lifecycle transition",
                metadata: [
                    "hypervisor": .string(type.rawValue),
                    "strato.vm.id": .string(id),
                    "event": .string(reason),
                ])
        case .resynchronize(let reason):
            logger.debug(
                "Hypervisor asked for a full re-reading",
                metadata: [
                    "hypervisor": .string(type.rawValue),
                    "reason": .string(reason),
                ])
        }
        await observedStateTrigger?.signal()
    }

    func handleGuestExecStart(_ message: GuestExecStartMessage) async {
        logger.info(
            "Guest exec start request received",
            metadata: [
                "resourceKind": .string(message.resourceKind.rawValue),
                LogMetadata.guestResourceIDKey(for: message.resourceKind): .string(
                    message.resourceId),
                "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(message.sessionId),
                "tty": .stringConvertible(message.tty),
            ])

        let request = SandboxExecRequest(
            command: message.command, env: message.env, workingDir: message.workingDir,
            tty: message.tty, rows: message.rows, cols: message.cols)

        guard guestExecSessionKinds[message.sessionId] == nil else {
            await sendGuestExecClosed(
                sessionId: message.sessionId, reason: "exec session already exists")
            return
        }

        // Register the route before starting. A guest can emit exec_started
        // immediately; pre-registration keeps a terminal event racing the
        // handshake from leaving a stale route behind.
        guestExecSessionKinds[message.sessionId] = message.resourceKind
        let continuation = sandboxExecEventsContinuation
        let sessionId = message.sessionId
        do {
            switch message.resourceKind {
            case .sandbox:
                guard let runtime = sandboxRuntime else {
                    throw SandboxRuntimeError.runtimeUnavailable
                }
                let sandboxId = message.resourceId
                try await runtime.startExec(
                    sandboxId: sandboxId, sessionId: sessionId, request: request
                ) { event in
                    continuation.yield((sessionId, .sandbox, event))
                }
            case .virtualMachine:
                // Resolve from `managedVMs`, never orphanedVMs. That local
                // placement check is the security boundary that keeps a
                // compromised control-plane replica from choosing an
                // arbitrary fleet CID on this host.
                let placement = try VMGuestExecPlacement.resolve(
                    vmId: message.resourceId, managedVMs: managedVMs)
                let vmId = message.resourceId
                let cid = placement.vsockCID
                try await vmExecSessionManager.startExec(
                    placement: placement, sessionId: sessionId, request: request,
                    placementIsCurrent: { [weak self] in
                        await self?.isCurrentVMExecPlacement(vmId: vmId, vsockCID: cid) == true
                    }
                ) { event in
                    continuation.yield((sessionId, .virtualMachine, event))
                }
            }
        } catch {
            guestExecSessionKinds.removeValue(forKey: sessionId)
            logger.error(
                "Failed to start guest exec session",
                metadata: [
                    "resourceKind": .string(message.resourceKind.rawValue),
                    LogMetadata.guestResourceIDKey(for: message.resourceKind): .string(
                        message.resourceId),
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "error": .string(error.localizedDescription),
                ])
            await sendGuestExecClosed(sessionId: sessionId, reason: error.localizedDescription)
        }
    }

    func isCurrentVMExecPlacement(vmId: String, vsockCID: UInt32) -> Bool {
        guard let current = try? VMGuestExecPlacement.resolve(vmId: vmId, managedVMs: managedVMs) else {
            return false
        }
        return current.vsockCID == vsockCID
    }

    func handleGuestExecInput(_ message: GuestExecInputMessage) async {
        if message.data != nil && message.rawData == nil {
            // The payload is present but not decodable base64: the stream is
            // corrupt, and forwarding nothing would silently swallow
            // keystrokes. Treat it as session-fatal, like the handler's other
            // failure paths: tear the session down and tell the control plane.
            logger.warning(
                "Invalid guest exec input received (failed to decode base64); closing session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(message.sessionId),
                ])
            await closeGuestExec(sessionId: message.sessionId)
            await sendGuestExecClosed(
                sessionId: message.sessionId, reason: "undecodable exec input (invalid base64)")
            return
        }
        do {
            switch guestExecSessionKinds[message.sessionId] {
            case .sandbox:
                guard let runtime = sandboxRuntime else { throw SandboxRuntimeError.runtimeUnavailable }
                try await runtime.sendExecInput(
                    sessionId: message.sessionId, data: message.rawData, eof: message.eof)
            case .virtualMachine:
                try await vmExecSessionManager.sendExecInput(
                    sessionId: message.sessionId, data: message.rawData, eof: message.eof)
            case nil:
                throw VMExecBridgeError.sessionNotFound(message.sessionId)
            }
        } catch {
            logger.warning(
                "Failed to write guest exec input",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(message.sessionId),
                    "error": .string(error.localizedDescription),
                ])
            await closeGuestExec(sessionId: message.sessionId)
            await sendGuestExecClosed(sessionId: message.sessionId, reason: error.localizedDescription)
        }
    }

    func handleGuestExecResize(_ message: GuestExecResizeMessage) async {
        do {
            switch guestExecSessionKinds[message.sessionId] {
            case .sandbox:
                guard let runtime = sandboxRuntime else { throw SandboxRuntimeError.runtimeUnavailable }
                try await runtime.resizeExec(
                    sessionId: message.sessionId, rows: message.rows, cols: message.cols)
            case .virtualMachine:
                try await vmExecSessionManager.resizeExec(
                    sessionId: message.sessionId, rows: message.rows, cols: message.cols)
            case nil:
                throw VMExecBridgeError.sessionNotFound(message.sessionId)
            }
        } catch {
            logger.warning(
                "Failed to resize guest exec session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(message.sessionId),
                    "error": .string(error.localizedDescription),
                ])
            await closeGuestExec(sessionId: message.sessionId)
            await sendGuestExecClosed(sessionId: message.sessionId, reason: error.localizedDescription)
        }
    }

    func handleGuestExecClose(_ message: GuestExecCloseMessage) async {
        logger.info(
            "Guest exec close request received",
            metadata: [
                "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(message.sessionId),
                "reason": .string(message.reason ?? ""),
            ])
        // The control plane already tore its side down; closing is terminal
        // and needs no reply. Guest-side, this kills the exec process group if
        // exec_exit has not arrived.
        await closeGuestExec(sessionId: message.sessionId)
    }

    func closeGuestExec(sessionId: String) async {
        switch guestExecSessionKinds.removeValue(forKey: sessionId) {
        case .sandbox:
            await sandboxRuntime?.closeExec(sessionId: sessionId)
        case .virtualMachine:
            await vmExecSessionManager.closeExec(sessionId: sessionId)
        case nil:
            return
        }
    }

    /// Translate one runtime exec event into its outbound message. Runs on the
    /// exec pump, so events are sent strictly in the order the runtime
    /// delivered them.
    func sendGuestExecEvent(
        sessionId: String, resourceKind: GuestResourceKind, event: SandboxExecEvent
    ) async {
        if case .exited = event {
            if guestExecSessionKinds[sessionId] == resourceKind {
                guestExecSessionKinds.removeValue(forKey: sessionId)
            }
        } else if case .closed = event, guestExecSessionKinds[sessionId] == resourceKind {
            guestExecSessionKinds.removeValue(forKey: sessionId)
        }
        guard let websocketClient else {
            // No control-plane socket: the event (possibly the session's
            // terminal one) is dropped. The control plane's agent-disconnect
            // cleanup handles the user-facing side; just make the drop
            // observable.
            logger.warning(
                "Dropping sandbox exec event: no control plane connection",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "event": .string(String(describing: event)),
                ])
            return
        }
        do {
            switch event {
            case .started:
                try await websocketClient.sendMessage(GuestExecStartedMessage(sessionId: sessionId))
            case .output(let stream, let data):
                try await websocketClient.sendMessage(
                    GuestExecOutputMessage(sessionId: sessionId, stream: stream, rawData: data))
            case .exited(let code):
                try await websocketClient.sendMessage(GuestExecExitMessage(sessionId: sessionId, exitCode: code))
            case .closed(let reason):
                try await websocketClient.sendMessage(GuestExecClosedMessage(sessionId: sessionId, reason: reason))
            }
        } catch {
            logger.error(
                "Failed to send guest exec message",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    func sendGuestExecClosed(sessionId: String, reason: String?) async {
        guard let websocketClient else {
            // Terminal for the session but undeliverable; see
            // `sendGuestExecEvent` for why a warning is enough.
            logger.warning(
                "Dropping guest exec closed message: no control plane connection",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "reason": .string(reason ?? ""),
                ])
            return
        }
        do {
            try await websocketClient.sendMessage(
                GuestExecClosedMessage(sessionId: sessionId, reason: reason))
        } catch {
            logger.error(
                "Failed to send guest exec closed message",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    /// Ship one assembled workload log line. Runs on the log pump, so lines
    /// arrive at the control plane in the order the guest emitted them.
    func sendSandboxLogLine(sandboxId: String, stream: String, line: String) async {
        let message = SandboxLogMessage(sandboxId: sandboxId, stream: stream, message: line)
        do {
            try await websocketClient?.sendMessage(message)
        } catch {
            logger.error(
                "Failed to send sandbox log line",
                metadata: ["strato.sandbox.id": .string(sandboxId), "error": .string(error.localizedDescription)])
        }
    }

    // MARK: - Volume frames (none remain)

    // `handleVolumeInfo` is gone with the `volume_info` frame (wire v32, ADR
    // 0001 stage 7, STR-149), and `handleVolumeSnapshot`/`...Delete` with the
    // two artifact verbs (v33, stage 8, STR-150). `StorageBackend.volumeInfo` remains, as the
    // agent's own probe behind `volumeVirtualSize` — the size cache the resize
    // planner reads. Nothing asks the agent to read a volume on the control
    // plane's behalf anymore.
}
