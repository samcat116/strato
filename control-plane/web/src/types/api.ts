// API Types - matches Vapor backend response types

import type { components } from "./openapi";

type OpenAPISchemas = components["schemas"];
type WithRequired<T, K extends keyof T> = T & Required<Pick<T, K>>;
export type StorageDevice = OpenAPISchemas["StorageDevice"];
export type UpdateStorageDeviceRequest = OpenAPISchemas["UpdateStorageDeviceRequest"];

/** Paged envelope returned by every resource list endpoint (issue #700). */
export interface Page<T> {
  items: T[];
  /** Total rows the caller may see, ignoring limit/offset. */
  total: number;
  limit: number;
  offset: number;
}

/** The server-side page-size cap used while draining complete lists. */
export const LIST_PAGE_LIMIT = "500";
export type UserSource = OpenAPISchemas["UserSource"];

export type User = WithRequired<OpenAPISchemas["UserPublic"], "id">;

export interface CreateUserRequest {
  username: string;
  email: string;
  displayName: string;
}
export type AdminCreateUserRequest = OpenAPISchemas["AdminCreateUserRequest"];
export type AdminCreateUserResponse = OpenAPISchemas["AdminCreateUserResponse"];
export type ClaimInfoResponse = OpenAPISchemas["ClaimInfoResponse"];
export type UpdateUserRequest = OpenAPISchemas["UpdateUserRequest"];

export type Passkey = WithRequired<OpenAPISchemas["PasskeySummary"], "id">;
export type VMStatus = OpenAPISchemas["VMStatus"];
export type InterfaceAddress = OpenAPISchemas["InterfaceAddress"];
export type ObservedInterfaceAddress = OpenAPISchemas["ObservedInterfaceAddress"];

export type VMNetworkInterface = OpenAPISchemas["NetworkInterface"];
export type CreateVMNetworkInterfaceRequest = OpenAPISchemas["CreateVMNetworkInterfaceRequest"];
export type InstanceIdentityStatus = OpenAPISchemas["InstanceIdentityStatus"];
export type MetadataSource = OpenAPISchemas["MetadataSource"];

export type VM = WithRequired<OpenAPISchemas["VMDetail"], "id" | "createdAt" | "updatedAt">;


export type Organization = WithRequired<OpenAPISchemas["OrganizationDetail"], "id" | "createdAt">;
export type OrganizationMember = WithRequired<OpenAPISchemas["OrganizationMember"], "id">;

export type GrantCeiling = OpenAPISchemas["IAMGrantCeiling"];
export type GrantWriteResponse = OpenAPISchemas["IAMGrantWriteResponse"];


/** Canonical `iam_roles` UUID used by project grant endpoints. */
export type ProjectRole = string;
export type ProjectMember = WithRequired<OpenAPISchemas["ProjectMember"], "userId">;
export type ProjectGroupGrant = WithRequired<OpenAPISchemas["ProjectGroupGrant"], "groupId">;
export type ProjectWorkloadGrant = OpenAPISchemas["ProjectWorkloadGrant"];
export type VMProjectGrantResponse = OpenAPISchemas["VMProjectGrantResponse"];
export type ProjectVMPrincipal = OpenAPISchemas["ProjectVMPrincipal"];
export type ProjectMembers = Omit<OpenAPISchemas["ProjectMembers"], "users" | "groups"> & {
  users: ProjectMember[];
  groups: ProjectGroupGrant[];
};

export type ActionCheckItem = OpenAPISchemas["IAMActionCheckItem"];
export type ActionCheckResponse = OpenAPISchemas["IAMActionCheckResponse"];


// Groups
export type Group = WithRequired<OpenAPISchemas["GroupDetail"], "id">;
export type GroupMember = WithRequired<OpenAPISchemas["GroupMember"], "id">;
export type CreateGroupRequest = OpenAPISchemas["CreateGroupRequest"];
export type UpdateGroupRequest = OpenAPISchemas["UpdateGroupRequest"];
export type IAMRoleOwnerType = OpenAPISchemas["IAMRoleOwnerType"];
export type IAMNodeType = OpenAPISchemas["IAMNodeType"];
export type IAMNode = OpenAPISchemas["IAMNode"];
export type IAMRole = OpenAPISchemas["IAMRole"];
export type IAMRoleListResponse = OpenAPISchemas["IAMRoleListResponse"];
export type IAMBindableRole = OpenAPISchemas["IAMBindableRole"];
export type IAMBindableRolesResponse = OpenAPISchemas["IAMBindableRolesResponse"];
export type IAMRoleCreateRequest = OpenAPISchemas["IAMRoleCreateRequest"];
export type IAMRoleUpdateRequest = OpenAPISchemas["IAMRoleUpdateRequest"];
export type IAMRoleValidateRequest = OpenAPISchemas["IAMRoleValidateRequest"];
export type IAMRoleValidateResponse = OpenAPISchemas["IAMRoleValidateResponse"];
export type IAMPolicyEffect = OpenAPISchemas["IAMPolicyEffect"];
export type IAMPolicy = OpenAPISchemas["IAMPolicy"];
export type IAMPolicyListResponse = OpenAPISchemas["IAMPolicyListResponse"];
export type IAMPolicyCreateRequest = OpenAPISchemas["IAMPolicyCreateRequest"];
export type IAMPolicyUpdateRequest = OpenAPISchemas["IAMPolicyUpdateRequest"];
export type IAMPolicyValidateRequest = OpenAPISchemas["IAMPolicyValidateRequest"];
export type IAMPolicyValidateResponse = OpenAPISchemas["IAMPolicyValidateResponse"];
export type IAMActionCatalogEntry = OpenAPISchemas["IAMActionCatalogEntry"];
export type IAMActionCatalogService = OpenAPISchemas["IAMActionCatalogService"];
export type IAMActionCatalogResponse = OpenAPISchemas["IAMActionCatalogResponse"];
export type AgentStatus = OpenAPISchemas["AgentStatus"];
export type AgentResources = OpenAPISchemas["AgentResources"];
export type HypervisorType = OpenAPISchemas["HypervisorType"];
export type CPUArchitecture = OpenAPISchemas["CPUArchitecture"];

export type NetworkCapability = OpenAPISchemas["AgentNetworkCapability"];
export type HypervisorCapabilities = OpenAPISchemas["AgentHypervisorCapabilities"];
export type HypervisorSupport = OpenAPISchemas["AgentHypervisorSupport"];
export type HostInfo = OpenAPISchemas["AgentHostInfo"];


export type Agent = OpenAPISchemas["AgentDetail"];
export type NodeDependencyObservation = OpenAPISchemas["NodeDependencyObservation"];
export type HeldWorkload = OpenAPISchemas["HeldWorkload"];
export type AdoptWorkloadsResult = OpenAPISchemas["AdoptWorkloadsResult"];
export type AgentUpdateResult = OpenAPISchemas["AgentUpdateResult"];

export type AgentEnrollment = OpenAPISchemas["AgentEnrollmentDetail"];

export type AgentEnrollmentListItem = OpenAPISchemas["AgentEnrollmentListItem"];
export type SiteStatus = OpenAPISchemas["SiteStatus"];

export type Site = OpenAPISchemas["SiteDetail"];
export type CreateSiteRequest = OpenAPISchemas["CreateSiteRequest"];
export type UpdateSiteRequest = OpenAPISchemas["UpdateSiteRequest"];
export type StoragePoolMode = OpenAPISchemas["StoragePoolMode"];
export type StoragePool = OpenAPISchemas["StoragePoolResponse"];
export type CephClusterHealth = OpenAPISchemas["CephClusterHealth"];
export type CephCluster = OpenAPISchemas["CephClusterResponse"];
export type RegisterCephClusterRequest = OpenAPISchemas["CreateExternalCephClusterRequest"];
export type UpdateCephClusterRequest = OpenAPISchemas["UpdateExternalCephClusterRequest"];
export type CephProjectAccess = OpenAPISchemas["CephProjectAccessResponse"];
export type ConfigureCephProjectAccessRequest = OpenAPISchemas["UpsertCephProjectAccessRequest"];
export type CredentialRestriction = OpenAPISchemas["CredentialRestriction"];

export type APIKey = WithRequired<OpenAPISchemas["APIKeySummary"], "id">;
export type CreateAPIKeyResponse = OpenAPISchemas["CreateAPIKeyResponse"];
export type SessionResponse = Omit<OpenAPISchemas["SessionResponse"], "user"> & { user: User };

// SCIM provisioning tokens (org-scoped, admin only)
export type SCIMToken = WithRequired<OpenAPISchemas["SCIMTokenSummary"], "id">;
export type CreateSCIMTokenResponse = WithRequired<OpenAPISchemas["CreateSCIMTokenResult"], "id">;
export type CreateSCIMTokenRequest = OpenAPISchemas["CreateSCIMTokenRequest"];
export type UpdateSCIMTokenRequest = OpenAPISchemas["UpdateSCIMTokenRequest"];

export type OIDCProvider = WithRequired<OpenAPISchemas["OIDCProviderConfig"], "id">;

export type CreateOIDCProviderRequest = OpenAPISchemas["CreateOIDCProviderRequest"];
export type UpdateOIDCProviderRequest = OpenAPISchemas["UpdateOIDCProviderRequest"];
export type OIDCProviderTestResult = OpenAPISchemas["OIDCProviderTestResult"];

export type PublicOIDCProvider = WithRequired<OpenAPISchemas["OIDCProviderPublicSummary"], "id">;
export type SSOLookupResponse = Omit<OpenAPISchemas["SSOLookupResult"], "providers"> & {
  providers: PublicOIDCProvider[];
};

export type RegistrationPolicy = OpenAPISchemas["RegistrationPolicy"];
export type SSFStream = WithRequired<OpenAPISchemas["SSFStream"], "id">;
export type CreateSSFStreamRequest = OpenAPISchemas["CreateSSFStreamRequest"];
export type UpdateSSFStreamRequest = OpenAPISchemas["UpdateSSFStreamRequest"];

export type RegisterSSFStreamResponse = Omit<OpenAPISchemas["RegisterSSFStreamResult"], "stream"> & { stream: SSFStream };

export type SSFStreamStatus = OpenAPISchemas["SSFStreamStatus"];
export type SSFPollResult = OpenAPISchemas["SSFPollResult"];
export type WebhookSubscription = OpenAPISchemas["WebhookSubscription"];
export type WebhookDelivery = OpenAPISchemas["WebhookDelivery"];
export type CreateWebhookRequest = OpenAPISchemas["CreateWebhookRequest"];
export type UpdateWebhookRequest = OpenAPISchemas["UpdateWebhookRequest"];
export type WebhookWithSecret = OpenAPISchemas["WebhookWithSecret"];
export type CreateVMRequest = OpenAPISchemas["CreateVMRequest"];
export type PatchVMMetadataRequest = OpenAPISchemas["PatchVMMetadataRequest"];
export type OperationKind = OpenAPISchemas["OperationKind"];
export type OperationStatus = OpenAPISchemas["OperationStatus"];
export type ResourceConditions = OpenAPISchemas["ResourceConditions"];

/**
 * The 202 body of a VM, sandbox, or volume lifecycle mutation (backend
 * STR-147, extended to volumes by STR-148): the
 * resource as the mutation left it, the generation it now has to reach, and
 * the id of the mutation's audit record.
 *
 * `mutationId` matters for **delete**, and only for delete: every other
 * mutation is answerable from the resource, but a delete succeeds by the
 * resource ceasing to exist, and a 404 on it means deleted, never-existed and
 * not-authorized alike. `operationsApi.get(mutationId)` answers authoritatively
 * once the row is gone.
 */
export interface AcceptedMutation<Resource> {
  resource: Resource;
  targetGeneration: number;
  mutationId: string;
}
export type OperationResourceKind = OpenAPISchemas["OperationResourceKind"];

export type Operation = WithRequired<OpenAPISchemas["ResourceOperation"], "id">;
export type SandboxStatus = OpenAPISchemas["SandboxStatus"];

export type Sandbox = WithRequired<OpenAPISchemas["SandboxDetail"], "id" | "createdAt" | "updatedAt">;
export type SandboxNetworkInterface = OpenAPISchemas["SandboxNetworkInterface"];
export type CreateSandboxRequest = OpenAPISchemas["CreateSandboxRequest"];
export type VMSnapshotStatus = OpenAPISchemas["VMSnapshotStatus"];
export type VMSnapshot = WithRequired<OpenAPISchemas["VMSnapshot"], "id">;
export type CreateVMSnapshotRequest = OpenAPISchemas["CreateVMSnapshotRequest"];
export type SandboxSnapshotStatus = OpenAPISchemas["SandboxSnapshotStatus"];
export type SandboxSnapshot = WithRequired<OpenAPISchemas["SandboxSnapshot"], "id">;
export type CreateSandboxSnapshotRequest = OpenAPISchemas["CreateSandboxSnapshotRequest"];

// VM graphics console (backend issue #566): POST /api/vms/:id/console/vnc
// mints a short-lived single-use session, then the browser attaches over a
// WebSocket at `websocketPath` and hands that socket to noVNC. The two-step
// shape exists so the reasons a display can be unavailable — the VM was
// created headless (409), its agent is too old or its socket is on another
// replica (503) — arrive as status codes rather than as an unexplained
// disconnect after the upgrade.
export interface VNCSession {
  sessionId: string;
  /** Same-origin WebSocket path, e.g. `/api/vms/<id>/console/vnc/<sessionId>/attach`. */
  websocketPath: string;
  /** When the pending (unattached) session expires. */
  expiresAt: string;
}

// Sandbox exec (backend issue #423): POST /api/sandboxes/:id/exec creates a
// short-lived pending session, then the browser attaches over a WebSocket at
// `websocketPath` (binary frames = stdin/stdout bytes, text frames = JSON
// control messages).
export interface SandboxExecRequest {
  command: string[];
  env?: Record<string, string>;
  workingDir?: string;
  tty?: boolean;
  rows?: number;
  cols?: number;
  /** Omitted keeps the browser-compatible raw binary framing. */
  outputMode?: "raw" | "multiplexed";
}

export interface SandboxExecSession {
  sessionId: string;
  /** Same-origin WebSocket path, e.g. `/api/sandboxes/<id>/exec/<sessionId>/attach`. */
  websocketPath: string;
  /** When the pending (unattached) session expires. */
  expiresAt: string;
  /** Echoes the selected framing; absent only when talking to an older server. */
  outputMode?: "raw" | "multiplexed";
}

// Sandbox workload logs (stdout/stderr shipped to Loki). Same envelope as VM
// logs, but labeled with `stream` instead of level/event_type.
export type SandboxLogStream = "stdout" | "stderr";

export interface SandboxLogEntry {
  timestamp: string;
  message: string;
  labels: {
    sandbox_id?: string;
    stream?: SandboxLogStream;
    source?: string;
    [key: string]: string | undefined;
  };
}

/**
 * The window/paging params every resource's log endpoint accepts. One shape,
 * because `buildLogQueryString` in lib/api/logs.ts serializes all of them: a
 * per-resource copy that drifted would leave the builder silently dropping that
 * resource's new param.
 */
export interface LogQueryParams {
  limit?: number;
  direction?: "forward" | "backward";
  start?: number; // Unix timestamp
  end?: number; // Unix timestamp
}

export type SandboxLogsQueryParams = LogQueryParams;
export type CreateOrganizationRequest = OpenAPISchemas["CreateOrganizationRequest"];
export type UpdateOrganizationRequest = OpenAPISchemas["UpdateOrganizationRequest"];
export type CreateAPIKeyRequest = OpenAPISchemas["CreateAPIKeyRequest"];
export type CreateAgentEnrollmentRequest = OpenAPISchemas["CreateAgentEnrollmentRequest"];
export type ImageStatus = OpenAPISchemas["ImageStatus"];
export type ImageFormat = OpenAPISchemas["ImageFormat"];
export type ArtifactKind = OpenAPISchemas["ArtifactKind"];
export type ArtifactStatus = OpenAPISchemas["ArtifactStatus"];
export type ImageArtifact = OpenAPISchemas["ImageArtifact"];
export type Image = OpenAPISchemas["Image"];
export type CreateImageRequest = OpenAPISchemas["CreateImageRequest"];
export type ImageUploadForm = OpenAPISchemas["ImageUploadForm"];
export type UpdateImageRequest = OpenAPISchemas["UpdateImageRequest"];
export type VolumeStatus = OpenAPISchemas["VolumeStatus"];
export type VolumeFormat = OpenAPISchemas["VolumeFormat"];
export type VolumeType = OpenAPISchemas["VolumeType"];
export type VolumeIOLimits = OpenAPISchemas["VolumeIOLimits"];
export type Volume = OpenAPISchemas["Volume"];

export type SnapshotStatus =
  | "creating"
  | "available"
  | "deleting"
  | "error";
export type VolumeSnapshot = OpenAPISchemas["VolumeSnapshot"];
export type CreateVolumeRequest = OpenAPISchemas["CreateVolumeRequest"];
export type AttachVolumeRequest = OpenAPISchemas["AttachVolumeRequest"];
export type ResizeVolumeRequest = OpenAPISchemas["ResizeVolumeRequest"];
export type CloneVolumeRequest = OpenAPISchemas["CloneVolumeRequest"];
export type CreateVolumeSnapshotRequest = OpenAPISchemas["CreateVolumeSnapshotRequest"];

// VM Log types
// Each union carries "unknown": the backend decodes unrecognized values
// tolerantly into that case (a newer agent may emit vocabulary this build
// doesn't know) and forwards it, so the UI must render it, not crash on it.
export type VMLogLevel = "debug" | "info" | "warning" | "error" | "unknown";
export type VMLogSource = "agent" | "control_plane" | "unknown";
export type VMEventType =
  | "status_change"
  | "operation"
  | "error"
  | "info"
  | "unknown";

export interface VMLogEntry {
  timestamp: string;
  message: string;
  labels: {
    vm_id?: string;
    level?: VMLogLevel;
    source?: VMLogSource;
    event_type?: VMEventType;
    operation?: string;
    [key: string]: string | undefined;
  };
}

export type VMLogsQueryParams = LogQueryParams;

// Resource Quotas
export type QuotaEntityType = "organization" | "ou" | "project";

export type QuotaLimits = OpenAPISchemas["ResourceQuotaLimits"];
export type QuotaReservedUsage = OpenAPISchemas["ResourceQuotaUsage"];
export type QuotaUtilization = OpenAPISchemas["ResourceQuotaUtilization"];
export type ResourceQuota = WithRequired<OpenAPISchemas["ResourceQuota"], "id">;
export type HierarchyQuota = OpenAPISchemas["HierarchyQuota"];
export type CreateQuotaRequest = OpenAPISchemas["CreateResourceQuotaRequest"];
export type UpdateQuotaRequest = OpenAPISchemas["UpdateResourceQuotaRequest"];


export type VMSummaryNode = OpenAPISchemas["HierarchyVMSummary"];
export type ProjectNode = OpenAPISchemas["HierarchyProjectNode"];
export type FolderNode = OpenAPISchemas["HierarchyFolderNode"];
export type OrganizationNode = OpenAPISchemas["HierarchyOrganizationNode"];
export type HierarchyResourceUsage = OpenAPISchemas["HierarchyResourceUsage"];
export type HierarchyStats = OpenAPISchemas["HierarchyStats"];
export type OrganizationHierarchy = OpenAPISchemas["OrganizationHierarchy"];
export type HierarchySearchResult = OpenAPISchemas["HierarchySearchResult"];

export type HierarchySearchResponse = OpenAPISchemas["HierarchySearchResults"];

export type Network = OpenAPISchemas["Network"];
export type CreateNetworkRequest = OpenAPISchemas["CreateNetworkRequest"];
export type UpdateNetworkRequest = OpenAPISchemas["UpdateNetworkRequest"];

export type NetworkACLRuleDirection = OpenAPISchemas["NetworkACLRuleDirection"];
export type NetworkACLRuleEthertype = OpenAPISchemas["NetworkACLRuleEthertype"];
export type NetworkACLRuleAction = OpenAPISchemas["NetworkACLRuleAction"];
export type CreateNetworkACLRuleRequest = OpenAPISchemas["CreateNetworkACLRuleRequest"];
export type NetworkACLRule = OpenAPISchemas["NetworkACLRule"];
export type NetworkACL = OpenAPISchemas["NetworkACL"];
export const MAX_NETWORK_ACL_RULES = 100;

export type SecurityGroupRuleDirection = OpenAPISchemas["SecurityGroupRuleDirection"];
export type Ethertype = "ipv4" | "ipv6";

/** Server-enforced cap (SecurityGroup.maxGroupsPerNIC in the control plane). */
export const MAX_SECURITY_GROUPS_PER_NIC = 5;
export type SecurityGroupRule = OpenAPISchemas["SecurityGroupRule"];
export type SecurityGroup = OpenAPISchemas["SecurityGroup"];
export type CreateSecurityGroupRequest = OpenAPISchemas["CreateSecurityGroupRequest"];
export type UpdateSecurityGroupRequest = OpenAPISchemas["UpdateSecurityGroupRequest"];
export type CreateSecurityGroupRuleRequest = OpenAPISchemas["CreateSecurityGroupRuleRequest"];
export type AttachSecurityGroupRequest = OpenAPISchemas["AttachSecurityGroupRequest"];
export type AuditEvent = OpenAPISchemas["AuditEvent"];
export type AuditEventListResponse = OpenAPISchemas["AuditEventListResponse"];

export type WorkloadRegistrationEntry = OpenAPISchemas["SPIRERegistrationEntry"];
export type NodeAttestationGroup = OpenAPISchemas["SPIRENodeAttestationGroup"];
export type TrustBundleInfo = OpenAPISchemas["SPIRETrustBundle"];
export type FederatedDomain = OpenAPISchemas["SPIREFederatedDomain"];
export type FederationInfo = OpenAPISchemas["SPIREFederation"];
export type IssuanceInfo = OpenAPISchemas["SPIREIssuance"];
export type WorkloadIdentityOverview = OpenAPISchemas["WorkloadIdentityOverview"];
export type PendingDeviceAuthorization = OpenAPISchemas["PendingDeviceAuthorization"];

export type CLISession = WithRequired<OpenAPISchemas["CLISessionSummary"], "id">;
