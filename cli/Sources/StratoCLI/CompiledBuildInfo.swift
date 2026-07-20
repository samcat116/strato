/// Placeholder overwritten by CI at release-build time (see
/// .github/workflows/release.yaml). Local builds keep the nil stub.
enum CompiledBuildInfo {
    static let version: String? = nil
    static let gitSHA: String? = nil
}
