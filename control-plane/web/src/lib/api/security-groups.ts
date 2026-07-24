// Security group API endpoints

import { api } from "./client";
import type {
  SecurityGroup,
  SecurityGroupRule,
  CreateSecurityGroupRequest,
  UpdateSecurityGroupRequest,
  CreateSecurityGroupRuleRequest,
  AttachSecurityGroupRequest,
  Page,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

export const securityGroupsApi = {
  list(projectId?: string): Promise<SecurityGroup[]> {
    return api
      .get<Page<SecurityGroup>>("/api/security-groups", {
        limit: LIST_PAGE_LIMIT,
        ...(projectId ? { project_id: projectId } : {}),
      })
      .then((page) => page.items);
  },

  get(id: string): Promise<SecurityGroup> {
    return api.get<SecurityGroup>(`/api/security-groups/${id}`);
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
