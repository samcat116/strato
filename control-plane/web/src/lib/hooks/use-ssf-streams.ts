import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ssfStreamsApi } from "@/lib/api/ssf-streams";
import { ApiError } from "@/lib/api/client";
import type {
  CreateSSFStreamRequest,
  UpdateSSFStreamRequest,
} from "@/types/api";

export function useSSFStreams(orgId: string, enabled = true) {
  return useQuery({
    queryKey: ["ssf-streams", orgId],
    queryFn: () => ssfStreamsApi.list(orgId),
    enabled: enabled && !!orgId,
  });
}

export function useCreateSSFStream(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: CreateSSFStreamRequest) =>
      ssfStreamsApi.create(orgId, data),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["ssf-streams", orgId] }),
  });
}

export function useUpdateSSFStream(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      streamId,
      data,
    }: {
      streamId: string;
      data: UpdateSSFStreamRequest;
    }) => ssfStreamsApi.update(orgId, streamId, data),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["ssf-streams", orgId] }),
  });
}

export function useDeleteSSFStream(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (streamId: string) => ssfStreamsApi.delete(orgId, streamId),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["ssf-streams", orgId] }),
  });
}

export function useRegisterSSFStream(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (streamId: string) => ssfStreamsApi.register(orgId, streamId),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["ssf-streams", orgId] }),
  });
}

export function useVerifySSFStream(orgId: string) {
  return useMutation({
    mutationFn: (streamId: string) => ssfStreamsApi.verify(orgId, streamId),
  });
}

export function useSSFStreamStatus(orgId: string) {
  return useMutation({
    mutationFn: (streamId: string) => ssfStreamsApi.status(orgId, streamId),
  });
}

export function usePollSSFStream(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (streamId: string) => ssfStreamsApi.pollNow(orgId, streamId),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["ssf-streams", orgId] }),
  });
}

export function ssfStreamErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights to manage SSF streams.";
  }
  return error instanceof Error ? error.message : fallback;
}
