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

// MARK: - Instance metadata service (STR-56)

extension Agent {

    /// Push the current generation-guarded metadata into each managed
    /// Firecracker VMM named by this desired-state payload. VMs omitted from a
    /// partial sync retain their last snapshot, matching `MetadataStore`'s
    /// blast-radius contract; newly created VMs are seeded in `createVM` and
    /// adopted VMs are refreshed by `adoptVM`.
    func refreshFirecrackerMetadata(for desired: [DesiredVMState]) async {
        guard let service = hypervisorServices[.firecracker] else { return }
        for vm in desired where vm.hypervisorType == .firecracker {
            let vmId = vm.vmId.uuidString
            guard managedVMs[vmId]?.hypervisorType == .firecracker else { continue }
            await refreshFirecrackerMetadata(vmId: vmId, using: service)
        }
    }

    func refreshFirecrackerMetadata(
        vmId: String, using service: any HypervisorService
    ) async {
        guard let id = UUID(uuidString: vmId) else { return }
        let metadata = metadataServiceEnabled ? await metadataStore.metadata(for: id) : nil
        do {
            try await service.refreshInstanceMetadata(vmId: vmId, metadata: metadata)
        } catch {
            // A snapshot refresh is retried on every sync and must not prevent
            // the VM lifecycle reconciler from making progress.
            logger.warning(
                "Unable to refresh Firecracker MMDS snapshot",
                metadata: [
                    "vmId": .string(vmId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    /// Bring up the guest-facing metadata service.
    ///
    /// Restoring the durable copy comes first and unconditionally — before the
    /// supervisor, and even when this host will serve nothing. A restored store
    /// is what lets a listener answer during a control-plane outage that spans
    /// an agent restart, and the restore is also what turns a listener's "I know
    /// nothing" 503 into an honest 404 for an address this host really does not
    /// serve.
    func startMetadataService() async {
        switch metadataSnapshotStore.load() {
        case .records(let records):
            await metadataStore.restore(records)
            logger.info(
                "Restored instance metadata from the previous run",
                metadata: ["instances": .stringConvertible(records.count)])
        case .unknown:
            // No file, or one this build could not read. Either way this host
            // knows nothing until the first sync, and its listeners will say so
            // rather than guess.
            break
        }

        // Debounced, because a sync applies one record per VM and the durable
        // copy only has to reflect the sync as a whole.
        metadataPersistTrigger = CoalescingTrigger(
            interval: .seconds(2), logger: logger,
            action: { [weak self] in await self?.persistInstanceMetadata() })

        guard metadataServiceEnabled else {
            logger.info("Instance metadata service disabled by configuration")
            return
        }
        #if os(Linux)
        // OVN only: the namespaces the listeners bind in are created by the OVN
        // chassis path, and user-mode networking has no localport to terminate.
        // macOS reaches its guests through SLIRP `guestfwd` instead (STR-61).
        guard effectiveNetworkMode == .ovn else {
            logger.info("Instance metadata service needs OVN networking; not starting it")
            return
        }
        let isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ipBinaryPath = SandboxJailerResolver.resolveIPBinaryPath(isExecutable: isExecutable) else {
            logger.warning(
                """
                Instance metadata service needs the iproute2 `ip` tool to enter each network's namespace, \
                and it was not found; guests on this host will not be able to read their metadata
                """,
                metadata: ["searched": .string(SandboxJailerResolver.ipBinaryCandidates.joined(separator: ", "))])
            return
        }
        let spawner = MetadataServerProcessSpawner(
            ipBinaryPath: ipBinaryPath, logLevel: logger.logLevel.rawValue,
            hopLimit: metadataHopLimit,
            identityMinter: GuestIdentityMinter { [weak self] vmId, audience, ttlSeconds in
                guard let self else { throw GuestIdentityMintingError.unavailable }
                return try await self.mintGuestIdentity(
                    vmId: vmId, audience: audience, ttlSeconds: ttlSeconds)
            },
            logger: logger)
        metadataServers = MetadataServerSupervisor(spawner: spawner, logger: logger)

        // Start serving before the first sync, from the namespaces this host
        // already has. Without this the durable copy above would be pointless:
        // its whole purpose is to keep answering across a control-plane outage
        // that spans an agent restart, and until a sync arrives there would be
        // no listener process to answer with — guests would get connection
        // refused rather than stale-but-honest metadata, and `.restored` would
        // be a state nothing could ever observe.
        //
        // The namespaces are the right source because they are host state that
        // outlives the agent: the chassis reconcile created them and only a host
        // reboot clears the tmpfs they live on. A network removed while this
        // agent was down leaves a stale namespace and so starts a listener that
        // is not wanted; the first sync stops it, which is the level-triggered
        // correction this whole path is built on.
        let existing = spawner.existingNamespaces()
        guard !existing.isEmpty else { return }
        logger.info(
            "Starting metadata listeners for namespaces that survived the agent",
            metadata: ["networks": .stringConvertible(existing.count)])
        await reconcileMetadataServers(networks: existing)
        #endif
    }

    /// Converge the listener fleet and hand each one its network's current
    /// servable set.
    ///
    /// `networks` nil ≙ a control plane that predates the field: no listener is
    /// started or stopped, matching what the chassis reconcile does with the
    /// same value. The store is still persisted, since a sync that says nothing
    /// about metadata ports may still have carried metadata.
    func reconcileMetadataServers(networks: [UUID]) async {
        await metadataPersistTrigger?.signal()

        guard let metadataServers else { return }
        let origin = await metadataStore.origin()
        let servable = await metadataStore.snapshot()
        await metadataServers.reconcile(desired: networks) { networkId in
            // One network's slice. Built here rather than in the listener so a
            // child only ever holds the instances it may serve — a listener
            // cannot leak what it was never given.
            MetadataSnapshot(
                networkId: networkId, origin: origin,
                instances: servable.values.filter { instance in
                    instance.nics.contains { $0.networkId == networkId }
                }.sorted { $0.instanceId.uuidString < $1.instanceId.uuidString })
        }
    }

    /// Write the durable copy. Coalesced by `metadataPersistTrigger`.
    ///
    /// The encode and the write happen off the actor. `userData` rides inline
    /// per instance, so this file is megabytes on a busy host, and a synchronous
    /// write on the actor would stall every message the agent is handling for
    /// as long as the disk takes. Debouncing bounds how often that happens, not
    /// how long it lasts.
    func persistInstanceMetadata() async {
        let records = await metadataStore.exportRecords()
        let store = metadataSnapshotStore
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                store.save(records)
                continuation.resume()
            }
        }
    }

    func mintGuestIdentity(
        vmId: UUID, audience: String, ttlSeconds: Int
    ) async throws -> GuestJWTSVIDResponse {
        guard let metadata = await metadataStore.metadata(for: vmId),
            metadata.isServiceEnabled,
            let policy = metadata.identity,
            !policy.audiences.isEmpty,
            policy.audiences.contains(audience),
            ttlSeconds > 0,
            ttlSeconds <= min(900, policy.ttlSeconds ?? 300)
        else {
            throw GuestIdentityMintingError.unavailable
        }
        return try await makeMTLSArtifactDownloader().mintGuestIdentity(
            controlPlaneBaseURL: controlPlaneHTTPBase,
            vmId: vmId,
            audience: audience,
            ttlSeconds: ttlSeconds)
    }
}
