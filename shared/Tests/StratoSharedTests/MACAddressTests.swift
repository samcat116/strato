import Testing

@testable import StratoShared

@Suite("MAC address")
struct MACAddressTests {
    @Test("Parses and canonicalizes six colon-separated octets")
    func canonicalizes() throws {
        let address = try #require(MACAddress("02:0C:29:0A:bB:fF"))

        #expect(address.description == "02:0c:29:0a:bb:ff")
        #expect(address.isLocallyAdministered)
        #expect(MACAddress(address.description) == address)
    }

    @Test(
        "Rejects malformed, zero, multicast, and broadcast addresses",
        arguments: [
            "", "02:00:00:00:00", "02-00-00-00-00-01", "2:00:00:00:00:01",
            "02:00:00:00:00:gg", "02:+1:00:00:00:01", "02:-1:00:00:00:01",
            "00:00:00:00:00:00", "01:00:5e:00:00:01", "ff:ff:ff:ff:ff:ff",
        ])
    func rejectsInvalid(_ string: String) {
        #expect(MACAddress(string) == nil)
    }

    @Test("Allocation parsing requires the locally administered bit")
    func allocationRequiresLocalAddress() {
        #expect(MACAddress("00:0c:29:12:34:56") != nil)
        #expect(MACAddress(allocated: "00:0c:29:12:34:56") == nil)
        #expect(MACAddress(allocated: "02:0c:29:12:34:56") != nil)
    }
}
