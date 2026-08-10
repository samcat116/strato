import Foundation
import Logging

/// High-level manager for Firecracker microVM lifecycle operations
/// Provides a simple interface for creating, configuring, and managing microVMs
public actor FirecrackerManager {
    private let socketPath: String
    private let httpClient: UnixSocketHTTPClient
    private let logger: Logger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Current state of the VM
    private var vmState: InstanceState = .notStarted

    /// Creates a new FirecrackerManager
    /// - Parameters:
    ///   - socketPath: Path to the Firecracker API Unix socket
    ///   - logger: Logger instance for debug output
    ///   - requestTimeout: Ceiling on one API round trip. The default is sized
    ///     for the calls that wait on the vCPUs; reads that do not take
    ///     ``UnixSocketHTTPClient/defaultReadTimeout`` per call instead.
    init(
        socketPath: String,
        logger: Logger = Logger(label: "SwiftFirecracker.Manager"),
        requestTimeout: TimeInterval = UnixSocketHTTPClient.defaultRequestTimeout
    ) {
        self.socketPath = socketPath
        self.httpClient = UnixSocketHTTPClient(
            socketPath: socketPath, logger: logger, requestTimeout: requestTimeout)
        self.logger = logger
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Connection Management

    /// Connects to the Firecracker API socket
    func connect() async throws {
        try await httpClient.connect()
    }

    /// Disconnects from the Firecracker API socket
    func disconnect() async {
        await httpClient.disconnect()
    }

    // MARK: - Machine Configuration

    /// Configures the machine (vCPUs, memory)
    /// Must be called before starting the VM
    public func configureMachine(_ config: MachineConfig) async throws {
        let body = try encoder.encode(config)
        let response = try await httpClient.request(method: .PUT, path: "/machine-config", body: body)
        try handleResponse(response)
        logger.info(
            "Machine configured",
            metadata: [
                "vcpus": "\(config.vcpuCount)",
                "memory_mib": "\(config.memSizeMib)",
            ])
    }

    // MARK: - Boot Configuration

    /// Configures the boot source (kernel and initramfs)
    /// Must be called before starting the VM
    public func configureBootSource(_ bootSource: BootSource) async throws {
        let body = try encoder.encode(bootSource)
        let response = try await httpClient.request(method: .PUT, path: "/boot-source", body: body)
        try handleResponse(response)
        logger.info(
            "Boot source configured",
            metadata: [
                "kernel": "\(bootSource.kernelImagePath)"
            ])
    }

    // MARK: - Drive Management

    /// Adds or updates a drive
    public func configureDrive(_ drive: Drive) async throws {
        let body = try encoder.encode(drive)
        let response = try await httpClient.request(method: .PUT, path: "/drives/\(drive.driveId)", body: body)
        try handleResponse(response)
        logger.info(
            "Drive configured",
            metadata: [
                "drive_id": "\(drive.driveId)",
                "path": "\(drive.pathOnHost)",
                "is_root": "\(drive.isRootDevice)",
            ])
    }

    // MARK: - Network Configuration

    /// Adds or updates a network interface
    public func configureNetwork(_ networkInterface: NetworkInterface) async throws {
        let body = try encoder.encode(networkInterface)
        let response = try await httpClient.request(
            method: .PUT, path: "/network-interfaces/\(networkInterface.ifaceId)", body: body)
        try handleResponse(response)
        logger.info(
            "Network interface configured",
            metadata: [
                "iface_id": "\(networkInterface.ifaceId)",
                "host_dev": "\(networkInterface.hostDevName)",
            ])
    }

    // MARK: - Vsock Configuration

    /// Configures the virtio-vsock device (host↔guest control channel).
    /// Must be called before starting the VM.
    ///
    /// After boot, reach a guest-listening port through the configured UDS with
    /// ``VsockConnection/connect(udsPath:port:timeout:retryInterval:logger:)``.
    public func configureVsock(_ vsock: VsockConfig) async throws {
        let body = try encoder.encode(vsock)
        let response = try await httpClient.request(method: .PUT, path: "/vsock", body: body)
        try handleResponse(response)
        logger.info(
            "Vsock configured",
            metadata: [
                "guest_cid": "\(vsock.guestCid)",
                "uds_path": "\(vsock.udsPath)",
            ])
    }

    // MARK: - Entropy Device

    /// Attaches a virtio-rng entropy device (`PUT /entropy`) so the guest can
    /// reseed its RNG — required for clone safety when a snapshot is restored
    /// more than once. Must be called before starting the VM; requires
    /// Firecracker >= 1.3.
    public func configureEntropy() async throws {
        let body = Data("{}".utf8)
        let response = try await httpClient.request(method: .PUT, path: "/entropy", body: body)
        try handleResponse(response)
        logger.info("Entropy device configured")
    }

    // MARK: - MMDS (Metadata Service)

    /// Configures the microVM metadata service (version, allowed network
    /// interfaces, endpoint address). Must be called before starting the VM.
    public func configureMMDS(_ config: MMDSConfig) async throws {
        let body = try encoder.encode(config)
        let response = try await httpClient.request(method: .PUT, path: "/mmds/config", body: body)
        try handleResponse(response)
        logger.info(
            "MMDS configured",
            metadata: [
                "interfaces": "\(config.networkInterfaces.joined(separator: ","))",
                "version": "\(config.version ?? "default")",
            ])
    }

    /// Replaces the MMDS metadata store with the given JSON-encodable value.
    /// The guest reads this back over the MMDS HTTP endpoint.
    public func setMMDSData<T: Encodable>(_ data: T) async throws {
        let body = try encoder.encode(data)
        try await putMMDSData(body)
    }

    /// Replaces the MMDS metadata store with a pre-encoded JSON payload.
    /// - Throws: ``FirecrackerError/serializationError`` if `json` is not valid JSON.
    public func setMMDSData(rawJSON json: Data) async throws {
        guard (try? JSONSerialization.jsonObject(with: json)) != nil else {
            throw FirecrackerError.serializationError("MMDS data store payload is not valid JSON")
        }
        try await putMMDSData(json)
    }

    private func putMMDSData(_ body: Data) async throws {
        let response = try await httpClient.request(method: .PUT, path: "/mmds", body: body)
        try handleResponse(response)
        logger.info("MMDS data store updated", metadata: ["bytes": "\(body.count)"])
    }

    // MARK: - VM Lifecycle

    /// Starts the VM
    /// All configuration (machine, boot, drives) must be set before calling this
    public func start() async throws {
        if vmState != .notStarted {
            // `vmState` is a local mirror, not the truth: a VM that crashed,
            // rebooted, or was driven out of band leaves it stale. Confirm
            // against the VMM before refusing.
            await refreshState()
            guard vmState == .notStarted else {
                throw FirecrackerError.vmAlreadyRunning("VM is already in state: \(vmState)")
            }
        }

        let action = VMAction(actionType: .instanceStart)
        let body = try encoder.encode(action)
        let response = try await httpClient.request(method: .PUT, path: "/actions", body: body)
        try handleResponse(response)

        vmState = .running
        logger.info("VM started")
    }

    /// Pauses the VM
    public func pause() async throws {
        try await requireState(.running)

        let stateChange = VMStateChange(state: .paused)
        let body = try encoder.encode(stateChange)
        let response = try await httpClient.request(method: .PATCH, path: "/vm", body: body)
        try handleResponse(response)

        vmState = .paused
        logger.info("VM paused")
    }

    /// Resumes a paused VM
    public func resume() async throws {
        try await requireState(.paused)

        try await sendResume()
    }

    /// Sends `Resumed` without trusting Firecracker's instance-level state.
    ///
    /// This is only for recovery after `pause()` failed. Firecracker broadcasts
    /// `Pause` to every vCPU before collecting their acknowledgements, but it
    /// changes `GET /` from `Running` to `Paused` only after *all* of them
    /// acknowledge. A timeout can therefore leave some vCPUs paused while the
    /// only observable state remains `Running`; the guarded ``resume()`` would
    /// refuse to send the command that unwinds that partial pause.
    ///
    /// `Resumed` is idempotent at the vCPU state machine: a running vCPU
    /// acknowledges it and keeps running, while a paused one resumes. Callers
    /// must not use this as an ordinary lifecycle operation because it
    /// deliberately bypasses the manager's state precondition.
    public func recoverFromFailedPause() async throws {
        try await sendResume()
    }

    private func sendResume() async throws {
        let stateChange = VMStateChange(state: .resumed)
        let body = try encoder.encode(stateChange)
        let response = try await httpClient.request(method: .PATCH, path: "/vm", body: body)
        try handleResponse(response)

        vmState = .running
        logger.info("VM resumed")
    }

    // MARK: - Snapshots

    /// Creates a snapshot of the guest memory + VMM state (`PUT /snapshot/create`).
    /// The VM must be paused; disk contents are NOT captured — copy the drive
    /// files while the VM is still paused for a consistent checkpoint.
    public func createSnapshot(_ config: SnapshotCreateConfig) async throws {
        try await requireState(.paused)

        let body = try encoder.encode(config)
        let response = try await httpClient.request(method: .PUT, path: "/snapshot/create", body: body)
        try handleResponse(response)
        logger.info(
            "Snapshot created",
            metadata: [
                "vmstate": "\(config.snapshotPath)",
                "memory": "\(config.memFilePath)",
                "type": "Full",
            ])
    }

    /// Loads a snapshot into a freshly spawned, entirely unconfigured VM
    /// (`PUT /snapshot/load`). The snapshot carries the full device topology,
    /// so none of the usual configuration calls precede this; drive files must
    /// exist at the paths recorded in the vmstate. Leaves the VM paused unless
    /// `config.resumeVM` is true.
    func loadSnapshot(_ config: SnapshotLoadConfig) async throws {
        try await requireState(.notStarted)

        let body = try encoder.encode(config)
        let response = try await httpClient.request(method: .PUT, path: "/snapshot/load", body: body)
        try handleResponse(response)

        vmState = (config.resumeVM ?? false) ? .running : .paused
        logger.info(
            "Snapshot loaded",
            metadata: [
                "vmstate": "\(config.snapshotPath)",
                "resumed": "\(config.resumeVM ?? false)",
            ])
    }

    /// Sends Ctrl+Alt+Del to the VM (triggers reboot if configured)
    public func sendCtrlAltDel() async throws {
        let action = VMAction(actionType: .sendCtrlAltDel)
        let body = try encoder.encode(action)
        let response = try await httpClient.request(method: .PUT, path: "/actions", body: body)
        try handleResponse(response)
        logger.info("Sent Ctrl+Alt+Del to VM")
    }

    // MARK: - Instance Information

    /// Gets the current instance information.
    ///
    /// Bounded by the short read budget rather than the client's default: the
    /// VMM answers this from its own event loop without asking the vCPUs
    /// anything, and callers pair it with an action in the same convergence
    /// step (`shutdownSandbox` is `getInstanceInfo` then `pause`), where the two
    /// ceilings add up against one mutation deadline.
    public func getInstanceInfo() async throws -> InstanceInfo {
        let response = try await httpClient.request(
            method: .GET, path: "/", timeout: UnixSocketHTTPClient.defaultReadTimeout)
        try handleResponse(response)
        guard let body = response.body else {
            throw FirecrackerError.deserializationError("Empty response body")
        }
        let info = try decoder.decode(InstanceInfo.self, from: body)
        vmState = info.state
        return info
    }

    // MARK: - Helper Methods

    /// Re-reads the VM's state from the VMM, refreshing the local mirror.
    ///
    /// Best effort: a failure here means the guard that called it falls back to
    /// the cached value, which is no worse than not having asked.
    private func refreshState() async {
        _ = try? await getInstanceInfo()
    }

    /// Confirms the VM is in `expected`, re-reading from the VMM first if the
    /// cached mirror disagrees, so a stale cache cannot produce a spurious
    /// `invalidState`.
    private func requireState(_ expected: InstanceState) async throws {
        if vmState == expected { return }
        await refreshState()
        guard vmState == expected else {
            throw FirecrackerError.invalidState(
                current: vmState.rawValue, expected: expected.rawValue)
        }
    }

    /// Handles HTTP response and throws on error
    private func handleResponse(_ response: HTTPResponse) throws {
        guard response.isSuccess else {
            var message = "HTTP \(response.statusCode)"
            if let body = response.body,
                let errorResponse = try? decoder.decode(FirecrackerAPIError.self, from: body)
            {
                message = errorResponse.faultMessage
            } else if let body = response.body,
                let bodyString = String(data: body, encoding: .utf8)
            {
                message = bodyString
            }
            throw FirecrackerError.httpError(statusCode: response.statusCode, message: message)
        }
    }
}
