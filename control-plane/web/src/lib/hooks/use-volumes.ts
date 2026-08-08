import { useQueries } from "@tanstack/react-query";
import { volumesApi } from "@/lib/api/volumes";
import type { Volume } from "@/types/api";
import { makeResourceQueryHooks } from "./use-resource-queries";

const hooks = makeResourceQueryHooks({
  queryKey: "volumes",
  scopeKey: "projectId",
  list: (projectId) => volumesApi.list(projectId),
  get: (id) => volumesApi.get(id),
  listSnapshots: (id) => volumesApi.listSnapshots(id),
  // Still polled, but as a backstop rather than the mechanism: since backend
  // STR-148 a volume's own mutations are followed by MutationWatcher off its
  // `conditions`, and this only has to catch changes nothing in this tab
  // requested (another operator's, or an agent reporting drift).
  listRefetchInterval: 10000,
});

export function useVolumes(projectId?: string) {
  return hooks.useList(projectId);
}

/**
 * Aggregates snapshots across many volumes. The backend only exposes
 * per-volume snapshot listing, so the global snapshots page fans out one
 * query per volume and flattens the results. (The per-volume keys match the
 * factory's `useSnapshots` keys, so invalidation covers both.)
 */
export function useSnapshotsForVolumes(volumes: Volume[]) {
  return useQueries({
    queries: volumes
      .filter((v) => v.id)
      .map((v) => ({
        queryKey: ["volumes", v.id!, "snapshots"],
        queryFn: () => volumesApi.listSnapshots(v.id!),
        refetchInterval: 5000,
      })),
    combine: (results) => ({
      data: results.flatMap((r) => r.data ?? []),
      isLoading: results.some((r) => r.isLoading),
    }),
  });
}

export const useInvalidateVolumes = hooks.useInvalidate;
