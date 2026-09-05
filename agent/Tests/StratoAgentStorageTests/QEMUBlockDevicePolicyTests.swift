import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("QEMU block-device policy selection")
struct QEMUBlockDevicePolicyTests {
    private let capable = StorageBlockDeviceCapabilities(
        discardSupported: true, directIOSupported: true)

    @Test("direct mode selects the probed direct path")
    func direct() {
        let policy = QEMUBlockDevicePolicy.select(
            requestedMode: .direct, vCPUCount: 8, capabilities: capable)
        #expect(policy.cacheMode == BlockDeviceCacheMode.none)
        #expect(policy.ioMode == .ioUring)
        #expect(policy.discard)
        #expect(!policy.nonRotational)
        #expect(policy.queueCount == 8)
        #expect(policy.fallbackReason?.contains("libvirt cannot express rotation_rate") == true)
    }

    @Test("a failed direct probe falls back without claiming support")
    func directFallback() {
        let policy = QEMUBlockDevicePolicy.select(
            requestedMode: .direct,
            vCPUCount: 4,
            capabilities: StorageBlockDeviceCapabilities(
                discardSupported: false,
                discardUnavailableReason: "hole punching is unavailable",
                directIOSupported: false,
                directIOUnavailableReason: "io_uring is disabled by the kernel"))
        #expect(policy.cacheMode == nil)
        #expect(policy.ioMode == nil)
        #expect(!policy.discard)
        #expect(!policy.nonRotational)
        #expect(policy.queueCount == 4)
        #expect(policy.fallbackReason?.contains("hole punching") == true)
        #expect(policy.fallbackReason?.contains("io_uring is disabled") == true)
    }

    @Test("cached shared mode is explicit and keeps discard independent")
    func cachedShared() {
        let policy = QEMUBlockDevicePolicy.select(
            requestedMode: .cachedShared, vCPUCount: 2, capabilities: capable)
        #expect(policy.cacheMode == .writeback)
        #expect(policy.ioMode == nil)
        #expect(policy.discard)
        #expect(!policy.nonRotational)
        #expect(policy.fallbackReason?.contains("libvirt cannot express rotation_rate") == true)
    }

    @Test("queue count follows vCPUs within validated limits")
    func queueBounds() {
        #expect(
            QEMUBlockDevicePolicy.select(
                requestedMode: .conservative, vCPUCount: 0, capabilities: capable
            ).queueCount == 1)
        #expect(
            QEMUBlockDevicePolicy.select(
                requestedMode: .conservative, vCPUCount: 1024, capabilities: capable
            ).queueCount == QEMUBlockDevicePolicy.maximumQueueCount)
    }
}
