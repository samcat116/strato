import Testing

@testable import StratoAgentCore

/// The Firecracker version gate behind snapshot network remapping (STR-104).
///
/// Getting this wrong in either direction is expensive: too permissive and a
/// pre-1.12 VMM rejects the whole `PUT /snapshot/load` body over an unknown
/// key, failing a restore that would otherwise have worked; too strict and
/// networked forks and warm starts silently stop happening.
@Suite("Firecracker Snapshot Feature Gates")
struct FirecrackerSnapshotFeaturesTests {

    @Test("network_overrides needs Firecracker 1.12 or newer")
    func networkOverridesVersionGate() {
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.7.0"))
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.11.0"))
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.11.9"))
        #expect(FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.12.0"))
        #expect(FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.12.1"))
        #expect(FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.13.0"))
        #expect(FirecrackerSnapshotFeatures.supportsNetworkOverrides("2.0.0"))
    }

    /// A host nobody could identify is not capable. Assuming the feature and
    /// being wrong fails the load; assuming its absence costs a fork a host.
    @Test("an unknown or unreadable version is never capable")
    func unknownVersionIsNotCapable() {
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides(nil))
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides(""))
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides("unknown"))
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides("v1.12.0"))
    }

    /// `firecracker --version` on a development build prints a suffixed
    /// patch component; the feature is in the release it derives from.
    @Test("a pre-release suffix does not demote the version")
    func prereleaseSuffixesCompareByTheirNumbers() {
        #expect(FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.12.0-dev"))
        #expect(!FirecrackerSnapshotFeatures.supportsNetworkOverrides("1.11.0-dev"))
    }

    @Test("components compare numerically, not lexically")
    func componentsCompareNumerically() {
        // The whole point: "1.9.0" > "1.12.0" as strings, and must not be here.
        #expect(FirecrackerSnapshotFeatures.compare("1.9.0", "1.12.0") == .orderedAscending)
        #expect(FirecrackerSnapshotFeatures.compare("1.12.0", "1.12") == .orderedSame)
        #expect(FirecrackerSnapshotFeatures.compare("1.12.0", "1.12.0") == .orderedSame)
        #expect(FirecrackerSnapshotFeatures.compare("1.12.1", "1.12.0") == .orderedDescending)
    }
}
