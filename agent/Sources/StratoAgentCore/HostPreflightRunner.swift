import Foundation
import StratoShared

extension HostPreflight {
    // MARK: - Running the checks

    public static func run(_ inputs: Inputs) -> Report {
        var checks: [Check] = []

        checks.append(
            ensureWritableDirectory(
                inputs.vmStoragePath, kind: .vmStorageDirectory, configKey: "vm_storage_dir"))
        checks.append(
            ensureWritableDirectory(
                inputs.volumeStoragePath, kind: .volumeStorageDirectory, configKey: "volume storage path"))
        checks.append(
            ensureWritableDirectory(
                inputs.imageCachePath, kind: .imageCacheDirectory, configKey: "image cache path"))
        if let firecrackerSocketDir = inputs.firecrackerSocketDirectory {
            checks.append(
                ensureWritableDirectory(
                    firecrackerSocketDir, kind: .firecrackerSocketDirectory,
                    configKey: "firecracker_socket_dir"))
            if let pidfdSupport = inputs.firecrackerPIDFDSupport {
                checks.append(checkFirecrackerPIDFD(pidfdSupport))
            }
        }
        if let jailerUIDRange = inputs.sandboxJailerUIDRange {
            checks.append(checkSandboxJailerUIDRange(jailerUIDRange))
        }

        checks.append(checkQemuImg(inputs.qemuImgPath))
        checks.append(checkFirmware(inputs.firmwarePath))

        // libvirt before the vTPM check, and not only for reading order: a host
        // whose daemon is unusable was never asked about a vTPM, and saying so
        // depends on knowing that the check above already failed. Every
        // remaining check is independent of both.
        var libvirtUsable = false
        if let libvirt = inputs.libvirt {
            let libvirtChecks = checkLibvirt(libvirt, minimumVersion: inputs.minimumLibvirtVersion)
            libvirtUsable = libvirtChecks.allSatisfy(\.passed)
            checks.append(contentsOf: libvirtChecks)
        }
        checks.append(checkVhostVsock(inputs.vhostVsock))
        checks.append(checkTPMSupport(inputs.tpmSupport, libvirtUsable: libvirtUsable))
        if let descriptorPath = inputs.qemuFirmwareDescriptorPath {
            checks.append(checkFirmwareDescriptors(descriptorPath))
        }

        if inputs.ovnMode {
            if inputs.ovnNBConnection.hasPrefix("unix:") {
                checks.append(
                    checkSocket(
                        String(inputs.ovnNBConnection.dropFirst("unix:".count)), kind: .ovnDatabaseSocket,
                        hint: "is OVN (ovn-central / ovn-controller) installed and running on this host?"))
            } else {
                // Remote NB (shared site central): nothing local to probe;
                // reachability surfaces when the network service connects.
                checks.append(.pass(.ovnDatabaseSocket))
            }
            if !inputs.ovnNBTLSFilePaths.isEmpty {
                checks.append(checkTLSFiles(inputs.ovnNBTLSFilePaths))
            }
            checks.append(
                checkSocket(
                    inputs.ovsSocketPath, kind: .ovsDatabaseSocket,
                    hint: "is Open vSwitch (ovsdb-server / ovs-vswitchd) installed and running on this host?"))
            checks.append(
                checkTool(
                    "ip", kind: .ipTool, searchPath: inputs.searchPath,
                    hint: "install iproute2; the agent needs it to manage TAP devices"))
            // Advisory: only *networked sandboxes* need `tc` (it installs the
            // redirects splicing a jailed VMM's TAP to its veth). VMs and
            // network-free sandboxes are unaffected, so a host without it is
            // degraded, not broken.
            //
            // The hint names the candidate list because this check and the
            // resolver disagree by construction: the check walks `PATH`, while
            // the attach path invokes an absolute path resolved from a fixed
            // list (a service manager's stripped `PATH` must not break it). A
            // `tc` outside that list passes here and still refuses every
            // networked sandbox, so the hint has to point at the real cause.
            checks.append(
                checkTool(
                    "tc", kind: .tcTool, severity: .advisory, searchPath: inputs.searchPath,
                    hint: "install iproute2; without `tc` the agent cannot attach a NIC into a jailed "
                        + "sandbox's network namespace. It must be at one of "
                        + SandboxJailerResolver.tcBinaryCandidates.joined(separator: ", ")
                        + " — the agent invokes it by absolute path, not via PATH"))
            checks.append(
                checkTool(
                    "ovs-vsctl", kind: .ovsVsctlTool, searchPath: inputs.searchPath,
                    hint: "install openvswitch-switch; the agent needs it to attach VM NICs to the integration bridge"
                ))
            checks.append(
                checkTool(
                    "ovn-appctl", kind: .ovnAppctlTool, severity: .advisory, searchPath: inputs.searchPath,
                    hint: "install ovn-host; without it the agent cannot verify ovn-controller is connected "
                        + "to the southbound database"))
            // Advisory, and deliberately not gating: a host without CoreDNS
            // runs VMs perfectly well. What it cannot do is answer on a
            // network's resolver address — so it registers `resolverCapable:
            // false` and the control plane withholds the resolver from every
            // network in its *site*, because the DHCP option pointing guests at
            // it is authored once per network while the listener is per chassis.
            //
            // The consequence is that one un-provisioned host holds the feature
            // back for its whole site, which is why this is worth a loud line at
            // startup rather than a silent capability bit. Like `tc`, the hint
            // names the candidate list: this check walks `PATH` while the
            // supervisor invokes an absolute path.
            checks.append(
                checkTool(
                    "coredns", kind: .corednsBinary, severity: .advisory, searchPath: inputs.searchPath,
                    hint: "install CoreDNS; without it this host cannot serve its networks' DNS resolver, "
                        + "and the control plane withholds the resolver from every network in this site. "
                        + "It must be at one of "
                        + NetworkResolverDefaults.corednsBinaryCandidates.joined(separator: ", ")
                        + ", or named by [resolver] coredns_binary_path"))
            checks.append(checkGlobalReversePathFilter(inputs.globalReversePathFilter))
        }

        checks.append(checkFreeSpace(inputs.vmStoragePath, minimum: inputs.minimumFreeDiskBytes))

        return Report(checks: checks)
    }

}
