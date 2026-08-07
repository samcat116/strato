/**
 * Human-readable memory size from a raw byte count. Shared by the sandbox
 * memory allocation and by the VM/sandbox checkpoint lists, whose captured
 * machine state is also memory measured in bytes (the VM DTO ships a
 * preformatted string for its own configured memory; snapshots do not).
 *
 * Separate from the dashboard's `formatBytes`, which rounds to whole GiB: a
 * checkpoint's state is often hundreds of mebibytes, and rounding that to
 * "0 GiB" would read as empty. Binary units, labelled as such — the divisor
 * is 1024.
 */
export function formatMemory(bytes: number): string {
  // A shared util has callers it can't see, so it refuses garbage rather than
  // rendering "NaN MiB" — same stance as `formatDuration`'s opening guard.
  if (!Number.isFinite(bytes) || bytes < 0) return "—";

  // Round to mebibytes *before* choosing the unit: a value just under 1 GiB
  // would otherwise fail the GiB test and then round up to "1024 MiB".
  const mib = Math.round(bytes / 1024 ** 2);
  if (mib >= 1024) {
    const gib = bytes / 1024 ** 3;
    return `${Number.isInteger(gib) ? gib : gib.toFixed(1)} GiB`;
  }
  return `${mib} MiB`;
}
