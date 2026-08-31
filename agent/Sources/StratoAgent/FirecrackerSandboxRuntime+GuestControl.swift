import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

/// Owns status mapping, guest-control exchange, identity recovery, and jail plumbing.
extension FirecrackerSandboxRuntime {
    // MARK: - Status mapping

    /// Fold the Firecracker instance state and (when running) the guest agent's
    /// workload state into the observed `SandboxStatus`.
    func mappedStatus(
        instance: InstanceState, udsPath: String, sandboxId: String
    ) async -> SandboxStatus {
        switch instance {
        case .notStarted:
            return .stopped
        case .paused:
            // A control-plane stop; a workload that had already exited is
            // remembered as such.
            return sandboxes[sandboxId]?.lastExitCode != nil ? .exited : .stopped
        case .running:
            // A checkpoint/restore in flight has drained the guest control
            // channel; opening a fresh connection here would race the drain
            // (Firecracker refuses to snapshot a vsock device with live
            // connections). The instance is demonstrably running.
            if checkpointing.contains(sandboxId) {
                return .running
            }
            do {
                let response = try await sendControl(.getStatus, udsPath: udsPath, timeout: 5)
                guard case .status(_, _, let state, let exitCode) = response else {
                    return .starting
                }
                // Ignore a response from a stale generation still bound to the
                // deterministic UDS rather than reporting another sandbox's
                // status/exit code and advancing convergence on it.
                let expectedNonce = sandboxes[sandboxId]?.identityNonce ?? ""
                guard identityMatches(response, sandboxId: sandboxId, expectedNonce: expectedNonce) else {
                    logger.warning(
                        "Ignoring sandbox control status from a mismatched guest identity",
                        metadata: ["strato.sandbox.id": .string(sandboxId)])
                    return .unknown
                }
                switch state {
                case .starting:
                    return .starting
                case .held:
                    // A warm-provisioned guest awaiting its launch (issue
                    // #426): the microVM runs but the workload does not
                    // exist yet — still converging toward running.
                    return .starting
                case .running:
                    return .running
                case .exited:
                    if let exitCode {
                        sandboxes[sandboxId]?.lastExitCode = exitCode
                    }
                    return .exited
                }
            } catch {
                // The microVM is up but the guest agent isn't answering yet
                // (still booting) or is momentarily busy — still converging.
                return .starting
            }
        }
    }

    // MARK: - Guest control channel

    /// Open a fresh vsock connection, send one control request, and read the
    /// single newline-delimited JSON response. Stateless per call: the guest
    /// serve loop accepts many short-lived connections, and re-opening avoids
    /// stale file descriptors across polls.
    ///
    /// The read phase is bounded by the connection's own per-read deadline, so
    /// a guest that accepts the connection but then wedges before sending a
    /// full line fails that one read rather than hanging the poll. This used to
    /// require racing a task group and closing the socket out from under a
    /// blocking `read(2)`.
    func sendControl(
        _ request: GuestControlProtocol.Request, udsPath: String, timeout: TimeInterval
    ) async throws -> GuestControlProtocol.Response {
        let connection = try await VsockConnection.connect(
            udsPath: udsPath, port: SandboxConfigDrive.defaultVsockPort, timeout: timeout, logger: logger)

        do {
            let response = try await Self.exchange(request, on: connection, timeout: timeout)
            await connection.close()
            return response
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Read one line, translating the transport's timeout into this runtime's
    /// own `GuestControlError.timeout` so callers keep a stable, sandbox-
    /// specific error vocabulary regardless of how the read is bounded.
    static func nextControlLine(
        on connection: VsockConnection, timeout: TimeInterval
    ) async throws -> String? {
        do {
            return try await connection.nextLine(timeout: timeout)
        } catch let error as FirecrackerError {
            if case .timeout = error { throw GuestControlError.timeout }
            throw error
        }
    }

    /// Write one request and read the single newline-delimited response,
    /// bounded by `timeout`.
    static func exchange(
        _ request: GuestControlProtocol.Request, on connection: VsockConnection,
        timeout: TimeInterval
    ) async throws -> GuestControlProtocol.Response {
        try await connection.write(request.encodedLine())

        guard let line = try await nextControlLine(on: connection, timeout: timeout) else {
            throw GuestControlError.malformedResponse("guest closed before sending a full response line")
        }
        let response = try GuestControlProtocol.Response.decode(line: line)
        if case .error(_, let message) = response {
            throw GuestControlError.guestError(message)
        }
        return response
    }

    // MARK: - Guest identity

    /// Confirm a control response echoes this sandbox's identity, so a stale
    /// generation still serving the deterministic vsock UDS (a leaked process, a
    /// pre-adoption resume) cannot be mistaken for the current one. The nonce is
    /// always checked; supported config drives require it.
    func identityMatches(
        _ response: GuestControlProtocol.Response, sandboxId: String, expectedNonce: String
    ) -> Bool {
        let echoedId: String
        let echoedNonce: String
        switch response {
        case .pong(let id, let nonce, _):
            (echoedId, echoedNonce) = (id, nonce)
        case .status(let id, let nonce, _, _):
            (echoedId, echoedNonce) = (id, nonce)
        default:
            return false
        }
        return echoedId == sandboxId && echoedNonce == expectedNonce
    }

    /// Read the boot nonce back from a sandbox's staged config drive (at its
    /// host-view path, flat or in-jail), requiring the current schema and the
    /// expected sandbox identity.
    func recoverIdentityNonce(
        configPath: String, expectedSandboxId: String
    ) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let drive = try SandboxConfigDrive.decode(fromBlockImage: data)
        guard drive.sandboxId == expectedSandboxId else {
            throw GuestControlError.identityMismatch(
                expected: expectedSandboxId, got: drive.sandboxId)
        }
        return drive.identityNonce
    }

    // MARK: - Jail plumbing (issue #425)

    /// Hard-link `from` to `to` when both live on one filesystem (the shared
    /// kernel/initramfs are read-only, so a link is safe), falling back to a
    /// copy across filesystems.
    func linkOrCopy(from: String, to: String) throws {
        if (try? FileManager.default.linkItem(atPath: from, toPath: to)) != nil {
            return
        }
        try FileManager.default.copyItem(atPath: from, toPath: to)
    }

    /// `chown(2)` wrapper — the jailed Firecracker runs as a per-sandbox uid
    /// and must own its writable artifacts.
    func chownPath(_ path: String, uid: UInt32, gid: UInt32) throws {
        guard chown(path, uid_t(uid), gid_t(gid)) == 0 else {
            throw SandboxRuntimeError.jailSetupFailed(
                "chown \(uid):\(gid) \(path) failed: \(String(cString: strerror(errno)))")
        }
    }

    /// The jailer cgroup flags for one sandbox: on hosts with a cgroup-v2
    /// memory controller, a `memory.max` ceiling protecting the *host* from a
    /// compromised VMM (the agent's manifest accounting remains the only
    /// capacity owner — see docs/architecture/sandboxes.md). Hosts without
    /// one (cgroup v1, or v2 with the memory controller disabled — the jailer
    /// aborts on any `--cgroup` file it cannot write) get no ceiling and one
    /// warning.
    func jailerCgroups(guestMemoryBytes: Int64) -> (version: Int?, entries: [String]) {
        guard SandboxJailPlan.hostSupportsMemoryCeiling() else {
            if !warnedNoMemoryCeiling {
                warnedNoMemoryCeiling = true
                logger.warning(
                    "Host has no usable cgroup-v2 memory controller; sandboxes run jailed but without a jailer memory ceiling"
                )
            }
            return (nil, [])
        }
        return (2, ["memory.max=\(SandboxJailPlan.memoryLimitBytes(guestMemoryBytes: guestMemoryBytes))"])
    }

    /// Create the sandbox's dedicated network namespace. A namespace left by
    /// a crashed previous life is reused — it is empty either way. Invokes
    /// the `ip` binary the resolver located, never a `PATH` lookup: the
    /// resolution that declared this host jail-capable and the spawn must
    /// agree on the same binary.
    func createNetns(_ name: String) async throws {
        guard let ipBinaryPath = jailerConfig.ipBinaryPath else {
            // Unreachable when the resolver gated jailing: it requires `ip`.
            throw SandboxRuntimeError.jailSetupFailed(
                "the `ip` tool (iproute2) was not found on this host")
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: ipBinaryPath),
                arguments: ["netns", "add", name])
        } catch {
            throw SandboxRuntimeError.jailSetupFailed(
                "spawning `\(ipBinaryPath) netns add \(name)` failed: \(error.localizedDescription)")
        }
        if result.terminationStatus != 0 {
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.contains("File exists") { return }
            throw SandboxRuntimeError.jailSetupFailed(
                "`ip netns add \(name)` failed (exit \(result.terminationStatus)): \(output)")
        }
    }

    /// Best-effort teardown of a jailed sandbox's host-side leftovers: the
    /// chroot subtree and per-VM cgroup directory (normally the client's job,
    /// but a crash can orphan both) and the network namespace.
    ///
    /// `removingNetns: false` is for the paths that rebuild the *same* sandbox
    /// under the same id — a failed warm restore falling back to a cold boot,
    /// and the demotion of a failed warm launch. The namespace holds the veth,
    /// TAP and `tc` filters the orchestrator realized for this sandbox's NIC
    /// (STR-100), and the runtime cannot recreate them: deleting it there would
    /// leave the rebuilt microVM configured against a TAP that no longer
    /// exists. Every other caller is tearing the sandbox down for good, or
    /// rolling a create back to the reconciler that will tear the attachment
    /// down itself.
    func removeJailArtifacts(_ plan: SandboxJailPlan, removingNetns: Bool = true) async {
        try? FileManager.default.removeItem(atPath: plan.jailDirectory)
        _ = rmdir(
            JailerOptions.cgroupDirectory(
                firecrackerBinaryPath: firecrackerBinaryPath, vmId: plan.sandboxId))
        guard removingNetns else { return }
        // `ip netns delete` is just an unmount plus unlink of the bind-mounted
        // name (ip-netns(8)); doing the syscalls directly means teardown keeps
        // working even when iproute2 was removed after a previous agent life
        // created the namespace. Best effort — ENOENT (never created) and
        // EPERM (non-root dev agent, which never created one) are both fine.
        _ = umount2(plan.netnsPath, Int32(MNT_DETACH))
        _ = unlink(plan.netnsPath)
    }

    // MARK: - Paths

    func sandboxDirectory(_ sandboxId: String) -> String {
        sandboxStoragePath + "/" + sandboxId
    }

    func vsockUDSPath(_ sandboxId: String) -> String {
        socketDirectory + "/" + sandboxId + ".vsock"
    }

    func removeArtifacts(_ sandboxId: String) {
        try? FileManager.default.removeItem(atPath: sandboxDirectory(sandboxId))
    }
}

#endif
