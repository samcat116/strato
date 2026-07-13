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
    private(set) public var vmState: InstanceState = .notStarted

    /// Creates a new FirecrackerManager
    /// - Parameters:
    ///   - socketPath: Path to the Firecracker API Unix socket
    ///   - logger: Logger instance for debug output
    public init(socketPath: String, logger: Logger = Logger(label: "SwiftFirecracker.Manager")) {
        self.socketPath = socketPath
        self.httpClient = UnixSocketHTTPClient(socketPath: socketPath, logger: logger)
        self.logger = logger
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Connection Management

    /// Connects to the Firecracker API socket
    public func connect() async throws {
        try await httpClient.connect()
    }

    /// Disconnects from the Firecracker API socket
    public func disconnect() async {
        await httpClient.disconnect()
    }

    // MARK: - Machine Configuration

    /// Configures the machine (vCPUs, memory)
    /// Must be called before starting the VM
    public func configureMachine(_ config: MachineConfig) async throws {
        let body = try encoder.encode(config)
        let response = try await httpClient.request(method: .PUT, path: "/machine-config", body: body)
        try handleResponse(response)
        logger.info("Machine configured", metadata: [
            "vcpus": "\(config.vcpuCount)",
            "memory_mib": "\(config.memSizeMib)"
        ])
    }

    /// Gets the current machine configuration
    public func getMachineConfig() async throws -> MachineConfigResponse {
        let response = try await httpClient.request(method: .GET, path: "/machine-config")
        try handleResponse(response)
        guard let body = response.body else {
            throw FirecrackerError.deserializationError("Empty response body")
        }
        return try decoder.decode(MachineConfigResponse.self, from: body)
    }

    // MARK: - Boot Configuration

    /// Configures the boot source (kernel and initramfs)
    /// Must be called before starting the VM
    public func configureBootSource(_ bootSource: BootSource) async throws {
        let body = try encoder.encode(bootSource)
        let response = try await httpClient.request(method: .PUT, path: "/boot-source", body: body)
        try handleResponse(response)
        logger.info("Boot source configured", metadata: [
            "kernel": "\(bootSource.kernelImagePath)"
        ])
    }

    // MARK: - Drive Management

    /// Adds or updates a drive
    public func configureDrive(_ drive: Drive) async throws {
        let body = try encoder.encode(drive)
        let response = try await httpClient.request(method: .PUT, path: "/drives/\(drive.driveId)", body: body)
        try handleResponse(response)
        logger.info("Drive configured", metadata: [
            "drive_id": "\(drive.driveId)",
            "path": "\(drive.pathOnHost)",
            "is_root": "\(drive.isRootDevice)"
        ])
    }

    // MARK: - Network Configuration

    /// Adds or updates a network interface
    public func configureNetwork(_ networkInterface: NetworkInterface) async throws {
        let body = try encoder.encode(networkInterface)
        let response = try await httpClient.request(method: .PUT, path: "/network-interfaces/\(networkInterface.ifaceId)", body: body)
        try handleResponse(response)
        logger.info("Network interface configured", metadata: [
            "iface_id": "\(networkInterface.ifaceId)",
            "host_dev": "\(networkInterface.hostDevName)"
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
        logger.info("Vsock configured", metadata: [
            "guest_cid": "\(vsock.guestCid)",
            "uds_path": "\(vsock.udsPath)"
        ])
    }

    // MARK: - MMDS (Metadata Service)

    /// Configures the microVM metadata service (version, allowed network
    /// interfaces, endpoint address). Must be called before starting the VM.
    public func configureMMDS(_ config: MMDSConfig) async throws {
        let body = try encoder.encode(config)
        let response = try await httpClient.request(method: .PUT, path: "/mmds/config", body: body)
        try handleResponse(response)
        logger.info("MMDS configured", metadata: [
            "interfaces": "\(config.networkInterfaces.joined(separator: ","))",
            "version": "\(config.version ?? "default")"
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
        guard vmState == .notStarted else {
            throw FirecrackerError.vmAlreadyRunning("VM is already in state: \(vmState)")
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
        guard vmState == .running else {
            throw FirecrackerError.invalidState(current: vmState.rawValue, expected: InstanceState.running.rawValue)
        }

        let stateChange = VMStateChange(state: .paused)
        let body = try encoder.encode(stateChange)
        let response = try await httpClient.request(method: .PATCH, path: "/vm", body: body)
        try handleResponse(response)

        vmState = .paused
        logger.info("VM paused")
    }

    /// Resumes a paused VM
    public func resume() async throws {
        guard vmState == .paused else {
            throw FirecrackerError.invalidState(current: vmState.rawValue, expected: InstanceState.paused.rawValue)
        }

        let stateChange = VMStateChange(state: .resumed)
        let body = try encoder.encode(stateChange)
        let response = try await httpClient.request(method: .PATCH, path: "/vm", body: body)
        try handleResponse(response)

        vmState = .running
        logger.info("VM resumed")
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

    /// Gets the current instance information
    public func getInstanceInfo() async throws -> InstanceInfo {
        let response = try await httpClient.request(method: .GET, path: "/")
        try handleResponse(response)
        guard let body = response.body else {
            throw FirecrackerError.deserializationError("Empty response body")
        }
        let info = try decoder.decode(InstanceInfo.self, from: body)
        vmState = info.state
        return info
    }

    // MARK: - Helper Methods

    /// Handles HTTP response and throws on error
    private func handleResponse(_ response: HTTPResponse) throws {
        guard response.isSuccess else {
            var message = "HTTP \(response.statusCode)"
            if let body = response.body,
               let errorResponse = try? decoder.decode(FirecrackerAPIError.self, from: body) {
                message = errorResponse.faultMessage
            } else if let body = response.body,
                      let bodyString = String(data: body, encoding: .utf8) {
                message = bodyString
            }
            throw FirecrackerError.httpError(statusCode: response.statusCode, message: message)
        }
    }
}

// MARK: - Convenience Methods

extension FirecrackerManager {
    /// Creates and starts a VM with the given configuration
    /// This is a convenience method that combines all configuration steps
    public func createAndStart(
        machineConfig: MachineConfig,
        bootSource: BootSource,
        rootDrive: Drive,
        networkInterface: NetworkInterface? = nil,
        vsock: VsockConfig? = nil
    ) async throws {
        // Configure machine
        try await configureMachine(machineConfig)

        // Configure boot source
        try await configureBootSource(bootSource)

        // Configure root drive
        try await configureDrive(rootDrive)

        // Configure network if provided
        if let network = networkInterface {
            try await configureNetwork(network)
        }

        // Configure vsock if provided (host↔guest control channel)
        if let vsock {
            try await configureVsock(vsock)
        }

        // Start the VM
        try await start()
    }
}
