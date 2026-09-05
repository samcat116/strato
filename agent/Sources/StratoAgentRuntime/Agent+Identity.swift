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

/// Owns SPIFFE clients, registration, desired-state polling, and control-plane identity.
extension Agent {
    // MARK: - SPIFFE Helpers

    func createSPIFFEClient(config: SPIFFEConfig) throws -> any SPIFFEClientProtocol {
        let trustDomain = config.trustDomain ?? SPIFFEConfig.defaultTrustDomain
        let agentName = initialAgentID.replacingOccurrences(of: ".", with: "-")
        let spiffeID = SPIFFEIdentity(trustDomain: trustDomain, path: "/agent/\(agentName)")

        switch config.sourceType {
        case "files":
            guard let certPath = config.certificatePath,
                let keyPath = config.privateKeyPath,
                let bundlePath = config.trustBundlePath
            else {
                throw AgentError.spiffeConfigurationError(
                    "File-based SPIFFE requires certificate_path, private_key_path, and trust_bundle_path"
                )
            }

            logger.info(
                "Using file-based SPIFFE client",
                metadata: [
                    "certificatePath": .string(certPath),
                    "strato.agent.identity": .string(spiffeID.uri),
                ])

            return FileSPIFFEClient(
                certificatePath: certPath,
                privateKeyPath: keyPath,
                trustBundlePath: bundlePath,
                spiffeID: spiffeID,
                logger: logger
            )

        case "workload_api", nil:
            let socketPath = config.workloadAPISocketPath ?? SPIFFEConfig.defaultWorkloadAPISocketPath

            logger.info(
                "Using Workload API SPIFFE client",
                metadata: [
                    "socketPath": .string(socketPath),
                    "strato.agent.identity": .string(spiffeID.uri),
                ])

            return WorkloadAPISPIFFEClient(
                socketPath: socketPath,
                logger: logger
            )

        default:
            throw AgentError.spiffeConfigurationError(
                "Unknown SPIFFE source_type: \(config.sourceType ?? "nil"). Use 'files' or 'workload_api'"
            )
        }
    }

    /// Pinned control-plane identity built from the configured (or
    /// trust-domain-derived) control-plane SPIFFE ID and the roots the current
    /// SVID holds for *that identity's* trust domain — the SVID's own bundle
    /// in a single-domain deployment, its federated bundle for the platform
    /// domain once the agent lives in its org's domain (issue #600). Rebuilt
    /// on every rotation so rotated roots are picked up along with the SVID.
    func makeControlPlanePinning(spiffe: SPIFFEConfig) async throws -> SPIFFEPeerPinning {
        guard let svidManager else {
            throw AgentError.spiffeConfigurationError("SVID manager not initialized")
        }
        let svid = try await svidManager.getSVID()
        return try SPIFFEPeerPinning(
            expectedSPIFFEID: spiffe.resolvedControlPlaneSPIFFEID,
            svid: svid)
    }

    /// The current SVID-backed client TLS configuration, looked up fresh so
    /// rotated SVIDs are picked up without any re-wiring. Throws until the
    /// SVID manager has started.
    func currentSVIDTLSConfiguration() async throws -> TLSConfiguration {
        guard let svidManager else {
            throw AgentError.spiffeConfigurationError("no SVID is available yet for an mTLS download")
        }
        return try await svidManager.getTLSConfiguration()
    }

    /// Downloader for control-plane artifacts (images, typed artifacts,
    /// control-plane-hosted update binaries), authenticating with the agent's
    /// SVID over mTLS.
    func makeMTLSArtifactDownloader() -> MTLSArtifactDownloader {
        MTLSArtifactDownloader(
            tlsConfigurationProvider: { [weak self] in
                guard let self else {
                    throw AgentError.spiffeConfigurationError("agent is shutting down")
                }
                return try await self.currentSVIDTLSConfiguration()
            },
            logger: logger
        )
    }

    /// Downloader for agent-update artifacts: URLs targeting the control
    /// plane's origin fetch over SVID mTLS (they sit behind the Envoy mTLS
    /// listener, issue #493); everything else — GitHub release URLs, `file://`
    /// overrides on air-gapped hosts — keeps the stock path.
    func makeUpdateArtifactDownload() -> AgentUpdater.Downloader {
        let mtlsDownloader = makeMTLSArtifactDownloader()
        let base = controlPlaneHTTPBase
        return { url, destination in
            if MTLSArtifactDownloader.targetsOrigin(url, of: base) {
                try await mtlsDownloader.downloadArtifact(url: url, to: destination)
            } else {
                try await AgentUpdater.defaultDownload(from: url, to: destination)
            }
        }
    }

    func handleSVIDRotation() async {
        logger.info("SVID rotated, updating WebSocket TLS configuration")

        do {
            guard let spiffe = spiffeConfig else {
                // Unreachable while SPIFFE is mandatory at startup; log rather
                // than return silently so a future refactor that loosens that
                // shows up as a rotation that stopped happening.
                logger.error("SVID rotated but no SPIFFE configuration is present; pinning not updated")
                return
            }
            let newTLSConfig = try await svidManager?.getTLSConfiguration()
            let newPinning = try await makeControlPlanePinning(spiffe: spiffe)
            if let client = websocketClient {
                await client.updateTLSConfiguration(newTLSConfig, spiffePinning: newPinning)
            }
            logger.info("WebSocket TLS configuration updated after SVID rotation")
        } catch {
            logger.error("Failed to update TLS configuration after SVID rotation: \(error)")
        }
    }

    func registerWithControlPlane() async throws {
        let resources = await getAgentResources()

        // A network service that failed to connect earlier may be fixable by
        // now (OVS installed, ovn-controller restarted); retry once before
        // computing the networking report so a fixed host reports overlay
        // support on reconnect instead of only after a restart.
        if networkService != nil, !networkServiceConnected {
            networkServiceConnected = await connectNetworkService()
        }

        // Probe on every registration (initial and reconnect) so the control
        // plane sees the host as it is now, not as it was at process start —
        // e.g. Firecracker installed or /dev/kvm permissions fixed since then.
        // The host preflight (storage directories, qemu-img, firmware,
        // OVN/OVS dependencies) runs on the same cadence and gates the
        // per-hypervisor probes: a host that cannot store VM disks must not
        // advertise any hypervisor, whatever the binary probes say.
        //
        // Simulation mode bypasses the probes and preflight entirely: there is
        // no real hypervisor to detect, so it advertises the mock backends as
        // available+accelerated to make the agent placement-eligible.
        let hypervisors: [HypervisorSupport]
        // Whether this host can back a guest TPM 2.0 (issue #565). Simulation
        // mode asserts it for the same reason it asserts the sandbox runtime:
        // the host fact it checks for is meaningless to a mock backend, and
        // withholding it would make simulated fleets unusable for scale-testing
        // Windows-shaped placement.
        var hostPreflightReport: HostPreflight.Report? = nil
        var tpmAvailable = isSimulationMode
        if isSimulationMode {
            hypervisors = Agent.simulatedHypervisorSupport()
        } else {
            // One `virsh` call answers reachability and version together; the
            // vTPM question is a second one, and it is only worth asking of a
            // daemon that answered the first. Skipping it on a broken host
            // saves a subprocess per reconnect and, more importantly, keeps the
            // preflight from printing an "install swtpm" remedy underneath the
            // gating "libvirt is not usable" one.
            let libvirt = await probeLibvirt()
            let preflight = runHostPreflight(
                libvirt: libvirt, tpmSupport: await probeTPMSupport(libvirt: libvirt))
            hostPreflightReport = preflight
            tpmAvailable = preflight.tpmAvailable
            logHostPreflight(preflight)
            // The domain builder refuses a `<tpm>` element this host cannot
            // back, and this is the only place that fact is known — it comes
            // from libvirt, on the same cadence as every other probe, so a host
            // that gains swtpm advertises it on the next reconnect rather than
            // after a restart.
            await libvirtService?.setTPMSupported(tpmAvailable)
            let probed = preflight.gate(
                HypervisorProbe.probeAll(
                    libvirt: libvirt, firecrackerBinaryPath: firecrackerBinaryPath))
            // Firecracker's binary version rides the registration (issue
            // #428): snapshot mobility keys cross-agent restore placement on
            // version equality, so the control plane needs to know what each
            // host would load snapshots with.
            let versioned = HypervisorProbe.stampingFirecrackerVersion(
                probed,
                version: await HypervisorProbe.firecrackerVersion(binaryPath: firecrackerBinaryPath))
            hypervisors = versioned.map { support in
                guard support.type == .qemu else { return support }
                return HypervisorSupport(
                    type: support.type,
                    available: support.available,
                    accelerated: support.accelerated,
                    unavailabilityReason: support.unavailabilityReason,
                    supportsSnapshots: support.supportsSnapshots,
                    supportsVsock: preflight.vhostVsockAvailable,
                    supportsGuestExec: preflight.vhostVsockAvailable,
                    supportsVolumeIOLimits: true,
                    version: support.version
                )
            }
        }

        // The identity range gates only jailed sandboxes, never trusted
        // Firecracker VMs. Refresh on every registration so fixing the host's
        // passwd/group/subordinate-id reservations recovers capability without
        // restarting the agent.
        if sandboxJailerMode == .required {
            sandboxJailerUIDRangeBlockedReason =
                hostPreflightReport?.sandboxJailerUIDRangeFailureDetail
        } else {
            sandboxJailerUIDRangeBlockedReason = nil
        }
        await sandboxRuntime?.updateJailerBlockedReason(sandboxJailCreationBlockedReason)
        let networkCapability = currentNetworkCapability()

        // Sandbox runtime: probed on the same cadence, gated on Firecracker
        // (binary + KVM, folded into its probe) plus the guest base image
        // present on disk. The typed flag is what the scheduler keys sandbox
        // placement and snapshot admission on (issue #415).
        //
        // Simulation mode bypasses the host probe, mirroring the hypervisor
        // bypass above: the host artifacts it checks for (a real Firecracker,
        // the guest base image on disk) are meaningless for the mock runtime
        // (issue #470). The "never advertise what we cannot serve" invariant
        // holds either way, because capability additionally requires this
        // agent to actually hold a runtime that will serve the workload —
        // the host probe alone is necessary but not sufficient.
        let sandboxProbe: SandboxRuntimeProbe.Report
        if isSimulationMode {
            // Networking included, on the same terms as the simulated overlay
            // report above: a simulated agent exists to model a full
            // Linux host to the *scheduler*, and withholding this would quietly
            // remove networked sandboxes from everything simulation covers
            // (placement, assembly, reconciliation). Nothing is realized —
            // `sandboxNICPlacement` short-circuits to the host namespace and the
            // orchestrator is a no-op — so the promise of "no real side effects"
            // holds.
            sandboxProbe = SandboxRuntimeProbe.Report(capable: true, networkingUnavailabilityReason: nil)
        } else {
            sandboxProbe = SandboxRuntimeProbe.probe(
                firecracker: hypervisors.first { $0.type == .firecracker },
                guestImagePath: sandboxGuestImagePath,
                jailerBlockedReason: sandboxJailCreationBlockedReason,
                jailsNewSandboxes: sandboxJailNewSandboxes,
                networkCapability: networkCapability
            )
        }
        let sandboxCapable = sandboxProbe.capable && sandboxRuntime != nil
        // Sandbox networking (STR-103) is a second, strictly stronger signal on
        // the same probe: OVN, the jailer, and a guest image that brings the
        // interface up. Reported separately because the control plane needs
        // both answers — it places NIC-less sandboxes on a host with only the
        // first, and withholds `SandboxSpec.network` from it.
        let sandboxNetworkingCapable = sandboxCapable && sandboxProbe.networkingCapable
        if !sandboxCapable && !isSimulationMode {
            #if os(Linux)
            // Only worth a log where the runtime could ever exist.
            let reason = sandboxProbe.unavailabilityReason ?? "sandbox runtime was not initialized"
            logger.info(
                "Sandbox runtime unavailable; not advertising sandbox capability",
                metadata: [
                    "reason": .string(reason)
                ])
            #endif
        }

        // Logged at warning, unlike the capability above: a host that runs no
        // sandboxes at all is an ordinary configuration, but one that runs them
        // and cannot network them will silently attract only NIC-less
        // placements, which is the kind of half-working state an operator
        // should be told about rather than have to infer from a scheduler
        // refusal elsewhere in the fleet.
        if !sandboxNetworkingCapable, sandboxCapable,
            let reason = sandboxProbe.networkingUnavailabilityReason
        {
            logger.warning(
                "This host runs sandboxes but cannot give them a NIC; not advertising sandbox networking",
                metadata: [
                    "reason": .string(reason)
                ])
        }

        // Refresh after every registration-time recovery attempt and host
        // probe. The capability report and dependency snapshot must describe
        // the same host state in this registration message.
        let dependencyObservations: [NodeDependencyObservation]
        if let dependencyManager {
            dependencyObservations = await dependencyManager.refresh()
        } else {
            dependencyObservations = []
        }

        let message = AgentRegisterMessage(
            agentId: initialAgentID,
            hostname: ProcessInfo.processInfo.hostName,
            version: BuildInfo.version,
            resources: resources,
            architecture: CPUArchitecture.current,
            hypervisors: hypervisors,
            networkCapability: networkCapability,
            sandboxCapable: sandboxCapable,
            sandboxNetworkingCapable: sandboxNetworkingCapable,
            tpmCapable: tpmAvailable,
            operatingSystem: OperatingSystem.current,
            hostInfo: HostInfoProbe.gather(),
            // Speaking wire v37 is not the same as being able to answer on the
            // resolver address, so this is reported separately — the
            // `sandboxCapable`/`tpmCapable` shape. The control plane folds it
            // across the whole site before enabling any network's resolver,
            // because the DHCP option that points guests at it is authored once
            // per network while the listener is per chassis.
            resolverCapable: resolverBinaryPath != nil,
            // `startMetadataService` sets the supervisor only after the
            // service is enabled and the host passes its Linux, OVN, and `ip`
            // tool gates. Reporting the initialized supervisor rather than the
            // config bit makes every failure path ineligible by default.
            metadataServiceCapable: metadataServers != nil,
            dependencyObservations: dependencyObservations
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Registration message sent to control plane, waiting for response...")

        // Wait for registration response with timeout
        let assignedId = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            self.armRegistrationWait(continuation)
        }

        self.assignedAgentID = assignedId
        logger.info("Registration complete, assigned ID: \(assignedId)")

        await replayRecordedExecSessionsAfterRegistration()

        // Give the control plane a fresh baseline right away — it will also
        // serve us its desired state on the first poll, and the two together
        // converge any drift accumulated while disconnected.
        _ = await storageDeviceInventory.refreshForRegistration()
        await sendObservedStateReport()

    }

    /// Parks the given continuation as the pending registration wait and arms a
    /// 30s timeout bound to *this* attempt. Each attempt gets its own generation
    /// so a timeout from a superseded attempt can't fail a newer one, and the
    /// timeout task is tracked so resolving the registration cancels it instead of
    /// leaving it to fire (and leak) later.
    func armRegistrationWait(_ continuation: CheckedContinuation<String, Error>) {
        // A prior attempt's continuation may still be parked — e.g. a reconnect
        // fired before the last attempt resolved. Fail it now (cancelling its
        // timeout) so it neither leaks its awaiter nor lets a stale timeout fire.
        if let stale = takeRegistrationContinuation() {
            stale.resume(throwing: AgentError.registrationSuperseded)
        }

        registrationGeneration &+= 1
        let generation = registrationGeneration
        registrationContinuation = continuation
        guard !reconnectState.connectionWasLostDuringStartup else {
            takeRegistrationContinuation()?.resume(
                throwing: AgentError.registrationFailed(
                    "control-plane connection closed during registration"))
            return
        }
        registrationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.failRegistrationOnTimeout(generation: generation)
        }
    }

    /// Fails the registration attempt identified by `generation`, but only if it
    /// is still the current one — a timeout inherited from a superseded attempt is
    /// ignored.
    func failRegistrationOnTimeout(generation: UInt64) {
        guard generation == registrationGeneration else { return }
        guard let continuation = takeRegistrationContinuation() else { return }
        continuation.resume(throwing: AgentError.registrationTimeout)
    }

    /// Clears the pending registration continuation and cancels its bound timeout,
    /// returning the continuation so the caller can resume it exactly once. Returns
    /// nil when no registration is currently pending.
    func takeRegistrationContinuation() -> CheckedContinuation<String, Error>? {
        guard let continuation = registrationContinuation else { return nil }
        registrationContinuation = nil
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        return continuation
    }

    /// Handle registration response from control plane
    func handleRegistrationResponse(_ response: AgentRegisterResponseMessage) async {
        let controlPlaneProtocolVersion = response.protocolVersion
        guard controlPlaneProtocolVersion == WireProtocol.currentVersion else {
            let reason =
                "Control plane wire protocol version \(controlPlaneProtocolVersion) does not equal this agent's "
                + "required version \(WireProtocol.currentVersion). Deploy matching control-plane and agent builds."
            logger.error("Registration rejected: \(reason)")
            if let continuation = takeRegistrationContinuation() {
                continuation.resume(throwing: AgentError.registrationRejected(reason))
            }
            return
        }

        await startDesiredStatePoller()

        guard let continuation = takeRegistrationContinuation() else {
            logger.warning("Received registration response but no continuation waiting")
            return
        }
        continuation.resume(returning: response.agentId)
    }

    /// Start the desired-state long-poll loop — the only sync transport since
    /// v38 (STR-146 introduced it; the pushed transport went with the skew
    /// window). Called from every registration response, initial and
    /// reconnect; `DesiredStatePoller.start()` is idempotent, so a reconnect
    /// keeps the existing loop and its ETag rather than restarting from a full
    /// fetch.
    func startDesiredStatePoller() async {
        guard desiredStatePoller == nil else {
            await desiredStatePoller?.start()
            return
        }

        guard let url = URL(string: controlPlaneHTTPBase + Self.desiredStatePollPath) else {
            logger.error(
                "Could not build the desired-state poll URL; desired-state sync cannot start",
                metadata: ["base": .string(controlPlaneHTTPBase)])
            return
        }

        // The downloader is built per poller rather than per request, but it
        // still resolves the TLS configuration on every call, so a rotated SVID
        // is picked up by the next poll without restarting anything.
        let downloader = MTLSArtifactDownloader(
            tlsConfigurationProvider: { [weak self] in
                guard let self else {
                    throw AgentError.spiffeConfigurationError("agent is shutting down")
                }
                return try await self.currentSVIDTLSConfiguration()
            },
            logger: logger,
            timeouts: .longPoll
        )

        let poller = DesiredStatePoller(
            fetch: { ifNoneMatch in
                try await downloader.poll(url: url, ifNoneMatch: ifNoneMatch)
            },
            deliver: { [weak self] envelope in
                // Straight onto the ordinary inbound path so the fetched sync
                // lands on the `.desiredState` serialization lane and inherits
                // the ordering guarantees the reconciler relies on.
                await self?.routeInboundMessage(envelope)
            },
            logger: logger,
            fullRefetchInterval: desiredStateFullRefetchInterval
        )
        desiredStatePoller = poller
        await poller.start()
        logger.info(
            "Desired state is now fetched by long-poll",
            metadata: [
                "url": .string(url.absoluteString),
                "fullRefetchSeconds": .stringConvertible(desiredStateFullRefetchInterval.components.seconds),
            ])
    }

    /// The control-plane path serving the desired-state long-poll. Under
    /// `/agent/` because that is the prefix Envoy routes with no timeout.
    static var desiredStatePollPath: String { "/agent/desired-state" }

    /// Handle an `error` envelope from the control plane.
    ///
    /// Previously these fell through to the `default` case and were logged as
    /// "unknown message type: error", discarding the real reason (e.g. an
    /// unrecognized agent identity). Now the reason is surfaced.
    ///
    /// If registration is still pending — we're waiting on `registrationContinuation`
    /// — the control plane has rejected this connection (it sends such errors with an
    /// empty `requestId` and closes the socket). Fail the registration with the real
    /// reason instead of letting it time out after 30s; the caller (initial start or
    /// the reconnect loop) then surfaces it and retries as appropriate.
    func handleErrorResponse(_ message: ErrorMessage) async {
        let detailSuffix = message.details.map { " (\($0))" } ?? ""

        if let continuation = takeRegistrationContinuation() {
            logger.error("Registration failed: \(message.error)\(detailSuffix)")
            // Only an explicit terminal code — a credential rejection, or a
            // protocol version the control plane refuses to drive — should
            // stop the reconnect loop; retrying either can never succeed
            // without operator action. Anything else, including envelopes
            // from control planes that predate the code field, is treated as
            // transient so the reconnect loop keeps backing off instead of
            // exiting.
            if message.code == ErrorMessage.ErrorCode.invalidToken
                || message.code == ErrorMessage.ErrorCode.unsupportedProtocolVersion
            {
                continuation.resume(throwing: AgentError.registrationRejected(message.error))
            } else {
                continuation.resume(throwing: AgentError.registrationFailed(message.error))
            }
            return
        }

        logger.error(
            "Control plane reported an error: \(message.error)\(detailSuffix)",
            metadata: [
                "strato.request.id": .string(message.requestId)
            ])
    }

    /// The networking capability to report at registration, reflecting the
    /// backend selected at startup rather than the platform: a Linux agent
    /// configured for user-mode networking cannot provide OVN/VM-to-VM
    /// networking, and the scheduler relies on this to enforce the
    /// inter-VM-networking placement constraint.
    func currentNetworkCapability() -> NetworkCapability? {
        switch (effectiveNetworkMode, networkServiceConnected) {
        case (.ovn, true):
            return .overlay
        case (.ovn, false):
            // OVN was selected but the OVN/OVS connection failed at startup:
            // report no networking capability rather than claiming VM-to-VM
            // support the backend cannot currently provide (and user-mode
            // would be a lie — the agent is not running SLIRP either).
            logger.warning("OVN network service not connected; reporting no overlay networking support")
            return nil
        case (.user, _):
            // User-mode (SLIRP) networking is built into QEMU and needs no
            // external service, so it is not gated on connection state.
            return .userMode
        }
    }

    func unregisterFromControlPlane() async throws {
        let message = AgentUnregisterMessage(agentId: effectiveAgentID)

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Unregistration message sent to control plane")
    }

    /// The hypervisor support to advertise in simulation mode: the mock
    /// backends this agent actually registered, reported as available and
    /// hardware-accelerated so the scheduler can place workloads whose behavior
    /// the mock faithfully simulates. Per-volume I/O limits are deliberately not
    /// advertised: the mock has no live domain, so hot-attached limits cannot be
    /// applied or observed consistently.
    ///
    /// Derived from `HypervisorType.allCases`, exactly like the mock registration
    /// in `start()`, so the two cannot drift apart and a new backend is simulated
    /// the moment it has an enum case.
    static func simulatedHypervisorSupport() -> [HypervisorSupport] {
        HypervisorType.allCases.map { type in
            HypervisorSupport(
                type: type,
                available: true,
                accelerated: true,
                supportsVsock: type == .qemu ? true : nil
            )
        }
    }
}
