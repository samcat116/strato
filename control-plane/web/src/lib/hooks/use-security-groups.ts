import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { securityGroupsApi } from "@/lib/api/security-groups";
import type { AttachSecurityGroupRequest } from "@/types/api";

export function useSecurityGroups(projectId?: string) {
  return useQuery({
    queryKey: ["security-groups", { projectId: projectId ?? null }],
    queryFn: ({ signal }) =>
      projectId ? securityGroupsApi.list(projectId, signal) : Promise.resolve([]),
    enabled: !!projectId,
  });
}

export function useInvalidateSecurityGroups() {
  const queryClient = useQueryClient();
  return () =>
    queryClient.invalidateQueries({ queryKey: ["security-groups"] });
}

export function useAttachSecurityGroup() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      id,
      data,
    }: {
      id: string;
      data: AttachSecurityGroupRequest;
    }) => securityGroupsApi.attach(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["security-groups"] });
      // Membership lives on the workload's NIC too, so the VM/sandbox views
      // would otherwise keep showing the pre-attach set.
      queryClient.invalidateQueries({ queryKey: ["vms"] });
      queryClient.invalidateQueries({ queryKey: ["sandboxes"] });
    },
  });
}

export function useDetachSecurityGroup() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      id,
      data,
    }: {
      id: string;
      data: AttachSecurityGroupRequest;
    }) => securityGroupsApi.detach(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["security-groups"] });
      queryClient.invalidateQueries({ queryKey: ["vms"] });
      queryClient.invalidateQueries({ queryKey: ["sandboxes"] });
    },
  });
}
