import Foundation
import Testing
@testable import StratoShared

@Suite("Hypervisor memory bounds")
struct HypervisorMemoryTests {
    @Test("Apple memory bounds are inclusive and require MiB alignment")
    func bounds() throws {
        let support = HypervisorSupport(
            type: .appleVirtualization, available: true, accelerated: true,
            minimumMemoryBytes: 512 << 20, maximumMemoryBytes: 2048 << 20)
        #expect(support.supportsMemorySize(512 << 20))
        #expect(support.supportsMemorySize(2048 << 20))
        for bytes in [Int64(0), Int64(511 << 20), Int64((512 << 20) + 1), Int64(2049 << 20)] {
            #expect(!support.supportsMemorySize(bytes))
        }
        #expect(try JSONDecoder().decode(HypervisorSupport.self, from: JSONEncoder().encode(support)) == support)
    }

    @Test("Older reports decode but cannot promise Apple memory support")
    func legacyReport() throws {
        let data = Data(#"{"type":"apple_virtualization","available":true,"accelerated":true}"#.utf8)
        let report = try JSONDecoder().decode(HypervisorSupport.self, from: data)
        #expect(report.minimumMemoryBytes == nil)
        #expect(!report.supportsMemorySize(512 << 20))
        #expect(HypervisorSupport(type: .qemu, available: true, accelerated: true).supportsMemorySize(1))
    }
}
