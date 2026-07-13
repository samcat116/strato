/**
 * Human-readable memory size from a raw byte count. The sandbox API returns
 * memory in bytes (unlike the VM DTO, which ships a preformatted string), so the
 * UI formats it client-side.
 */
export function formatMemory(bytes: number): string {
  const gb = bytes / 1024 ** 3;
  if (gb >= 1) {
    return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
  }
  const mb = bytes / 1024 ** 2;
  return `${Math.round(mb)} MB`;
}
