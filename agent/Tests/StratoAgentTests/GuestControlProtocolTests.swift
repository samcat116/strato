import Foundation
import Testing

@testable import StratoAgentCore

/// Encode/decode coverage for the host mirror of the guest control protocol
/// (issues #421/#423): every request encodes to the exact snake_case shape the
/// guest's serde contract expects, and every guest response line decodes to
/// the matching case. Pure JSON — no vsock required.
///
/// These assertions predate the `SandboxControlProtocol` → ``GuestControlProtocol``
/// rename and are unchanged by it: the wire format did not move, so they are the
/// regression net proving it. Hardening coverage lives in
/// `GuestControlProtocolHardeningTests`.
@Suite("Guest Control Protocol Tests")
struct GuestControlProtocolTests {

    /// Parse one encoded request line back into a JSON object (asserting the
    /// newline-terminated single-line framing on the way).
    private func decodedObject(_ request: GuestControlProtocol.Request) throws -> [String: Any] {
        let line = request.encodedLine()
        #expect(line.last == 0x0A)
        let body = line.dropLast()
        #expect(!body.contains(0x0A))
        let object = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
        return try #require(object)
    }

    // MARK: - Request encoding (v1 surface, now via JSONEncoder)

    @Test("ping and get_status encode as bare type-tagged lines")
    func v1RequestsEncode() throws {
        // Byte-exact: the pre-v2 hand-rolled encoding is the guest's serde
        // contract, and the JSONEncoder-based path must keep producing it.
        let pingLine = GuestControlProtocol.Request.ping.encodedLine()
        #expect(pingLine == Data("{\"type\":\"ping\"}\n".utf8))
        let statusLine = GuestControlProtocol.Request.getStatus.encodedLine()
        #expect(statusLine == Data("{\"type\":\"get_status\"}\n".utf8))
    }

    // MARK: - Request encoding (v2 surface)

    @Test("exec encodes every field under its snake_case key")
    func execEncodesAllFields() throws {
        let request = GuestControlProtocol.ExecRequest(
            argv: ["/bin/sh", "-c", "echo hi"],
            env: ["FOO": "bar"],
            cwd: "/app",
            tty: true,
            rows: 24,
            cols: 80
        )
        let object = try decodedObject(.exec(request))
        #expect(object["type"] as? String == "exec")
        #expect(object["argv"] as? [String] == ["/bin/sh", "-c", "echo hi"])
        #expect(object["env"] as? [String: String] == ["FOO": "bar"])
        #expect(object["cwd"] as? String == "/app")
        #expect(object["tty"] as? Bool == true)
        #expect(object["rows"] as? Int == 24)
        #expect(object["cols"] as? Int == 80)
    }

    @Test("exec omits optional fields instead of encoding null")
    func execOmitsAbsentOptionals() throws {
        let request = GuestControlProtocol.ExecRequest(argv: ["/bin/true"])
        let object = try decodedObject(.exec(request))
        #expect(object["type"] as? String == "exec")
        #expect(object["argv"] as? [String] == ["/bin/true"])
        #expect(object["tty"] as? Bool == false)
        #expect(object["env"] == nil)
        #expect(object["cwd"] == nil)
        #expect(object["rows"] == nil)
        #expect(object["cols"] == nil)
    }

    @Test("stdin encodes its bytes as base64 under data")
    func stdinEncodesBase64() throws {
        let bytes = Data([0x00, 0x01, 0xFF, 0x0A])
        let object = try decodedObject(.stdin(bytes))
        #expect(object["type"] as? String == "stdin")
        let encoded = object["data"] as? String
        #expect(encoded == bytes.base64EncodedString())
    }

    @Test("stdin_eof encodes as a bare type-tagged line")
    func stdinEofEncodes() throws {
        let object = try decodedObject(.stdinEof)
        #expect(object["type"] as? String == "stdin_eof")
        #expect(object.count == 1)
    }

    @Test("resize encodes rows and cols")
    func resizeEncodes() throws {
        let object = try decodedObject(.resize(rows: 30, cols: 100))
        #expect(object["type"] as? String == "resize")
        #expect(object["rows"] as? Int == 30)
        #expect(object["cols"] as? Int == 100)
    }

    @Test("stream_logs encodes since_seq in snake_case")
    func streamLogsEncodes() throws {
        let object = try decodedObject(.streamLogs(sinceSeq: 17))
        #expect(object["type"] as? String == "stream_logs")
        #expect(object["since_seq"] as? UInt64 == 17)
        #expect(object.count == 2)
    }

    @Test("sync_clock encodes unix_nanos in snake_case")
    func syncClockEncodes() throws {
        let object = try decodedObject(.syncClock(unixNanos: 1_752_700_000_000_000_000))
        #expect(object["type"] as? String == "sync_clock")
        #expect((object["unix_nanos"] as? NSNumber)?.int64Value == 1_752_700_000_000_000_000)
        #expect(object.count == 2)
    }

    @Test("clock_synced decodes")
    func clockSyncedDecodes() throws {
        let response = try GuestControlProtocol.Response.decode(line: #"{"type":"clock_synced"}"#)
        #expect(response == .clockSynced)
    }

    // MARK: - Warm start (issue #426)

    @Test("launch encodes identity, config-drive shapes, and base64 entropy")
    func launchEncodes() throws {
        let entropy = Data([0x01, 0x02, 0xFE])
        let request = GuestControlProtocol.LaunchRequest(
            sandboxId: "sb-2",
            identityNonce: "n-2",
            imageConfig: SandboxConfigDrive.ImageConfig(
                env: ["PATH=/bin"], entrypoint: ["/bin/app"], cmd: ["--serve"],
                workingDir: "/app", user: "1000:1000"),
            overrides: SandboxConfigDrive.ProcessOverrides(
                entrypoint: nil, cmd: ["--other"], env: ["DEBUG": "1"], workdir: nil, user: nil),
            entropy: entropy)
        let object = try decodedObject(.launch(request))
        #expect(object["type"] as? String == "launch")
        #expect(object["sandbox_id"] as? String == "sb-2")
        #expect(object["identity_nonce"] as? String == "n-2")
        #expect(object["entropy"] as? String == entropy.base64EncodedString())

        // The nested shapes are the config drive's serde contracts: OCI
        // PascalCase inside image_config, snake_case inside overrides, with
        // absent optionals omitted (never null).
        let imageConfig = try #require(object["image_config"] as? [String: Any])
        #expect(imageConfig["Env"] as? [String] == ["PATH=/bin"])
        #expect(imageConfig["Entrypoint"] as? [String] == ["/bin/app"])
        #expect(imageConfig["Cmd"] as? [String] == ["--serve"])
        #expect(imageConfig["WorkingDir"] as? String == "/app")
        #expect(imageConfig["User"] as? String == "1000:1000")
        let overrides = try #require(object["overrides"] as? [String: Any])
        #expect(overrides["cmd"] as? [String] == ["--other"])
        #expect(overrides["env"] as? [String: String] == ["DEBUG": "1"])
        #expect(overrides["entrypoint"] == nil)
        #expect(overrides["workdir"] == nil)
        #expect(overrides["user"] == nil)
    }

    @Test("launch omits entropy when absent")
    func launchOmitsAbsentEntropy() throws {
        let request = GuestControlProtocol.LaunchRequest(
            sandboxId: "sb-3", identityNonce: "n-3",
            imageConfig: SandboxConfigDrive.ImageConfig(
                env: [], entrypoint: [], cmd: ["/bin/true"], workingDir: "", user: ""),
            overrides: SandboxConfigDrive.ProcessOverrides(
                entrypoint: nil, cmd: nil, env: [:], workdir: nil, user: nil),
            entropy: nil)
        let object = try decodedObject(.launch(request))
        #expect(object["entropy"] == nil)
        // A network-free sandbox's launch is byte-identical to a pre-STR-104
        // one: `network` is omitted, never null.
        #expect(object["network"] == nil)
    }

    /// A warm template's device was never addressed — the template is shared
    /// across sandboxes — so the launch is what makes it *this* sandbox's NIC
    /// (STR-104).
    @Test("launch carries the sandbox's own NIC configuration")
    func launchCarriesNetwork() throws {
        let request = GuestControlProtocol.LaunchRequest(
            sandboxId: "sb-4", identityNonce: "n-4",
            imageConfig: SandboxConfigDrive.ImageConfig(
                env: [], entrypoint: [], cmd: ["/bin/true"], workingDir: "", user: ""),
            overrides: SandboxConfigDrive.ProcessOverrides(
                entrypoint: nil, cmd: nil, env: [:], workdir: nil, user: nil),
            entropy: nil,
            network: SandboxConfigDrive.NetworkConfig(
                macAddress: "06:00:ac:10:00:07",
                ipv4: SandboxConfigDrive.AddressConfig(
                    address: "172.16.0.7", prefixLength: 24, gateway: "172.16.0.1"),
                mtu: 1442,
                nameservers: ["172.16.0.2"],
                searchDomains: ["proj.strato.internal"]))

        let object = try decodedObject(.launch(request))
        let network = try #require(object["network"] as? [String: Any])
        #expect(network["mac_address"] as? String == "06:00:ac:10:00:07")
        #expect(network["mtu"] as? Int == 1442)
        #expect(network["nameservers"] as? [String] == ["172.16.0.2"])
        #expect(network["search_domains"] as? [String] == ["proj.strato.internal"])
        let ipv4 = try #require(network["ipv4"] as? [String: Any])
        #expect(ipv4["address"] as? String == "172.16.0.7")
        #expect(ipv4["prefix_length"] as? Int == 24)
        #expect(ipv4["gateway"] as? String == "172.16.0.1")
        #expect(network["ipv6"] == nil)
    }

    @Test("launched decodes")
    func launchedDecodes() throws {
        let response = try GuestControlProtocol.Response.decode(line: #"{"type":"launched"}"#)
        #expect(response == .launched)
    }

    @Test("reidentify encodes source guard, target identity, clock, and entropy")
    func reidentifyEncodes() throws {
        let entropy = Data(repeating: 0xA5, count: 32)
        let request = GuestControlProtocol.ReidentifyRequest(
            expectedSandboxId: "source",
            expectedNonce: "old-nonce",
            sandboxId: "fork",
            identityNonce: "new-nonce",
            hostname: "strato-fork",
            entropy: entropy,
            unixNanos: 1_752_700_000_000_000_000)

        let object = try decodedObject(.reidentify(request))
        #expect(object["type"] as? String == "reidentify")
        #expect(object["expected_sandbox_id"] as? String == "source")
        #expect(object["expected_nonce"] as? String == "old-nonce")
        #expect(object["sandbox_id"] as? String == "fork")
        #expect(object["identity_nonce"] as? String == "new-nonce")
        #expect(object["hostname"] as? String == "strato-fork")
        #expect(object["entropy"] as? String == entropy.base64EncodedString())
        #expect((object["unix_nanos"] as? NSNumber)?.int64Value == 1_752_700_000_000_000_000)
        // A network-free fork sends no block, exactly as before STR-104.
        #expect(object["network"] == nil)
    }

    /// The fork target's address rides the request that rotates its identity,
    /// so the guest never runs a moment holding the source's (STR-104).
    @Test("reidentify carries the fork target's NIC configuration")
    func reidentifyCarriesNetwork() throws {
        let request = GuestControlProtocol.ReidentifyRequest(
            expectedSandboxId: "source",
            expectedNonce: "old-nonce",
            sandboxId: "fork",
            identityNonce: "new-nonce",
            hostname: "strato-fork",
            entropy: Data(repeating: 0xA5, count: 32),
            unixNanos: 1_752_700_000_000_000_000,
            network: SandboxConfigDrive.NetworkConfig(
                macAddress: "06:00:ac:10:00:09",
                ipv6: SandboxConfigDrive.AddressConfig(
                    address: "fd12:3456:789a::9", prefixLength: 64,
                    gateway: "fd12:3456:789a::1")))

        let object = try decodedObject(.reidentify(request))
        let network = try #require(object["network"] as? [String: Any])
        #expect(network["mac_address"] as? String == "06:00:ac:10:00:09")
        let ipv6 = try #require(network["ipv6"] as? [String: Any])
        #expect(ipv6["address"] as? String == "fd12:3456:789a::9")
        #expect(ipv6["prefix_length"] as? Int == 64)
        #expect(network["ipv4"] == nil)
    }

    @Test("reidentified decodes")
    func reidentifiedDecodes() throws {
        let response = try GuestControlProtocol.Response.decode(line: #"{"type":"reidentified"}"#)
        #expect(response == .reidentified)
    }

    @Test("held workload state decodes in a status response")
    func heldStateDecodes() throws {
        let response = try GuestControlProtocol.Response.decode(
            line: #"{"type":"status","sandbox_id":"tpl","nonce":"n","state":"held"}"#)
        let expected = GuestControlProtocol.Response.status(
            sandboxId: "tpl", nonce: "n", state: .held, exitCode: nil)
        #expect(response == expected)
    }

    @Test("SandboxExecRequest maps onto the guest exec request field by field")
    func execRequestBridgesToGuestRequest() {
        let request = SandboxExecRequest(
            command: ["/bin/sh"], env: ["A": "1"], workingDir: "/srv", tty: true, rows: 40, cols: 120)
        let guest = request.guestRequest
        #expect(guest.argv == ["/bin/sh"])
        #expect(guest.env == ["A": "1"])
        #expect(guest.cwd == "/srv")
        #expect(guest.tty == true)
        #expect(guest.rows == 40)
        #expect(guest.cols == 120)
    }

    // MARK: - Response decoding (v1 surface, unchanged)

    @Test("pong and status still decode")
    func v1ResponsesDecode() throws {
        let pong = try GuestControlProtocol.Response.decode(
            line: #"{"type":"pong","sandbox_id":"sb-1","nonce":"n-1"}"#)
        #expect(
            pong
                == .pong(
                    sandboxId: "sb-1", nonce: "n-1", controlProtocolVersion: nil))

        let versionedPong = try GuestControlProtocol.Response.decode(
            line:
                #"{"type":"pong","sandbox_id":"sb-1","nonce":"n-1","control_protocol_version":3}"#
        )
        #expect(
            versionedPong
                == .pong(
                    sandboxId: "sb-1", nonce: "n-1", controlProtocolVersion: 3))

        let running = try GuestControlProtocol.Response.decode(
            line: #"{"type":"status","sandbox_id":"sb-1","nonce":"n-1","state":"running"}"#)
        let expectedRunning = GuestControlProtocol.Response.status(
            sandboxId: "sb-1", nonce: "n-1", state: .running, exitCode: nil)
        #expect(running == expectedRunning)

        let exited = try GuestControlProtocol.Response.decode(
            line: #"{"type":"status","sandbox_id":"sb-1","nonce":"n-1","state":"exited","exit_code":3}"#)
        let expectedExited = GuestControlProtocol.Response.status(
            sandboxId: "sb-1", nonce: "n-1", state: .exited, exitCode: 3)
        #expect(exited == expectedExited)

        let error = try GuestControlProtocol.Response.decode(line: #"{"type":"error","message":"boom"}"#)
        #expect(error == .error(message: "boom"))
    }

    // MARK: - Response decoding (v2 surface)

    @Test("exec_started decodes")
    func execStartedDecodes() throws {
        let response = try GuestControlProtocol.Response.decode(line: #"{"type":"exec_started"}"#)
        #expect(response == .execStarted)
    }

    @Test("output decodes its stream and base64 payload")
    func outputDecodes() throws {
        let payload = Data("hello\n".utf8)
        let line = #"{"type":"output","stream":"stderr","data":"\#(payload.base64EncodedString())"}"#
        let response = try GuestControlProtocol.Response.decode(line: line)
        #expect(response == .output(stream: "stderr", data: payload))
    }

    @Test("output with missing or invalid base64 data is malformed")
    func outputRejectsBadData() {
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"output","stream":"stdout"}"#)
        }
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(
                line: #"{"type":"output","stream":"stdout","data":"%%%not-base64%%%"}"#)
        }
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"output","data":"aGk="}"#)
        }
    }

    @Test("exec_exit decodes its exit code and requires one")
    func execExitDecodes() throws {
        let response = try GuestControlProtocol.Response.decode(line: #"{"type":"exec_exit","exit_code":137}"#)
        #expect(response == .execExit(exitCode: 137))

        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"exec_exit"}"#)
        }
    }

    @Test("log decodes seq, stream, and payload — and requires all three")
    func logDecodes() throws {
        let payload = Data("a line".utf8)
        let line = #"{"type":"log","seq":18,"stream":"stdout","data":"\#(payload.base64EncodedString())"}"#
        let response = try GuestControlProtocol.Response.decode(line: line)
        #expect(response == .log(seq: 18, stream: "stdout", data: payload))

        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"log","stream":"stdout","data":"aGk="}"#)
        }
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"log","seq":1,"data":"aGk="}"#)
        }
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"log","seq":1,"stream":"stdout"}"#)
        }
    }

    @Test("log_eof decodes as the log stream's terminal marker")
    func logEofDecodes() throws {
        let response = try GuestControlProtocol.Response.decode(line: #"{"type":"log_eof"}"#)
        #expect(response == .logEof)
    }

    @Test("a trailing newline on a response line is tolerated")
    func trailingNewlineTolerated() throws {
        let response = try GuestControlProtocol.Response.decode(line: "{\"type\":\"exec_started\"}\n")
        #expect(response == .execStarted)
    }

    @Test("unknown response types are malformed")
    func unknownTypeRejected() {
        #expect(throws: GuestControlError.self) {
            try GuestControlProtocol.Response.decode(line: #"{"type":"mystery"}"#)
        }
    }
}
