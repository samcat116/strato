import Foundation
import Testing
import StratoShared

@Suite("Enum wire values and version-skew tolerance")
struct EnumDecodingTests {
    // MARK: VMStatus — the one enum with a tolerant fallback

    @Test(arguments: VMStatus.allCases)
    func vmStatusRoundTrips(status: VMStatus) throws {
        #expect(try roundTrip([status]) == [status])
    }

    @Test func vmStatusWireStringsAreCapitalized() {
        #expect(VMStatus.created.rawValue == "Created")
        #expect(VMStatus.running.rawValue == "Running")
        #expect(VMStatus.shutdown.rawValue == "Shutdown")
        #expect(VMStatus.paused.rawValue == "Paused")
        #expect(VMStatus.starting.rawValue == "Starting")
        #expect(VMStatus.stopping.rawValue == "Stopping")
        #expect(VMStatus.error.rawValue == "Error")
        #expect(VMStatus.unknown.rawValue == "Unknown")
    }

    @Test("unrecognized status decodes to .unknown, not an error")
    func vmStatusToleratesUnknownValues() throws {
        #expect(try decodeJSON([VMStatus].self, from: #"["Hibernated"]"#) == [.unknown])
        // Tolerance is case-sensitive: lowercase variants of real states are
        // unrecognized too, and must land on .unknown rather than throw.
        #expect(try decodeJSON([VMStatus].self, from: #"["running"]"#) == [.unknown])
        #expect(try decodeJSON([VMStatus].self, from: #"[""]"#) == [.unknown])
    }

    // MARK: Enums without a fallback — unknown values are a decode error

    @Test func hypervisorTypeRoundTripsAndRejectsUnknown() throws {
        #expect(HypervisorType.qemu.rawValue == "qemu")
        #expect(HypervisorType.firecracker.rawValue == "firecracker")
        for type in HypervisorType.allCases {
            #expect(try roundTrip([type]) == [type])
        }
        // No tolerant fallback: an agent advertising a hypervisor this build
        // doesn't know fails registration decode outright.
        #expect(throws: DecodingError.self) {
            try decodeJSON([HypervisorType].self, from: #"["cloud-hypervisor"]"#)
        }
    }

    @Test func consoleModeRoundTripsAndRejectsUnknown() throws {
        #expect(ConsoleMode.off.rawValue == "Off")
        #expect(ConsoleMode.pty.rawValue == "Pty")
        #expect(ConsoleMode.tty.rawValue == "Tty")
        #expect(ConsoleMode.file.rawValue == "File")
        #expect(ConsoleMode.socket.rawValue == "Socket")
        #expect(ConsoleMode.null.rawValue == "Null")
        for mode in ConsoleMode.allCases {
            #expect(try roundTrip([mode]) == [mode])
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON([ConsoleMode].self, from: #"["Vnc"]"#)
        }
    }

    @Test func vmLogEnumsRoundTrip() throws {
        #expect(VMLogLevel.debug.rawValue == "debug")
        #expect(VMLogLevel.info.rawValue == "info")
        #expect(VMLogLevel.warning.rawValue == "warning")
        #expect(VMLogLevel.error.rawValue == "error")

        #expect(VMLogSource.agent.rawValue == "agent")
        #expect(VMLogSource.qemu.rawValue == "qemu")
        #expect(VMLogSource.controlPlane.rawValue == "control_plane")

        #expect(VMEventType.statusChange.rawValue == "status_change")
        #expect(VMEventType.operation.rawValue == "operation")
        #expect(VMEventType.qemuOutput.rawValue == "qemu_output")
        #expect(VMEventType.error.rawValue == "error")
        #expect(VMEventType.info.rawValue == "info")

        let levels: [VMLogLevel] = [.debug, .info, .warning, .error]
        #expect(try roundTrip(levels) == levels)
        let sources: [VMLogSource] = [.agent, .qemu, .controlPlane]
        #expect(try roundTrip(sources) == sources)
        let events: [VMEventType] = [.statusChange, .operation, .qemuOutput, .error, .info]
        #expect(try roundTrip(events) == events)
    }

    @Test func networkEnumsRoundTrip() throws {
        for status in NetworkPortStatus.allCases {
            #expect(try roundTrip([status]) == [status])
        }
        for status in NetworkStatus.allCases {
            #expect(try roundTrip([status]) == [status])
        }
    }
}

@Suite("HypervisorCapabilities")
struct HypervisorCapabilitiesTests {
    @Test func roundTripPreservesAllFields() throws {
        let capabilities = HypervisorCapabilities(
            type: .firecracker,
            supportsPause: true,
            supportsLiveMigration: false,
            supportsSnapshots: true,
            requiresDirectKernelBoot: true,
            maxVCPUs: 32,
            maxMemory: 34_359_738_368
        )
        let decoded = try roundTrip(capabilities)
        #expect(decoded.type == .firecracker)
        #expect(decoded.supportsPause)
        #expect(!decoded.supportsLiveMigration)
        #expect(decoded.supportsSnapshots)
        #expect(decoded.requiresDirectKernelBoot)
        #expect(decoded.maxVCPUs == 32)
        #expect(decoded.maxMemory == 34_359_738_368)
    }

    @Test func builtinPresetsRoundTrip() throws {
        let qemu = try roundTrip(HypervisorCapabilities.qemu)
        #expect(qemu.type == .qemu)
        #expect(qemu.maxMemory == HypervisorCapabilities.qemu.maxMemory)
        let firecracker = try roundTrip(HypervisorCapabilities.firecracker)
        #expect(firecracker.type == .firecracker)
        #expect(firecracker.requiresDirectKernelBoot)
    }
}
