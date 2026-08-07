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
  const gib = bytes / 1024 ** 3;
  if (gib >= 1) {
    return `${Number.isInteger(gib) ? gib : gib.toFixed(1)} GiB`;
  }
  const mib = bytes / 1024 ** 2;
  return `${Math.round(mib)} MiB`;
}
