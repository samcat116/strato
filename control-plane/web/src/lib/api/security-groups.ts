// Security group API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  SecurityGroup,
  SecurityGroupRule,
  CreateSecurityGroupRequest,
  UpdateSecurityGroupRequest,
  CreateSecurityGroupRuleRequest,
  AttachSecurityGroupRequest,
} from "@/types/api-contracts";

export const securityGroupsApi = {
  list(projectId?: string, signal?: AbortSignal): Promise<SecurityGroup[]> {
    return listAllPages<SecurityGroup>(
      "/api/security-groups",
      projectId ? { project_id: projectId } : {}, signal
    );
  },

  create(data: CreateSecurityGroupRequest): Promise<SecurityGroup> {
    return api.post<SecurityGroup>("/api/security-groups", data);
  },

  update(id: string, data: UpdateSecurityGroupRequest): Promise<SecurityGroup> {
    return api.put<SecurityGroup>(`/api/security-groups/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/security-groups/${id}`);
  },

  createRule(
    id: string,
    data: CreateSecurityGroupRuleRequest
  ): Promise<SecurityGroupRule> {
    return api.post<SecurityGroupRule>(`/api/security-groups/${id}/rules`, data);
  },

  deleteRule(id: string, ruleId: string): Promise<void> {
    return api.delete(`/api/security-groups/${id}/rules/${ruleId}`);
  },

  attach(id: string, data: AttachSecurityGroupRequest): Promise<void> {
    return api.post(`/api/security-groups/${id}/attach`, data);
  },

  detach(id: string, data: AttachSecurityGroupRequest): Promise<void> {
    return api.post(`/api/security-groups/${id}/detach`, data);
  },
};
