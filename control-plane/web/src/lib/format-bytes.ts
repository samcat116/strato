/**
 * The UI's byte-count formatters (issue #1007).
 *
 * Every size Strato reports — VM and sandbox memory, checkpoint state, disks,
 * host RAM, image artifacts — is a binary quantity, so every formatter here
 * divides by 1024 and labels the result as such. Before this file the codebase
 * had six near-copies that all divided by 1024 while labelling the result
 * `GB`/`MB`/`TB`, naming decimal units for binary math.
 *
 * Two functions, because two surfaces genuinely want different precision:
 *
 * - `formatMemory` — a single resource's size, where the tail digit carries
 *   information (a 1.4 GiB checkpoint, a 512 MiB sandbox).
 * - `formatCapacity` — a host or fleet aggregate, where whole units read
 *   better on a stat tile ("128 GiB", not "127.9 GiB").
 *
 * `formatMemory` is also mirrored server-side by `Int64.formattedByteSize`
 * (`control-plane/Sources/App/Extensions/ByteConversion.swift`), which produces
 * the preformatted `memoryFormatted`/`sizeFormatted` DTO fields. Keep the two
 * in step: the VM detail page renders the server's string for configured
 * memory directly above a snapshots card this file formats, and they should
 * not read as two different unit systems. The parity the design rests on,
 * which no test can assert because the two live in different languages:
 *
 *     bytes           formatMemory / formattedByteSize   formatCapacity
 *     1023            1023 B                             1023 B
 *     536870912       512 MiB                            1 GiB
 *     1073741823      1 GiB                              1 GiB
 *     1503238553      1.4 GiB                            1 GiB
 *     4294967296      4 GiB                              4 GiB
 *     1099511627776   1 TiB                              1 TiB
 *     1649267441664   1.5 TiB                            1.5 TiB
 *
 * The two diverge only on degenerate input: this file renders `—`, because
 * JSON can hand it a `NaN` or an `undefined`, while the server's copy — which
 * the CLI prints verbatim into a table cell — clamps to `0 B` so the wire
 * field is always a size.
 */

const KIB = 1024;
const MIB = 1024 ** 2;
const GIB = 1024 ** 3;
const TIB = 1024 ** 4;

/** One decimal place, then dropped entirely when the value lands whole. */
function decimal(value: number): string {
  const rounded = Number(value.toFixed(1));
  return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1);
}

/**
 * Human-readable size of one resource, keeping a decimal in the large units.
 *
 * Used for sandbox memory, VM/sandbox checkpoint state, image defaults, and
 * image artifacts.
 */
export function formatMemory(bytes: number): string {
  // A shared util has callers it can't see, so it refuses garbage rather than
  // rendering "NaN MiB" — same stance as `formatDuration`'s opening guard.
  if (!Number.isFinite(bytes) || bytes < 0) return "—";

  // Each tier rounds *before* the next unit's test, so a value just under the
  // boundary can't both fail the larger unit and round up to "1024 MiB".
  if (bytes < KIB) return `${Math.round(bytes)} B`;
  const kib = Math.round(bytes / KIB);
  if (kib < 1024) return `${kib} KiB`;
  const mib = Math.round(bytes / MIB);
  if (mib < 1024) return `${mib} MiB`;
  const gib = Number((bytes / GIB).toFixed(1));
  if (gib < 1024) return `${decimal(gib)} GiB`;
  return `${decimal(bytes / TIB)} TiB`;
}

/**
 * Human-readable size of a host or fleet total, rounded to whole gibibytes.
 *
 * Used for the dashboard capacity tiles and the agent host/disk figures. When
 * the whole-gibibyte rounding would land on zero it falls through to
 * `formatMemory`, so a small aggregate — an agent whose guests are using
 * 300 MiB, say — reads as itself rather than as "0 GiB".
 *
 * The rounding is deliberate even where the same quantity is shown with a
 * decimal elsewhere: the agent detail page's guest-memory total reads `1 GiB`
 * here while the VM detail page's `guestMemoryUsedFormatted` reads `1.4 GiB`
 * for one VM's share of it. An aggregate's tail digit is noise. Don't
 * "fix" this into `formatMemory`.
 */
export function formatCapacity(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";

  const gib = Math.round(bytes / GIB);
  if (gib >= 1024) return `${decimal(bytes / TIB)} TiB`;
  if (gib >= 1) return `${gib} GiB`;
  return formatMemory(bytes);
}
