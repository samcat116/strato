import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { oauthApi } from "@/lib/api/oauth";
import type { CredentialRestriction } from "@/types/api";

export function useCLISessions() {
  return useQuery({
    queryKey: ["cli-sessions"],
    queryFn: ({ signal }) => oauthApi.listSessions(signal),
  });
}

export function useRevokeCLISession() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => oauthApi.revokeSession(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["cli-sessions"] });
    },
  });
}

export function usePendingDeviceAuthorization(userCode: string | null) {
  return useQuery({
    queryKey: ["device-authorization", userCode],
    queryFn: ({ signal }) => oauthApi.getPendingDevice(userCode!, signal),
    enabled: !!userCode,
    retry: false,
  });
}

export function useApproveDevice() {
  return useMutation({
    mutationFn: ({
      userCode,
      restriction,
    }: {
      userCode: string;
      restriction?: CredentialRestriction;
    }) => oauthApi.approveDevice(userCode, restriction),
  });
}

export function useDenyDevice() {
  return useMutation({
    mutationFn: (userCode: string) => oauthApi.denyDevice(userCode),
  });
}
