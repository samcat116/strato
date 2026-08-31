import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { networksApi } from "@/lib/api/networks";
import type { CreateNetworkACLRuleRequest } from "@/types/api";

export function useNetworks(projectId?: string) {
  return useQuery({
    queryKey: ["networks", { projectId: projectId ?? null }],
    queryFn: ({ signal }) => networksApi.list(projectId, signal),
  });
}

export function useInvalidateNetworks() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["networks"] });
}

export function useNetworkACL(networkId?: string, enabled = true) {
  return useQuery({
    queryKey: ["network-acl", networkId],
    queryFn: ({ signal }) => networksApi.getACL(networkId!, signal),
    enabled: enabled && Boolean(networkId),
  });
}

export function useCreateNetworkACL(networkId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => networksApi.createACL(networkId),
    onSuccess: (acl) => {
      queryClient.setQueryData(["network-acl", networkId], acl);
    },
  });
}

export function useDeleteNetworkACL(networkId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => networksApi.deleteACL(networkId),
    onSuccess: () => {
      queryClient.setQueryData(["network-acl", networkId], null);
    },
  });
}

export function useCreateNetworkACLRule(networkId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: CreateNetworkACLRuleRequest) =>
      networksApi.createACLRule(networkId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["network-acl", networkId] });
    },
  });
}

export function useDeleteNetworkACLRule(networkId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (ruleId: string) =>
      networksApi.deleteACLRule(networkId, ruleId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["network-acl", networkId] });
    },
  });
}
