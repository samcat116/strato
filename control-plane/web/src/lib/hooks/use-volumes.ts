import { volumesApi } from "@/lib/api/volumes";
import { useQuery, useQueryClient } from "@tanstack/react-query";
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

export function useProjectVolumeSnapshots(projectId?: string) {
  return useQuery({
    queryKey: ["volume-snapshots", { projectId }],
    queryFn: ({ signal }) => volumesApi.listProjectSnapshots(projectId!, signal),
    enabled: !!projectId,
    refetchInterval: 5000,
  });
}

export function useInvalidateVolumes() {
  const invalidateVolumes = hooks.useInvalidate();
  const queryClient = useQueryClient();

  return () => {
    invalidateVolumes();
    queryClient.invalidateQueries({ queryKey: ["volume-snapshots"] });
  };
}
