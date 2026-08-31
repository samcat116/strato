/**
 * API-bound contracts backed by the generated OpenAPI schema.
 *
 * `api.ts` still contains UI-friendly compatibility shapes while the frontend
 * is migrated incrementally. API clients must import from this module so wire
 * drift is checked against `openapi.ts` at build time. Response intersections
 * retain the existing UI guarantees; request intersections keep server-defaulted
 * generated properties optional until their forms are migrated.
 */
import type { components } from "./openapi";
import type * as Legacy from "./api";
export { LIST_PAGE_LIMIT } from "./api";

type Schema<Name extends keyof components["schemas"]> = components["schemas"][Name];
type Response<Name extends keyof components["schemas"], Compatibility> =
  Compatibility & Omit<Schema<Name>, keyof Compatibility>;
type Request<Name extends keyof components["schemas"], Compatibility> =
  Compatibility & Partial<Omit<Schema<Name>, keyof Compatibility>>;

export type VM = Response<"VMDetail", Legacy.VM>;
export type CreateVMRequest = Request<"CreateVMRequest", Legacy.CreateVMRequest>;
export type PatchVMMetadataRequest = Request<"UpdateVMRequest", Legacy.PatchVMMetadataRequest>;
export type VMNetworkInterface = Response<"NetworkInterface", Legacy.VMNetworkInterface>;
export type CreateVMNetworkInterfaceRequest = Request<"CreateVMNetworkInterfaceRequest", Legacy.CreateVMNetworkInterfaceRequest>;
export type VMSnapshot = Response<"VMSnapshot", Legacy.VMSnapshot>;
export type CreateVMSnapshotRequest = Request<"CreateVMSnapshotRequest", Legacy.CreateVMSnapshotRequest>;
export type VNCSession = Legacy.VNCSession;

export type Sandbox = Response<"SandboxDetail", Legacy.Sandbox>;
export type CreateSandboxRequest = Request<"CreateSandboxRequest", Legacy.CreateSandboxRequest>;
export type SandboxExecRequest = Request<"GuestExecRequest", Legacy.SandboxExecRequest>;
export type SandboxExecSession = Response<"GuestExecSession", Legacy.SandboxExecSession>;
export type SandboxSnapshot = Response<"SandboxSnapshot", Legacy.SandboxSnapshot>;
export type CreateSandboxSnapshotRequest = Request<"CreateSandboxSnapshotRequest", Legacy.CreateSandboxSnapshotRequest>;

export type Image = Response<"Image", Legacy.Image>;
export type ArtifactKind = Schema<"ArtifactKind"> & Legacy.ArtifactKind;
export type CreateImageRequest = Request<"CreateImageRequest", Legacy.CreateImageRequest>;
export type ImageUploadForm = Schema<"ImageUploadForm">;
export type UpdateImageRequest = Request<"UpdateImageRequest", Legacy.UpdateImageRequest>;

export type Volume = Response<"Volume", Legacy.Volume>;
export type VolumeSnapshot = Response<"VolumeSnapshot", Legacy.VolumeSnapshot>;
export type CreateVolumeRequest = Request<"CreateVolumeRequest", Legacy.CreateVolumeRequest>;
export type AttachVolumeRequest = Request<"AttachVolumeRequest", Legacy.AttachVolumeRequest>;
export type ResizeVolumeRequest = Request<"ResizeVolumeRequest", Legacy.ResizeVolumeRequest>;
export type CloneVolumeRequest = Request<"CloneVolumeRequest", Legacy.CloneVolumeRequest>;
export type CreateVolumeSnapshotRequest = Request<"CreateVolumeSnapshotRequest", Legacy.CreateVolumeSnapshotRequest>;

export type Network = Response<"Network", Legacy.Network>;
export type CreateNetworkRequest = Request<"CreateNetworkRequest", Legacy.CreateNetworkRequest>;
export type UpdateNetworkRequest = Request<"UpdateNetworkRequest", Legacy.UpdateNetworkRequest>;
export type NetworkACL = Response<"NetworkACL", Legacy.NetworkACL>;
export type NetworkACLRule = Response<"NetworkACLRule", Legacy.NetworkACLRule>;
export type CreateNetworkACLRuleRequest = Request<"CreateNetworkACLRuleRequest", Legacy.CreateNetworkACLRuleRequest>;
export type SecurityGroup = Response<"SecurityGroup", Legacy.SecurityGroup>;
export type SecurityGroupRule = Response<"SecurityGroupRule", Legacy.SecurityGroupRule>;
export type CreateSecurityGroupRequest = Request<"CreateSecurityGroupRequest", Legacy.CreateSecurityGroupRequest>;
export type UpdateSecurityGroupRequest = Request<"UpdateSecurityGroupRequest", Legacy.UpdateSecurityGroupRequest>;
export type CreateSecurityGroupRuleRequest = Request<"CreateSecurityGroupRuleRequest", Legacy.CreateSecurityGroupRuleRequest>;
export type AttachSecurityGroupRequest = Request<"AttachSecurityGroupRequest", Legacy.AttachSecurityGroupRequest>;

export type User = Response<"UserPublic", Legacy.User>;
export type SessionResponse = Response<"SessionResponse", Legacy.SessionResponse>;
export type ClaimInfoResponse = Response<"ClaimInfoResponse", Legacy.ClaimInfoResponse>;
export type AdminCreateUserRequest = Request<"AdminCreateUserRequest", Legacy.AdminCreateUserRequest>;
export type AdminCreateUserResponse = Response<"AdminCreateUserResponse", Legacy.AdminCreateUserResponse>;
export type CreateUserRequest = Request<"SelfRegisterUserRequest", Legacy.CreateUserRequest>;
export type UpdateUserRequest = Request<"UpdateUserRequest", Legacy.UpdateUserRequest>;
export type Passkey = Response<"PasskeySummary", Legacy.Passkey>;
export type APIKey = Response<"APIKeySummary", Legacy.APIKey>;
export type CreateAPIKeyRequest = Request<"CreateAPIKeyRequest", Legacy.CreateAPIKeyRequest>;
export type CreateAPIKeyResponse = Response<"CreateAPIKeyResponse", Legacy.CreateAPIKeyResponse>;
export type CredentialRestriction = Response<"CredentialRestriction", Legacy.CredentialRestriction>;
export type PendingDeviceAuthorization = Response<"PendingDeviceAuthorization", Legacy.PendingDeviceAuthorization>;
export type CLISession = Response<"CLISessionSummary", Legacy.CLISession>;

export type Organization = Response<"OrganizationDetail", Legacy.Organization>;
export type OrganizationMember = Response<"OrganizationMember", Legacy.OrganizationMember>;
export type CreateOrganizationRequest = Request<"CreateOrganizationRequest", Legacy.CreateOrganizationRequest>;
export type UpdateOrganizationRequest = Request<"UpdateOrganizationRequest", Legacy.UpdateOrganizationRequest>;
export type Group = Response<"GroupDetail", Legacy.Group>;
export type GroupMember = Response<"GroupMember", Legacy.GroupMember>;
export type CreateGroupRequest = Request<"CreateGroupRequest", Legacy.CreateGroupRequest>;
export type UpdateGroupRequest = Request<"UpdateGroupRequest", Legacy.UpdateGroupRequest>;
export type OrganizationHierarchy = Response<"OrganizationHierarchy", Legacy.OrganizationHierarchy>;
export type HierarchySearchResponse = Response<"HierarchySearchResults", Legacy.HierarchySearchResponse>;

export type ProjectMembers = Response<"ProjectMembers", Legacy.ProjectMembers>;
export type ProjectVMPrincipal = Response<"ProjectVMPrincipal", Legacy.ProjectVMPrincipal>;
export type VMProjectGrantResponse = Response<"VMProjectGrantResponse", Legacy.VMProjectGrantResponse>;
export type ProjectRole = Schema<"ProjectMemberRoleInput"> & Legacy.ProjectRole;

export type Agent = Response<"AgentDetail", Legacy.Agent>;
export type AgentEnrollment = Response<"AgentEnrollmentDetail", Legacy.AgentEnrollment>;
export type AgentUpdateResult = Response<"AgentUpdateResult", Legacy.AgentUpdateResult>;
export type AdoptWorkloadsResult = Response<"AdoptWorkloadsResult", Legacy.AdoptWorkloadsResult>;
export type CreateAgentEnrollmentRequest = Request<"CreateAgentEnrollmentRequest", Legacy.CreateAgentEnrollmentRequest>;
export type StorageDevice = Response<"StorageDevice", Legacy.StorageDevice>;
export type UpdateStorageDeviceRequest = Request<"UpdateStorageDeviceRequest", Legacy.UpdateStorageDeviceRequest>;
export type Site = Response<"SiteDetail", Legacy.Site>;
export type CreateSiteRequest = Request<"CreateSiteRequest", Legacy.CreateSiteRequest>;
export type UpdateSiteRequest = Request<"UpdateSiteRequest", Legacy.UpdateSiteRequest>;

export type ResourceQuota = Response<"ResourceQuota", Legacy.ResourceQuota>;
export type CreateQuotaRequest = Request<"CreateResourceQuotaRequest", Legacy.CreateQuotaRequest>;
export type UpdateQuotaRequest = Request<"UpdateResourceQuotaRequest", Legacy.UpdateQuotaRequest>;
export type WorkloadIdentityOverview = Response<"WorkloadIdentityOverview", Legacy.WorkloadIdentityOverview>;
export type Operation = Response<"ResourceOperation", Legacy.Operation>;
export type AuditEventListResponse = Response<"AuditEventListResponse", Legacy.AuditEventListResponse>;

export type ActionCheckItem = Response<"IAMActionCheckItem", Legacy.ActionCheckItem>;
export type ActionCheckResponse = Response<"IAMActionCheckResponse", Legacy.ActionCheckResponse>;
export type GrantWriteResponse = Response<"IAMGrantWriteResponse", Legacy.GrantWriteResponse>;
export type IAMNodeType = Schema<"IAMNodeType"> & Legacy.IAMNodeType;
export type IAMRole = Response<"IAMRole", Legacy.IAMRole>;
export type IAMRoleListResponse = Response<"IAMRoleListResponse", Legacy.IAMRoleListResponse>;
export type IAMBindableRolesResponse = Response<"IAMBindableRolesResponse", Legacy.IAMBindableRolesResponse>;
export type IAMRoleOwnerType = Schema<"IAMRoleOwnerType"> & Legacy.IAMRoleOwnerType;
export type IAMRoleCreateRequest = Request<"IAMRoleCreateRequest", Legacy.IAMRoleCreateRequest>;
export type IAMRoleUpdateRequest = Request<"IAMRoleUpdateRequest", Legacy.IAMRoleUpdateRequest>;
export type IAMRoleValidateRequest = Request<"IAMRoleValidateRequest", Legacy.IAMRoleValidateRequest>;
export type IAMRoleValidateResponse = Response<"IAMRoleValidateResponse", Legacy.IAMRoleValidateResponse>;
export type IAMPolicy = Response<"IAMPolicy", Legacy.IAMPolicy>;
export type IAMPolicyListResponse = Response<"IAMPolicyListResponse", Legacy.IAMPolicyListResponse>;
export type IAMPolicyCreateRequest = Request<"IAMPolicyCreateRequest", Legacy.IAMPolicyCreateRequest>;
export type IAMPolicyUpdateRequest = Request<"IAMPolicyUpdateRequest", Legacy.IAMPolicyUpdateRequest>;
export type IAMPolicyValidateRequest = Request<"IAMPolicyValidateRequest", Legacy.IAMPolicyValidateRequest>;
export type IAMPolicyValidateResponse = Response<"IAMPolicyValidateResponse", Legacy.IAMPolicyValidateResponse>;
export type IAMActionCatalogResponse = Response<"IAMActionCatalogResponse", Legacy.IAMActionCatalogResponse>;

export type OIDCProvider = Response<"OIDCProviderConfig", Legacy.OIDCProvider>;
export type CreateOIDCProviderRequest = Request<"CreateOIDCProviderRequest", Legacy.CreateOIDCProviderRequest>;
export type UpdateOIDCProviderRequest = Request<"UpdateOIDCProviderRequest", Legacy.UpdateOIDCProviderRequest>;
export type OIDCProviderTestResult = Response<"OIDCProviderTestResult", Legacy.OIDCProviderTestResult>;
export type SSOLookupResponse = Response<"SSOLookupResult", Legacy.SSOLookupResponse>;
export type RegistrationPolicy = Response<"RegistrationPolicy", Legacy.RegistrationPolicy>;

export type SCIMToken = Response<"SCIMTokenSummary", Legacy.SCIMToken>;
export type CreateSCIMTokenRequest = Request<"CreateSCIMTokenRequest", Legacy.CreateSCIMTokenRequest>;
export type CreateSCIMTokenResponse = Response<"CreateSCIMTokenResult", Legacy.CreateSCIMTokenResponse>;
export type UpdateSCIMTokenRequest = Request<"UpdateSCIMTokenRequest", Legacy.UpdateSCIMTokenRequest>;
export type SSFStream = Response<"SSFStream", Legacy.SSFStream>;
export type CreateSSFStreamRequest = Request<"CreateSSFStreamRequest", Legacy.CreateSSFStreamRequest>;
export type UpdateSSFStreamRequest = Request<"UpdateSSFStreamRequest", Legacy.UpdateSSFStreamRequest>;
export type RegisterSSFStreamResponse = Response<"RegisterSSFStreamResult", Legacy.RegisterSSFStreamResponse>;
export type SSFStreamStatus = Response<"SSFStreamStatus", Legacy.SSFStreamStatus>;
export type SSFPollResult = Response<"SSFPollResult", Legacy.SSFPollResult>;
export type WebhookSubscription = Response<"WebhookSubscription", Legacy.WebhookSubscription>;
export type WebhookWithSecret = Response<"WebhookWithSecret", Legacy.WebhookWithSecret>;
export type WebhookDelivery = Response<"WebhookDelivery", Legacy.WebhookDelivery>;
export type CreateWebhookRequest = Request<"CreateWebhookRequest", Legacy.CreateWebhookRequest>;
export type UpdateWebhookRequest = Request<"UpdateWebhookRequest", Legacy.UpdateWebhookRequest>;

// Client-side helpers that do not represent a single OpenAPI schema.
export type AcceptedMutation<Resource> = Legacy.AcceptedMutation<Resource>;
export type Page<Resource> = Legacy.Page<Resource>;
export type LogQueryParams = Legacy.LogQueryParams;
export type VMLogsQueryParams = Legacy.VMLogsQueryParams;
export type SandboxLogsQueryParams = Legacy.SandboxLogsQueryParams;
export type VMLogEntry = Response<"LogEntry", Legacy.VMLogEntry>;
export type SandboxLogEntry = Response<"LogEntry", Legacy.SandboxLogEntry>;
