import { useQueries, useQuery, useQueryClient } from "@tanstack/react-query";
import { volumesApi } from "@/lib/api/volumes";
import type { Volume } from "@/types/api";

export function useVolumes(projectId?: string) {
  return useQuery({
    queryKey: ["volumes", { projectId: projectId ?? null }],
    queryFn: () => volumesApi.list(projectId),
    // Poll so async transitions (creating, cloning, deleting) resolve in the UI
    refetchInterval: 5000,
  });
}

export function useVolume(id: string) {
  return useQuery({
    queryKey: ["volumes", id],
    queryFn: () => volumesApi.get(id),
    enabled: !!id,
  });
}

export function useVolumeSnapshots(volumeId: string) {
  return useQuery({
    queryKey: ["volumes", volumeId, "snapshots"],
    queryFn: () => volumesApi.listSnapshots(volumeId),
    enabled: !!volumeId,
    refetchInterval: 5000,
  });
}

/**
 * Aggregates snapshots across many volumes. The backend only exposes
 * per-volume snapshot listing, so the global snapshots page fans out one
 * query per volume and flattens the results.
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

export function useInvalidateVolumes() {
  const queryClient = useQueryClient();
  // Prefix match also invalidates per-volume and snapshot queries
  return () => queryClient.invalidateQueries({ queryKey: ["volumes"] });
}
