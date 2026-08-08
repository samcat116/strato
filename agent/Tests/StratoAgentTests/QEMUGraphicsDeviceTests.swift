import Testing

@testable import StratoAgentCore

/// What is left of the graphics console (issue #566) once libvirt writes the
/// `<graphics>`, `<video>` and `<input>` elements itself (STR-136): a socket
/// path two callers have to derive identically. The device shapes those
/// arguments used to assert now live in `DomainXMLBuilderTests`.
@Suite("QEMU graphics device")
struct QEMUGraphicsDeviceTests {

    /// The path the domain document binds and the path the agent later
    /// reconnects to for a re-adopted VM are the same derivation, so they cannot
    /// drift.
    @Test("the socket path is derived from the VM directory")
    func socketPathIsDeterministic() {
        #expect(
            QEMUGraphicsDevice.socketPath(vmDirectory: "/var/lib/strato/vms/abc") == "/var/lib/strato/vms/abc/vnc.sock")
    }
}
