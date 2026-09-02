public enum FNV1a {
    public static func hash64(_ input: some StringProtocol) -> UInt64 {
        hash64(input, offsetBasis: 0xcbf2_9ce4_8422_2325)
    }

    /// Preserves the non-standard offset basis used by Strato's DHCP server
    /// identities and DNS serials before their FNV implementations were
    /// consolidated. Those derived values are externally observed, so changing
    /// the seed during helper extraction would change unchanged resources.
    static func legacyStratoHash64(_ input: some StringProtocol) -> UInt64 {
        hash64(input, offsetBasis: 0x1465_0fb0_739d_0383)
    }

    private static func hash64(_ input: some StringProtocol, offsetBasis: UInt64) -> UInt64 {
        var hash = offsetBasis
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
