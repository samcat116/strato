import { api } from "./client";
import { listAllPages } from "./pagination";
import type { components } from "@/types/openapi";

type Schema<Name extends keyof components["schemas"]> = components["schemas"][Name];

export type FloatingIPPool = Schema<"FloatingIPPool">;
export type CreateFloatingIPPoolRequest = Schema<"CreateFloatingIPPoolRequest">;
export type FloatingIP = Schema<"FloatingIP">;
export type CreateFloatingIPRequest = Schema<"CreateFloatingIPRequest">;
export type DNSZone = Schema<"DNSZone">;
export type CreateDNSZoneRequest = Schema<"CreateDNSZoneRequest">;
export type DNSRecord = Schema<"DNSRecord">;
export type CreateDNSRecordRequest = Schema<"CreateDNSRecordRequest">;
export type RegistryPullSecret = Schema<"RegistryPullSecret">;
export type CreateRegistryPullSecretRequest = Schema<"CreateRegistryPullSecretRequest">;
export type ServiceAccount = Schema<"ServiceAccount">;
export type WorkloadRegistration = Schema<"WorkloadRegistration">;
export type HierarchyValidationReport = Schema<"HierarchyValidationReport">;
export type HierarchyRepairRequest = Schema<"HierarchyRepairRequest">;
export type HierarchyRepairReport = Schema<"HierarchyRepairReport">;
export type IAMDecisionLogEntry = Schema<"IAMDecisionLogEntry">;
export type IAMDecisionSummaryBucket = Schema<"IAMDecisionSummaryBucket">;
export type IAMPolicySetVersion = Schema<"IAMPolicySetVersionResponse">;
export type IAMGuardrailListResponse = Schema<"IAMGuardrailListResponse">;
export type IAMGuardrailCreateRequest = Schema<"IAMGuardrailCreateRequest">;
export type IAMGuardrailWriteResponse = Schema<"IAMGuardrailWriteResponse">;
export type IAMWhoCanRequest = Schema<"IAMWhoCanRequest">;
export type IAMWhoCanResponse = Schema<"IAMWhoCanResponse">;
export type LoadBalancer = Schema<"LoadBalancer">;
export type CreateLoadBalancerRequest = Schema<"CreateLoadBalancerRequest">;
export type CreateLoadBalancerBackendRequest = Schema<"CreateLoadBalancerBackendRequest">;

export const loadBalancersApi = {
  list: (projectId: string, signal?: AbortSignal) =>
    listAllPages<LoadBalancer>("/api/load-balancers", { project_id: projectId }, signal),
  create: (data: CreateLoadBalancerRequest) =>
    api.post<LoadBalancer>("/api/load-balancers", data),
  delete: (id: string) => api.delete<void>(`/api/load-balancers/${id}`),
  addListener: (id: string, port: number, backendPort: number) =>
    api.post<{ id: string; port: number; backendPort: number }>(
      `/api/load-balancers/${id}/listeners`,
      { port, backendPort }
    ),
  deleteListener: (id: string, listenerId: string) =>
    api.delete<void>(`/api/load-balancers/${id}/listeners/${listenerId}`),
  addBackend: (
    id: string,
    target: CreateLoadBalancerBackendRequest
  ) => api.post<LoadBalancer["backends"][number]>(`/api/load-balancers/${id}/backends`, target),
  deleteBackend: (id: string, backendId: string) =>
    api.delete<void>(`/api/load-balancers/${id}/backends/${backendId}`),
};

export const floatingIPsApi = {
  listPools: (signal?: AbortSignal) => listAllPages<FloatingIPPool>("/api/floating-ip-pools", {}, signal),
  createPool: (data: CreateFloatingIPPoolRequest) =>
    api.post<FloatingIPPool>("/api/floating-ip-pools", data),
  list: (projectId: string, signal?: AbortSignal) =>
    listAllPages<FloatingIP>("/api/floating-ips", { project_id: projectId }, signal),
  allocate: (data: CreateFloatingIPRequest) =>
    api.post<FloatingIP>("/api/floating-ips", data),
  release: (id: string) => api.delete<void>(`/api/floating-ips/${id}`),
  attach: (id: string, vmId: string, interfaceId?: string) =>
    api.post<FloatingIP>(`/api/floating-ips/${id}/attach`, {
      vmId,
      ...(interfaceId ? { interfaceId } : {}),
    }),
  detach: (id: string) => api.post<FloatingIP>(`/api/floating-ips/${id}/detach`),
};

export const dnsApi = {
  listZones: (projectId: string, signal?: AbortSignal) =>
    listAllPages<DNSZone>("/api/dns-zones", { project_id: projectId }, signal),
  createZone: (data: CreateDNSZoneRequest) =>
    api.post<DNSZone>("/api/dns-zones", data),
  deleteZone: (id: string) => api.delete<void>(`/api/dns-zones/${id}`),
  listRecords: (zoneId: string, signal?: AbortSignal) =>
    listAllPages<DNSRecord>(`/api/dns-zones/${zoneId}/records`, {}, signal),
  createRecord: (zoneId: string, data: CreateDNSRecordRequest) =>
    api.post<DNSRecord>(`/api/dns-zones/${zoneId}/records`, data),
  deleteRecord: (zoneId: string, id: string) =>
    api.delete<void>(`/api/dns-zones/${zoneId}/records/${id}`),
  attachNetwork: (zoneId: string, networkId: string, primary: boolean) =>
    api.post<DNSZone>(`/api/dns-zones/${zoneId}/networks`, { networkId, primary }),
  detachNetwork: (zoneId: string, networkId: string) =>
    api.delete<void>(`/api/dns-zones/${zoneId}/networks/${networkId}`),
};

export const registryCredentialsApi = {
  list: (projectId: string, signal?: AbortSignal) =>
    api.get<RegistryPullSecret[]>(`/api/projects/${projectId}/registry-credentials`, undefined, signal),
  create: (projectId: string, data: CreateRegistryPullSecretRequest) =>
    api.post<RegistryPullSecret>(`/api/projects/${projectId}/registry-credentials`, data),
  delete: (projectId: string, id: string) =>
    api.delete<void>(`/api/projects/${projectId}/registry-credentials/${id}`),
};

export const serviceAccountsApi = {
  list: (projectId: string, signal?: AbortSignal) =>
    api.get<ServiceAccount[]>(`/api/projects/${projectId}/service-accounts`, undefined, signal),
  create: (projectId: string, data: { name: string; description?: string }) =>
    api.post<ServiceAccount>(`/api/projects/${projectId}/service-accounts`, data),
  delete: (id: string) => api.delete<void>(`/api/service-accounts/${id}`),
  setProjectRole: (id: string, role: "viewer" | "operator" | "editor" | "admin") =>
    api.put(`/api/service-accounts/${id}/project-role`, { role }),
  clearProjectRole: (id: string) =>
    api.delete<void>(`/api/service-accounts/${id}/project-role`),
  listRegistrations: (id: string, signal?: AbortSignal) =>
    api.get<WorkloadRegistration[]>(`/api/service-accounts/${id}/registrations`, undefined, signal),
  createRegistration: (id: string, spiffeId: string) =>
    api.post<WorkloadRegistration>(`/api/service-accounts/${id}/registrations`, { spiffeId }),
  deleteRegistration: (id: string, registrationId: string) =>
    api.delete<void>(`/api/service-accounts/${id}/registrations/${registrationId}`),
};

export const workloadRegistrationsApi = {
  list: (signal?: AbortSignal) => listAllPages<WorkloadRegistration>("/api/workload-registrations", {}, signal),
  create: (data: { spiffeId: string; organizationId: string; displayName?: string }) =>
    api.post<WorkloadRegistration>("/api/workload-registrations", data),
  delete: (id: string) => api.delete<void>(`/api/workload-registrations/${id}`),
};

export const platformOperationsApi = {
  validateHierarchy: (signal?: AbortSignal) => api.get<HierarchyValidationReport>("/api/hierarchy/validate", undefined, signal),
  repairHierarchy: (data: HierarchyRepairRequest) =>
    api.post<HierarchyRepairReport>("/api/hierarchy/repair", data),
  listDecisionLogs: (limit = 100, signal?: AbortSignal) =>
    api.get<IAMDecisionLogEntry[]>("/api/iam/decision-logs", { limit: String(limit) }, signal),
  decisionSummary: (sinceHours = 24, signal?: AbortSignal) =>
    api.get<IAMDecisionSummaryBucket[]>("/api/iam/decision-logs/summary", {
      sinceHours: String(sinceHours),
    }, signal),
  policySetVersion: (signal?: AbortSignal) =>
    api.get<IAMPolicySetVersion>("/api/iam/policy-set/version", undefined, signal),
  listGuardrails: (nodeType: string, nodeId: string, signal?: AbortSignal) =>
    api.get<IAMGuardrailListResponse>("/api/iam/guardrails", {
      nodeType,
      nodeId,
      effective: "true",
    }, signal),
  createGuardrail: (data: IAMGuardrailCreateRequest) =>
    api.post<IAMGuardrailWriteResponse>("/api/iam/guardrails", data),
  deleteGuardrail: (id: string) => api.delete<void>(`/api/iam/guardrails/${id}`),
  whoCan: (data: IAMWhoCanRequest) =>
    api.post<IAMWhoCanResponse>("/api/authorization/who-can", data),
};
