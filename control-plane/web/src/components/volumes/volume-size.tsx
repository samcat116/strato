import type { Volume } from "@/types/api";

/**
 * A volume's size, showing what is actually on disk when that differs from what
 * was asked for (backend STR-199).
 *
 * A resize is accepted and then converges, so `size` moves immediately while
 * the image may not move for a long time — a grow against a running guest is
 * refused until the guest stops. Rendering `size` alone is how a grow that
 * never happened reads as one that did, so an outstanding grow shows as
 * `1 GiB → 3 GiB` instead.
 */
export function VolumeSize({ volume }: { volume: Volume }) {
  const outstanding =
    volume.observedSize !== undefined &&
    volume.observedSizeFormatted !== undefined &&
    volume.observedSize !== volume.size;

  if (!outstanding) {
    return <>{volume.sizeFormatted}</>;
  }

  return (
    <span title={`Resize to ${volume.sizeFormatted} has not been applied yet`}>
      {volume.observedSizeFormatted}
      <span className="text-muted-foreground"> → {volume.sizeFormatted}</span>
    </span>
  );
}
