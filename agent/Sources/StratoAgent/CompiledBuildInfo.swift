/// Build identity compiled into the binary itself, for installs where the
/// image-level `STRATO_VERSION` / `STRATO_GIT_SHA` environment variables
/// don't exist — the bare binaries shipped in the release tarballs. The
/// release workflow overwrites this file with the release tag and commit SHA
/// before compiling (see `.github/workflows/release.yaml`); the checked-in
/// values stay nil so every other build reports `BuildInfo`'s "dev"/"unknown"
/// fallbacks.
enum CompiledBuildInfo {
    static let version: String? = nil
    static let gitSHA: String? = nil
}
