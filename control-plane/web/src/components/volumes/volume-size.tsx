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
 *
 * Only a *grow* gets the arrow. A volume larger than its requested size is the
 * ordinary result of a clone or image-backed create inheriting its source's
 * size, and a shrink is refused permanently at both ends — neither is a pending
 * change, so neither should be drawn as one about to land.
 */
export function VolumeSize({ volume }: { volume: Volume }) {
  const observed = volume.observedSizeFormatted;
  if (observed == null || volume.observedSize == null) {
    return <>{volume.sizeFormatted}</>;
  }

  if (volume.observedSize < volume.size) {
    return (
      <span title={`Resize to ${volume.sizeFormatted} has not been applied yet`}>
        {observed}
        <span className="text-muted-foreground"> → {volume.sizeFormatted}</span>
      </span>
    );
  }

  return <>{observed}</>;
}
