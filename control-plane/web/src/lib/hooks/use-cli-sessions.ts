import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { oauthApi } from "@/lib/api/oauth";

export function useCLISessions() {
  return useQuery({
    queryKey: ["cli-sessions"],
    queryFn: () => oauthApi.listSessions(),
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
    queryFn: () => oauthApi.getPendingDevice(userCode!),
    enabled: !!userCode,
    retry: false,
  });
}

export function useApproveDevice() {
  return useMutation({
    mutationFn: (userCode: string) => oauthApi.approveDevice(userCode),
  });
}

export function useDenyDevice() {
  return useMutation({
    mutationFn: (userCode: string) => oauthApi.denyDevice(userCode),
  });
}
