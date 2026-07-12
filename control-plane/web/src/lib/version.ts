// Build identity for the running UI, baked in at build time by next.config.ts.
//
// `NEXT_PUBLIC_APP_VERSION` carries STRATO_VERSION — a real release tag (e.g.
// "v1.2.3") for tagged builds, or a rolling sentinel ("dev", "main", ...) for
// untagged ones. `NEXT_PUBLIC_GIT_SHA` carries the short commit hash. When the
// build isn't a tagged release we show the git hash instead, per the convention
// that a rolling build is identified by its commit.

const rawVersion = (process.env.NEXT_PUBLIC_APP_VERSION ?? "").trim();
const rawSHA = (process.env.NEXT_PUBLIC_GIT_SHA ?? "").trim();

// Sentinels that mean "not a tagged release" rather than a real version string.
const ROLLING_SENTINELS = new Set(["", "dev", "main", "local", "latest"]);

function isReleaseTag(version: string): boolean {
  if (ROLLING_SENTINELS.has(version.toLowerCase())) return false;
  // Rolling image tags like "main-abc1234" are not releases either.
  if (/^main-[0-9a-f]{7,40}$/i.test(version)) return false;
  return true;
}

const shortSHA = rawSHA ? rawSHA.slice(0, 7) : "";

/** Short label for the UI (e.g. "v1.2.3", "a1b2c3d", or "dev"). */
export const versionLabel: string = isReleaseTag(rawVersion)
  ? rawVersion
  : shortSHA || rawVersion || "dev";

/** Fuller identity for a tooltip: version + commit when both are known. */
export const versionTitle: string = [
  rawVersion && `version ${rawVersion}`,
  rawSHA && `commit ${rawSHA}`,
]
  .filter(Boolean)
  .join(" · ");
