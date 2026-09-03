import Foundation
import Configuration
import Logging
import StratoShared
import Toml
import TomlConfiguration

extension AgentConfig {
    private static let knownSettingPaths: Set<[String]> = [
        ["control_plane_url"],
        ["log_level"],
        ["network_mode"],
        ["ovn_encap_ip"],
        ["ovn_encap_type"],
        ["ovn_remote"],
        ["ovn_bootstrap_chassis"],
        ["ovn_northbound"],
        ["ovn_northbound_tls", "ca_cert"],
        ["ovn_northbound_tls", "client_cert"],
        ["ovn_northbound_tls", "client_key"],
        ["ovn_northbound_tls", "verify_server_certificate"],
        ["ovn_northbound_tls", "server_hostname"],
        ["enable_hvf"],
        ["enable_kvm"],
        ["qemu_memory_overhead_mb"],
        ["vm_storage_dir"],
        ["volume_storage_dir"],
        ["image_cache_dir"],
        ["image_cache_max_size_gb"],
        ["sandbox_image_cache_dir"],
        ["sandbox_image_cache_max_size_gb"],
        ["firmware_path_arm64"],
        ["firmware_path_x86_64"],
        ["firmware_code_path"],
        ["firmware_vars_template"],
        ["secure_boot_firmware_code_path"],
        ["secure_boot_firmware_vars_template"],
        ["firecracker_binary_path"],
        ["firecracker_socket_dir"],
        ["sandbox_guest_image_path"],
        ["sandbox_jailer_mode"],
        ["sandbox_jailer_binary_path"],
        ["sandbox_jailer_chroot_dir"],
        ["sandbox_jailer_uid_base"],
        ["sandbox_warm_start"],
        ["sandbox_warm_cache_max_size_gb"],
        ["hypervisor_type"],
        ["spiffe", "enabled"],
        ["spiffe", "trust_domain"],
        ["spiffe", "workload_api_socket_path"],
        ["spiffe", "source_type"],
        ["spiffe", "certificate_path"],
        ["spiffe", "private_key_path"],
        ["spiffe", "trust_bundle_path"],
        ["spiffe", "control_plane_spiffe_id"],
        ["ovn_uplink", "external_cidr"],
        ["ovn_uplink", "gateway"],
        ["ovn_uplink", "bridge"],
        ["ovn_uplink", "physnet"],
        ["ovn_uplink", "external_cidr6"],
        ["ovn_uplink", "gateway6"],
        ["ovn_dynamic_routing", "enabled"],
        ["ovn_dynamic_routing", "redistribute"],
        ["ovn_dynamic_routing", "vrf_name"],
        ["ovn_dynamic_routing", "maintain_vrf"],
        ["ovn_dynamic_routing", "routing_protocols"],
        ["resolver", "enabled"],
        ["resolver", "coredns_binary_path"],
        ["resolver", "config_dir"],
        ["resolver", "rate_limit_pps"],
        ["simulation", "enabled"],
        ["simulation", "cpu_cores"],
        ["simulation", "memory_mb"],
        ["simulation", "disk_gb"],
        ["simulation", "sandbox_log_interval_ms"],
        ["simulation", "sandbox_exit_after_seconds"],
        ["reconcile_teardown_minimum"],
        ["reconcile_teardown_percent"],
        ["allow_bulk_teardown"],
        ["desired_state_full_refetch_seconds"],
        ["metadata_service"],
        ["metadata_response_hop_limit"],
    ]

    private static let knownTablePaths: Set<[String]> = [
        ["ovn_northbound_tls"],
        ["spiffe"],
        ["ovn_uplink"],
        ["ovn_dynamic_routing"],
        ["resolver"],
        ["simulation"],
    ]

    /// Loads the agent configuration from process environment variables layered
    /// over a TOML file. Swift Configuration queries providers in order, so an
    /// environment value always wins over the matching file value.
    public static func load(
        from path: String,
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger? = nil
    ) async throws -> AgentConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AgentConfigError.configFileNotFound(path)
        }

        let fileURL = URL(fileURLWithPath: path)
        let tomlString = try String(contentsOf: fileURL, encoding: .utf8)
        let tomlData = try Toml(withString: tomlString)
        try validateKnownSettings(tomlData)

        let tomlProvider = try await TOMLProvider(filePath: .init(path))
        let reader = ConfigReader(providers: [
            EnvironmentVariablesProvider(environmentVariables: environmentVariables),
            tomlProvider,
        ])
        return try await load(from: reader, logger: logger)
    }

    static func load(from reader: ConfigReader, logger: Logger?) async throws -> AgentConfig {
        let values = AgentConfigReader(reader)
        guard let controlPlaneURL = try await values.string("control_plane_url") else {
            throw AgentConfigError.missingRequiredField("control_plane_url")
        }

        let logLevel: AgentLogLevel?
        if let configuredLogLevel = try await values.string("log_level") {
            do {
                logLevel = try AgentLogLevel(parsing: configuredLogLevel)
            } catch {
                throw AgentConfigError.invalidConfiguration(error.localizedDescription)
            }
        } else {
            logLevel = nil
        }
        let networkModeString = try await values.string("network_mode")
        let ovnEncapIP = try await values.string("ovn_encap_ip")
        let ovnEncapType = try await values.string("ovn_encap_type")
        let ovnRemote = try await values.string("ovn_remote")
        let ovnBootstrapChassis = try await values.bool("ovn_bootstrap_chassis")
        let ovnNorthbound = try await values.string("ovn_northbound")
        if let ovnNorthbound {
            let validSchemes = ["unix:", "tcp:", "ssl:"]
            guard validSchemes.contains(where: ovnNorthbound.hasPrefix) else {
                throw AgentConfigError.invalidConfiguration(
                    "ovn_northbound must be an OVN connection string (unix:<path>, tcp:<host>:<port>, or ssl:<host>:<port>), got '\(ovnNorthbound)'"
                )
            }
        }
        // A section is present when any recognized value is present. This also
        // lets environment-only nested settings materialize a section.
        let tlsValues = values.scoped(to: "ovn_northbound_tls")
        let tlsCACert = try await tlsValues.string("ca_cert")
        let tlsClientCert = try await tlsValues.string("client_cert")
        let tlsClientKey = try await tlsValues.string("client_key")
        let tlsVerifyServer = try await tlsValues.bool("verify_server_certificate")
        let tlsServerHostname = try await tlsValues.string("server_hostname")
        let hasTLSConfig =
            tlsCACert != nil || tlsClientCert != nil || tlsClientKey != nil
            || tlsVerifyServer != nil || tlsServerHostname != nil
        let ovnNorthboundTLS: OVNNorthboundTLSConfig?
        if hasTLSConfig {
            guard let ovnNorthbound, ovnNorthbound.hasPrefix("ssl:") else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_northbound_tls] requires ovn_northbound to be an ssl:<host>:<port> endpoint, "
                        + "got '\(ovnNorthbound ?? "(unset)")'"
                )
            }
            guard (tlsClientCert == nil) == (tlsClientKey == nil) else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_northbound_tls] client_cert and client_key must be set together"
                )
            }
            ovnNorthboundTLS = OVNNorthboundTLSConfig(
                caCertPath: tlsCACert,
                clientCertPath: tlsClientCert,
                clientKeyPath: tlsClientKey,
                verifyServerCertificate: tlsVerifyServer ?? true,
                serverHostname: tlsServerHostname
            )
        } else {
            ovnNorthboundTLS = nil
        }
        let enableHVF = try await values.bool("enable_hvf")
        let enableKVM = try await values.bool("enable_kvm")
        let qemuMemoryOverheadMB = try await values.int("qemu_memory_overhead_mb")
        if let qemuMemoryOverheadMB, !Self.qemuMemoryOverheadRange.contains(qemuMemoryOverheadMB) {
            throw AgentConfigError.invalidConfiguration(
                "qemu_memory_overhead_mb must be between 128 and 4096, got \(qemuMemoryOverheadMB)")
        }
        let vmStoragePath = try await values.string("vm_storage_dir")
        let volumeStoragePath = try await values.string("volume_storage_dir")
        let imageCacheDir = try await values.string("image_cache_dir")
        let sandboxImageCacheDir = try await values.string("sandbox_image_cache_dir")
        // Cache budgets must be positive: 0 would mean "evict everything, every
        // time" — an operator who wants no cache bound should omit the key.
        let imageCacheMaxSizeGB = try await Self.positiveInt(values, key: "image_cache_max_size_gb")
        let sandboxImageCacheMaxSizeGB = try await Self.positiveInt(
            values, key: "sandbox_image_cache_max_size_gb")
        let firmwarePathARM64 = try await values.string("firmware_path_arm64")
        let firmwarePathX86_64 = try await values.string("firmware_path_x86_64")
        // Split EDK2 firmware (issue #565). CODE and VARS only mean anything as
        // a pair — a lone code path with no variable store is the `-bios` setup
        // the pair exists to replace — so a half-configured pair is rejected
        // rather than silently ignored.
        let firmwareCodePath = try await values.string("firmware_code_path")
        let firmwareVarsTemplate = try await values.string("firmware_vars_template")
        guard (firmwareCodePath == nil) == (firmwareVarsTemplate == nil) else {
            throw AgentConfigError.invalidConfiguration(
                "firmware_code_path and firmware_vars_template must be set together")
        }
        let secureBootFirmwareCodePath = try await values.string("secure_boot_firmware_code_path")
        let secureBootFirmwareVarsTemplate = try await values.string("secure_boot_firmware_vars_template")
        guard (secureBootFirmwareCodePath == nil) == (secureBootFirmwareVarsTemplate == nil) else {
            throw AgentConfigError.invalidConfiguration(
                "secure_boot_firmware_code_path and secure_boot_firmware_vars_template must be set together")
        }
        let firecrackerBinaryPath = try await values.string("firecracker_binary_path")
        let firecrackerSocketDir = try await values.string("firecracker_socket_dir")
        let sandboxGuestImagePath = try await values.string("sandbox_guest_image_path")
        let hypervisorTypeString = try await values.string("hypervisor_type")

        // Sandbox jailer settings (issue #425). The mode is strictly decoded —
        // a typo like "required" silently falling back to auto would quietly
        // weaken a host an operator believed hardened.
        let sandboxJailerMode: SandboxJailerMode?
        if let modeString = try await values.string("sandbox_jailer_mode") {
            guard let mode = SandboxJailerMode(rawValue: modeString) else {
                throw AgentConfigError.invalidConfiguration(
                    "sandbox_jailer_mode must be 'auto', 'required', or 'disabled', got '\(modeString)'")
            }
            sandboxJailerMode = mode
        } else {
            sandboxJailerMode = nil
        }
        let sandboxJailerBinaryPath = try await values.string("sandbox_jailer_binary_path")
        let sandboxJailerChrootDir = try await values.string("sandbox_jailer_chroot_dir")
        let sandboxJailerUidBase: UInt32?
        if let uidBase = try await values.int("sandbox_jailer_uid_base") {
            guard uidBase >= Int(Self.minimumSandboxJailerUidBase),
                uidBase <= Int(SandboxJailerConfig.maximumUIDBase)
            else {
                throw AgentConfigError.invalidConfiguration(
                    "sandbox_jailer_uid_base must be at least \(Self.minimumSandboxJailerUidBase) with room for a \(SandboxJailerConfig.uidCount)-id range, got \(uidBase)"
                )
            }
            sandboxJailerUidBase = UInt32(uidBase)
        } else {
            sandboxJailerUidBase = nil
        }

        // Warm start (issue #426).
        let sandboxWarmStart = try await values.bool("sandbox_warm_start")
        let sandboxWarmCacheMaxSizeGB = try await Self.positiveInt(
            values, key: "sandbox_warm_cache_max_size_gb")

        // Teardown blast-radius guard (STR-98). Zero is meaningful for both
        // numbers — "allow no teardown without the override", and "any batch
        // past the floor is refused" — so neither goes through `positiveInt`;
        // a negative value is clamped to 0 by `TeardownGuard`.
        let reconcileTeardownMinimum = try await values.int("reconcile_teardown_minimum")
        let reconcileTeardownPercent = try await values.int("reconcile_teardown_percent")
        let allowBulkTeardown = try await values.bool("allow_bulk_teardown")

        // Desired-state transport (STR-146).
        let desiredStateFullRefetchSeconds = try await values.int("desired_state_full_refetch_seconds")
        let metadataService = try await values.bool("metadata_service")
        let metadataResponseHopLimit = try await values.int("metadata_response_hop_limit")
        if let metadataResponseHopLimit, !(1...255).contains(metadataResponseHopLimit) {
            // A hop limit outside the IP field's range is a mistake, and
            // silently substituting a working value hides it until someone
            // wonders why the setting did nothing.
            throw AgentConfigError.invalidConfiguration(
                "metadata_response_hop_limit must be between 1 and 255, got \(metadataResponseHopLimit)")
        }

        // Validate and parse network mode
        let networkMode: NetworkMode?
        if let modeString = networkModeString {
            guard let mode = NetworkMode(rawValue: modeString) else {
                throw AgentConfigError.invalidConfiguration("network_mode must be 'ovn' or 'user', got '\(modeString)'")
            }
            networkMode = mode
        } else {
            networkMode = nil
        }

        // Validate and parse hypervisor type
        let hypervisorType: HypervisorType?
        if let typeString = hypervisorTypeString {
            guard let hType = HypervisorType(rawValue: typeString) else {
                throw AgentConfigError.invalidConfiguration(
                    "hypervisor_type must be 'qemu' or 'firecracker', got '\(typeString)'")
            }
            hypervisorType = hType
            logger?.info("Agent configured to use hypervisor type: \(typeString)")
        } else {
            hypervisorType = nil
        }

        // Parse SPIFFE configuration from its scoped provider view.
        let spiffeValues = values.scoped(to: "spiffe")
        let spiffeEnabled = try await spiffeValues.bool("enabled")
        let trustDomain = try await spiffeValues.string("trust_domain")
        let workloadAPISocketPath = try await spiffeValues.string("workload_api_socket_path")
        let sourceType = try await spiffeValues.string("source_type")
        let certificatePath = try await spiffeValues.string("certificate_path")
        let privateKeyPath = try await spiffeValues.string("private_key_path")
        let trustBundlePath = try await spiffeValues.string("trust_bundle_path")
        let controlPlaneSPIFFEID = try await spiffeValues.string("control_plane_spiffe_id")
        let hasSPIFFEConfig =
            spiffeEnabled != nil || trustDomain != nil || workloadAPISocketPath != nil
            || sourceType != nil || certificatePath != nil || privateKeyPath != nil
            || trustBundlePath != nil || controlPlaneSPIFFEID != nil
        let spiffeConfig: SPIFFEConfig?
        if hasSPIFFEConfig {
            let parsedSPIFFEConfig = SPIFFEConfig(
                enabled: spiffeEnabled ?? false,
                trustDomain: trustDomain,
                workloadAPISocketPath: workloadAPISocketPath,
                sourceType: sourceType,
                certificatePath: certificatePath,
                privateKeyPath: privateKeyPath,
                trustBundlePath: trustBundlePath,
                controlPlaneSPIFFEID: controlPlaneSPIFFEID
            )

            // Validate what actually gets pinned, not just the override: an
            // empty trust_domain derives the equally malformed
            // "spiffe:///control-plane", and either way the only symptom
            // would be every TLS handshake failing with a pin mismatch.
            let resolvedID = parsedSPIFFEConfig.resolvedControlPlaneSPIFFEID
            guard SPIFFEConfig.isWellFormedSPIFFEID(resolvedID) else {
                let source =
                    controlPlaneSPIFFEID == nil
                    ? "derived from trust_domain '\(trustDomain ?? "")'"
                    : "from control_plane_spiffe_id"
                throw AgentConfigError.invalidConfiguration(
                    "The control plane's pinned SPIFFE ID (\(source)) must be a full SPIFFE ID "
                        + "(spiffe://<trust-domain>/<path>), got '\(resolvedID)'"
                )
            }

            spiffeConfig = parsedSPIFFEConfig

            if spiffeEnabled == true {
                logger?.info(
                    "SPIFFE authentication enabled",
                    metadata: [
                        "trustDomain": .string(trustDomain ?? SPIFFEConfig.defaultTrustDomain),
                        "sourceType": .string(sourceType ?? "workload_api"),
                    ])
            }
        } else {
            spiffeConfig = nil
        }

        // Parse the OVN uplink from the [ovn_uplink] scope (issue #342). SNAT
        // egress is off unless a dedicated external CIDR is configured.
        let uplinkValues = values.scoped(to: "ovn_uplink")
        let externalCIDR = try await uplinkValues.string("external_cidr")
        let gateway = try await uplinkValues.string("gateway")
        let bridge = try await uplinkValues.string("bridge")
        let physnet = try await uplinkValues.string("physnet")
        let externalCIDR6 = try await uplinkValues.string("external_cidr6")
        let gateway6 = try await uplinkValues.string("gateway6")
        let hasUplinkConfig =
            externalCIDR != nil || gateway != nil || bridge != nil || physnet != nil
            || externalCIDR6 != nil || gateway6 != nil
        let ovnUplink: OVNUplinkConfig?
        if hasUplinkConfig {
            guard let externalCIDR else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_uplink] external_cidr is required when the section is configured")
            }
            ovnUplink = OVNUplinkConfig(
                externalCIDR: externalCIDR,
                gateway: gateway,
                bridge: bridge ?? OVNUplinkConfig.defaultBridge,
                physnet: physnet ?? OVNUplinkConfig.defaultPhysnet,
                externalCIDR6: externalCIDR6,
                gateway6: gateway6
            )
            logger?.info(
                "OVN SNAT uplink configured",
                metadata: [
                    "externalCIDR": .string(externalCIDR),
                    "externalCIDR6": .string(externalCIDR6 ?? "none"),
                ])
        } else {
            ovnUplink = nil
        }

        // Parse OVN native dynamic routing from its scoped values (issue #344).
        let routingValues = values.scoped(to: "ovn_dynamic_routing")
        let routingEnabled = try await routingValues.bool("enabled")
        let redistribute = try await routingValues.stringArray("redistribute")
        let vrfName = try await routingValues.string("vrf_name")
        let maintainVRF = try await routingValues.bool("maintain_vrf")
        let routingProtocols = try await routingValues.stringArray("routing_protocols")
        let hasRoutingConfig =
            routingEnabled != nil || redistribute != nil || vrfName != nil
            || maintainVRF != nil || routingProtocols != nil
        let ovnDynamicRouting: OVNDynamicRoutingConfig?
        if hasRoutingConfig {
            let config = OVNDynamicRoutingConfig(
                enabled: routingEnabled ?? false,
                redistribute: redistribute ?? OVNDynamicRoutingConfig.defaultRedistribute,
                vrfName: vrfName,
                maintainVRF: maintainVRF ?? true,
                routingProtocols: routingProtocols ?? OVNDynamicRoutingConfig.defaultRoutingProtocols
            )
            let invalid = config.invalidValues
            guard invalid.isEmpty else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_dynamic_routing] has unsupported value(s): \(invalid.joined(separator: ", ")). "
                        + "redistribute allows \(OVNDynamicRoutingConfig.allowedRedistributeValues.sorted().joined(separator: "/")); "
                        + "routing_protocols allows \(OVNDynamicRoutingConfig.allowedRoutingProtocols.sorted().joined(separator: "/"))"
                )
            }
            ovnDynamicRouting = config
            if config.enabled {
                logger?.info(
                    "OVN dynamic routing enabled (requires OVN >= 25.03 and host FRR)",
                    metadata: [
                        "redistribute": .string(config.redistribute.joined(separator: ",")),
                        "routingProtocols": .string(config.routingProtocols.joined(separator: ",")),
                    ])
            }
        } else {
            ovnDynamicRouting = nil
        }

        // Parse the per-network resolver from its scoped values (STR-40).
        let resolverValues = values.scoped(to: "resolver")
        let resolverEnabled = try await resolverValues.bool("enabled")
        let corednsBinaryPath = try await resolverValues.string("coredns_binary_path")
        let resolverConfigDirectory = try await resolverValues.string("config_dir")
        let resolverRatePPS = try await resolverValues.int("rate_limit_pps")
        let hasResolverConfig =
            resolverEnabled != nil || corednsBinaryPath != nil
            || resolverConfigDirectory != nil || resolverRatePPS != nil
        let resolver: NetworkResolverConfig?
        if hasResolverConfig {
            guard resolverRatePPS.map({ $0 >= 0 }) ?? true else {
                throw AgentConfigError.invalidConfiguration(
                    "[resolver] rate_limit_pps must be zero (no limit) or a positive integer")
            }
            resolver = NetworkResolverConfig(
                enabled: resolverEnabled ?? true,
                corednsBinaryPath: corednsBinaryPath,
                configDirectory: resolverConfigDirectory,
                rateLimitPPS: resolverRatePPS)
        } else {
            resolver = nil
        }

        // Parse simulation ("dummy agent") settings from its scoped values.
        let simulationValues = values.scoped(to: "simulation")
        let simulationEnabled = try await simulationValues.bool("enabled")
        let simulationCPUCores = try await simulationValues.int("cpu_cores")
        let simulationMemoryMB = try await simulationValues.int("memory_mb")
        let simulationDiskGB = try await simulationValues.int("disk_gb")
        let simulationLogIntervalMS = try await simulationValues.int("sandbox_log_interval_ms")
        let simulationExitAfterSeconds = try await simulationValues.int("sandbox_exit_after_seconds")
        let hasSimulationConfig =
            simulationEnabled != nil || simulationCPUCores != nil || simulationMemoryMB != nil
            || simulationDiskGB != nil || simulationLogIntervalMS != nil
            || simulationExitAfterSeconds != nil
        let simulationConfig: SimulationConfig?
        if hasSimulationConfig {
            simulationConfig = SimulationConfig(
                enabled: simulationEnabled ?? false,
                cpuCores: simulationCPUCores,
                memoryMB: simulationMemoryMB,
                diskGB: simulationDiskGB,
                sandboxLogIntervalMS: simulationLogIntervalMS,
                sandboxExitAfterSeconds: simulationExitAfterSeconds
            )
            if simulationEnabled == true {
                logger?.warning(
                    "Simulation mode enabled: this agent will NOT run real VMs",
                    metadata: [
                        "cpuCores": .stringConvertible(simulationConfig?.resolvedCPUCores ?? 0)
                    ])
            }
        } else {
            simulationConfig = nil
        }

        // Validate platform-specific settings
        #if os(macOS)
        if enableKVM == true {
            logger?.warning("enable_kvm is not supported on macOS, will be ignored")
        }
        #elseif os(Linux)
        if enableHVF == true {
            logger?.warning("enable_hvf is only supported on macOS, will be ignored")
        }
        #endif

        return AgentConfig(
            controlPlaneURL: controlPlaneURL,
            logLevel: logLevel,
            networkMode: networkMode,
            ovnEncapIP: ovnEncapIP,
            ovnEncapType: ovnEncapType,
            ovnRemote: ovnRemote,
            ovnBootstrapChassis: ovnBootstrapChassis,
            ovnNorthbound: ovnNorthbound,
            ovnNorthboundTLS: ovnNorthboundTLS,
            enableHVF: enableHVF,
            enableKVM: enableKVM,
            qemuMemoryOverheadMB: qemuMemoryOverheadMB,
            vmStoragePath: vmStoragePath,
            volumeStoragePath: volumeStoragePath,
            imageCacheDir: imageCacheDir,
            imageCacheMaxSizeGB: imageCacheMaxSizeGB,
            sandboxImageCacheDir: sandboxImageCacheDir,
            sandboxImageCacheMaxSizeGB: sandboxImageCacheMaxSizeGB,
            firmwarePathARM64: firmwarePathARM64,
            firmwarePathX86_64: firmwarePathX86_64,
            firmwareCodePath: firmwareCodePath,
            firmwareVarsTemplate: firmwareVarsTemplate,
            secureBootFirmwareCodePath: secureBootFirmwareCodePath,
            secureBootFirmwareVarsTemplate: secureBootFirmwareVarsTemplate,
            spiffe: spiffeConfig,
            firecrackerBinaryPath: firecrackerBinaryPath,
            firecrackerSocketDir: firecrackerSocketDir,
            sandboxGuestImagePath: sandboxGuestImagePath,
            sandboxJailerMode: sandboxJailerMode,
            sandboxJailerBinaryPath: sandboxJailerBinaryPath,
            sandboxJailerChrootDir: sandboxJailerChrootDir,
            sandboxJailerUidBase: sandboxJailerUidBase,
            sandboxWarmStart: sandboxWarmStart,
            sandboxWarmCacheMaxSizeGB: sandboxWarmCacheMaxSizeGB,
            hypervisorType: hypervisorType,
            ovnUplink: ovnUplink,
            ovnDynamicRouting: ovnDynamicRouting,
            resolver: resolver,
            simulation: simulationConfig,
            reconcileTeardownMinimum: reconcileTeardownMinimum,
            reconcileTeardownPercent: reconcileTeardownPercent,
            allowBulkTeardown: allowBulkTeardown,
            desiredStateFullRefetchSeconds: desiredStateFullRefetchSeconds,
            metadataService: metadataService,
            metadataResponseHopLimit: metadataResponseHopLimit
        )
    }

    /// Reads an integer key that must be positive when present.
    private static func positiveInt(_ values: AgentConfigReader, key: String) async throws -> Int? {
        guard let value = try await values.int(key) else { return nil }
        guard value > 0 else {
            throw AgentConfigError.invalidConfiguration("\(key) must be a positive integer, got \(value)")
        }
        return value
    }

    /// Small throwing facade over ConfigReader's typed fetch APIs. ConfigReader's
    /// synchronous optional getters intentionally hide provider conversion errors;
    /// configuration loading must instead reject malformed environment overrides.
    struct AgentConfigReader: Sendable {
        let reader: ConfigReader
        let prefix: String?

        init(_ reader: ConfigReader, prefix: String? = nil) {
            self.reader = reader
            self.prefix = prefix
        }

        func scoped(to key: String) -> Self {
            Self(reader.scoped(to: ConfigKey(key)), prefix: qualified(key))
        }

        func string(_ key: String) async throws -> String? {
            try await fetch(key) { try await reader.fetchString(forKey: ConfigKey(key)) }
        }

        func int(_ key: String) async throws -> Int? {
            try await fetch(key) { try await reader.fetchInt(forKey: ConfigKey(key)) }
        }

        func bool(_ key: String) async throws -> Bool? {
            try await fetch(key) { try await reader.fetchBool(forKey: ConfigKey(key)) }
        }

        func stringArray(_ key: String) async throws -> [String]? {
            try await fetch(key) { try await reader.fetchStringArray(forKey: ConfigKey(key)) }
        }

        private func fetch<Value: Sendable>(
            _ key: String,
            operation: () async throws -> Value?
        ) async throws -> Value? {
            do {
                return try await operation()
            } catch {
                throw AgentConfigError.invalidConfiguration(
                    "\(qualified(key)) could not be read: \(error)")
            }
        }

        private func qualified(_ key: String) -> String {
            prefix.map { "\($0).\(key)" } ?? key
        }
    }

    /// Reject settings the agent does not consume. This makes removed options
    /// and ordinary typos fail at startup instead of silently doing nothing.
    private static func validateKnownSettings(_ toml: Toml) throws {
        if let unknownKey = toml.keyNames
            .map(\.components)
            .filter({ !knownSettingPaths.contains($0) })
            .sorted(by: { $0.lexicographicallyPrecedes($1) })
            .first
        {
            throw AgentConfigError.invalidConfiguration(
                "unknown setting '\(unknownKey.joined(separator: "."))'")
        }

        if let unknownTable = toml.tableNames
            .map(\.components)
            .filter({ !knownTablePaths.contains($0) })
            .sorted(by: { $0.lexicographicallyPrecedes($1) })
            .first
        {
            throw AgentConfigError.invalidConfiguration(
                "unknown section '[\(unknownTable.joined(separator: "."))]'")
        }
    }

}
