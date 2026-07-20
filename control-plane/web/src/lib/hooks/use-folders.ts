import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { foldersApi } from "@/lib/api/folders";
import { ApiError } from "@/lib/api/client";
import type { CreateFolderRequest, UpdateFolderRequest } from "@/types/api";

export function useFolders(orgId: string) {
  return useQuery({
    queryKey: ["folders", orgId],
    queryFn: () => foldersApi.list(orgId),
    enabled: !!orgId,
  });
}

export function useFolderTree(orgId: string, ouId: string | undefined) {
  return useQuery({
    queryKey: ["folder-tree", orgId, ouId],
    queryFn: () =>
      ouId ? foldersApi.tree(orgId, ouId) : Promise.reject("No folder ID"),
    enabled: !!orgId && !!ouId,
  });
}

export function useCreateFolder(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateFolderRequest) => foldersApi.create(orgId, data),
    onSuccess: () => invalidateFolders(queryClient, orgId),
  });
}

export function useUpdateFolder(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ ouId, data }: { ouId: string; data: UpdateFolderRequest }) =>
      foldersApi.update(orgId, ouId, data),
    onSuccess: () => invalidateFolders(queryClient, orgId),
  });
}

export function useDeleteFolder(orgId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (ouId: string) => foldersApi.delete(orgId, ouId),
    onSuccess: () => invalidateFolders(queryClient, orgId),
  });
}

// Invalidate both the top-level list and any cached subtrees for this org.
function invalidateFolders(
  queryClient: ReturnType<typeof useQueryClient>,
  orgId: string
) {
  queryClient.invalidateQueries({ queryKey: ["folders", orgId] });
  queryClient.invalidateQueries({ queryKey: ["folder-tree", orgId] });
}

/**
 * Turns an API error into a folder-management-friendly message. Mutating
 * folder operations require org admin rights (403), and delete is rejected
 * with a 409 when the folder still has subfolders or projects — both are
 * surfaced verbatim so the user knows what to clean up first.
 */
export function folderErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights to manage folders.";
  }
  return error instanceof Error ? error.message : fallback;
}
