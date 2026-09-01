import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ApiError } from "@/lib/api/client";
import { sitesApi } from "@/lib/api/sites";
import type {
  ConfigureCephProjectAccessRequest,
  RegisterCephClusterRequest,
  UpdateCephClusterRequest,
} from "@/types/api";

async function absentOn404<T>(request: Promise<T>): Promise<T | null> {
  try {
    return await request;
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null;
    throw error;
  }
}

export function useCephCluster(siteId: string | undefined, enabled = true) {
  return useQuery({
    queryKey: ["sites", siteId, "ceph-cluster"],
    queryFn: ({ signal }) =>
      siteId
        ? absentOn404(sitesApi.getCephCluster(siteId, signal))
        : Promise.resolve(null),
    enabled: !!siteId && enabled,
  });
}

export function useRegisterCephCluster(siteId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: RegisterCephClusterRequest) =>
      sitesApi.registerCephCluster(siteId, data),
    onSuccess: (cluster) =>
      queryClient.setQueryData(["sites", siteId, "ceph-cluster"], cluster),
  });
}

export function useUpdateCephCluster(siteId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: UpdateCephClusterRequest) =>
      sitesApi.updateCephCluster(siteId, data),
    onSuccess: (cluster) =>
      queryClient.setQueryData(["sites", siteId, "ceph-cluster"], cluster),
  });
}

export function useDeleteCephCluster(siteId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => sitesApi.deleteCephCluster(siteId),
    onSuccess: () => {
      queryClient.setQueryData(["sites", siteId, "ceph-cluster"], null);
      queryClient.invalidateQueries({ queryKey: ["storage-pools"] });
    },
  });
}

export function useCephProjectAccess(
  siteId: string | undefined,
  projectId: string | undefined,
  enabled = true
) {
  return useQuery({
    queryKey: ["sites", siteId, "ceph-cluster", "projects", projectId],
    queryFn: ({ signal }) =>
      siteId && projectId
        ? absentOn404(sitesApi.getCephProjectAccess(siteId, projectId, signal))
        : Promise.resolve(null),
    enabled: !!siteId && !!projectId && enabled,
  });
}

export function useConfigureCephProjectAccess(
  siteId: string,
  projectId: string
) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: ConfigureCephProjectAccessRequest) =>
      sitesApi.configureCephProjectAccess(siteId, projectId, data),
    onSuccess: (access) => {
      queryClient.setQueryData(
        ["sites", siteId, "ceph-cluster", "projects", projectId],
        access
      );
      queryClient.invalidateQueries({ queryKey: ["storage-pools", projectId] });
    },
  });
}

export function useDeleteCephProjectAccess(siteId: string, projectId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (cephxRevoked: boolean) =>
      sitesApi.deleteCephProjectAccess(siteId, projectId, cephxRevoked),
    onSuccess: () => {
      queryClient.setQueryData(
        ["sites", siteId, "ceph-cluster", "projects", projectId],
        null
      );
      queryClient.invalidateQueries({ queryKey: ["storage-pools", projectId] });
    },
  });
}

export function useProjectStoragePools(projectId: string | undefined) {
  return useQuery({
    queryKey: ["storage-pools", projectId],
    queryFn: ({ signal }) =>
      projectId
        ? sitesApi.listProjectStoragePools(projectId, signal)
        : Promise.resolve([]),
    enabled: !!projectId,
  });
}
