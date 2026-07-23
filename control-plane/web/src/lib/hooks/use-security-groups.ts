import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { securityGroupsApi } from "@/lib/api/security-groups";
import type {
  CreateSecurityGroupRequest,
  UpdateSecurityGroupRequest,
  CreateSecurityGroupRuleRequest,
  AttachSecurityGroupRequest,
} from "@/types/api";

export function useSecurityGroups(projectId?: string) {
  return useQuery({
    queryKey: ["security-groups", { projectId: projectId ?? null }],
    queryFn: () => securityGroupsApi.list(projectId),
  });
}

export function useSecurityGroup(id: string) {
  return useQuery({
    queryKey: ["security-groups", id],
    queryFn: () => securityGroupsApi.get(id),
    enabled: !!id,
  });
}

export function useInvalidateSecurityGroups() {
  const queryClient = useQueryClient();
  return () =>
    queryClient.invalidateQueries({ queryKey: ["security-groups"] });
}

export function useCreateSecurityGroup() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateSecurityGroupRequest) =>
      securityGroupsApi.create(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["security-groups"] });
    },
  });
}

export function useUpdateSecurityGroup() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      id,
      data,
    }: {
      id: string;
      data: UpdateSecurityGroupRequest;
    }) => securityGroupsApi.update(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["security-groups"] });
    },
  });
}

export function useDeleteSecurityGroup() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => securityGroupsApi.delete(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["security-groups"] });
    },
  });
}

export function useCreateSecurityGroupRule() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      id,
      data,
    }: {
      id: string;
      data: CreateSecurityGroupRuleRequest;
    }) => securityGroupsApi.createRule(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["security-groups"] });
    },
  });
}

export function useDeleteSecurityGroupRule() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ id, ruleId }: { id: string; ruleId: string }) =>
      securityGroupsApi.deleteRule(id, ruleId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["security-groups"] });
    },
  });
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
    },
  });
}
