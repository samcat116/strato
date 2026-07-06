// API Types - matches Vapor backend response types

export interface User {
  id: string;
  username: string;
  email: string;
  displayName: string;
  createdAt: string;
  currentOrganizationId?: string;
  isSystemAdmin: boolean;
}

export interface CreateUserRequest {
  username: string;
  email: string;
  displayName: string;
}

export interface UpdateUserRequest {
  displayName?: string;
  email?: string;
}

export type VMStatus =
  | "Running"
  | "Shutdown"
  | "Paused"
  | "Created"
  | "Starting"
  | "Stopping"
  | "Error"
  | "Unknown";

export interface VM {
  id: string;
  name: string;
  description: string;
  image: string;
  imageId?: string;
  projectId?: string;
  status: VMStatus;
  hypervisorId?: string;
  cpu: number;
  maxCpu: number;
  memory: number;
  memoryFormatted: string;
  disk: number;
  diskFormatted: string;
  createdAt: string;
  updatedAt: string;
}

export interface Organization {
  id: string;
  name: string;
  description: string;
  createdAt: string;
  userRole?: string;
}

export interface OrganizationMember {
  id: string;
  username: string;
  displayName: string;
  email: string;
  role: string;
  joinedAt: string;
}

// Project-level roles
export type ProjectRole = "admin" | "member" | "viewer";

export interface ProjectMember {
  userId: string;
  username: string;
  displayName: string;
  email: string;
  role: ProjectRole;
  joinedAt: string | null;
}

export interface ProjectGroupGrant {
  groupId: string;
  name: string;
  role: ProjectRole;
  grantedAt: string | null;
}

export interface ProjectMembers {
  users: ProjectMember[];
  groups: ProjectGroupGrant[];
}

// Batch permission check ("can I?")
export interface PermissionCheckItem {
  key: string;
  resourceType: string;
  resourceId: string;
  permission: string;
}

export interface PermissionCheckResponse {
  results: Record<string, boolean>;
}

// Groups
export interface Group {
  id: string;
  name: string;
  description: string;
  organizationId: string;
  memberCount?: number;
  createdAt?: string;
}

export interface GroupMember {
  id: string;
  username: string;
  displayName: string;
  email: string;
  joinedAt?: string;
}

export interface CreateGroupRequest {
  name: string;
  description: string;
}

export interface UpdateGroupRequest {
  name?: string;
  description?: string;
}

// Organizational Units
export interface OrganizationalUnit {
  id: string;
  name: string;
  description: string;
  organizationId: string;
  parentOuId?: string | null;
  path: string;
  depth: number;
  createdAt?: string;
  childOuCount?: number;
  projectCount?: number;
}

/** Recursive tree node returned by the OU `tree` endpoint. */
export interface OrganizationalUnitTree {
  id: string;
  name: string;
  description: string;
  path: string;
  depth: number;
  projectCount: number;
  children: OrganizationalUnitTree[];
}

export interface CreateOrganizationalUnitRequest {
  name: string;
  description: string;
  parentOuId?: string;
}

export interface UpdateOrganizationalUnitRequest {
  name?: string;
  description?: string;
}

export type AgentStatus = "online" | "offline" | "connecting" | "error";

export interface AgentResources {
  totalCPU: number;
  availableCPU: number;
  totalMemory: number;
  availableMemory: number;
  totalDisk: number;
  availableDisk: number;
}

export type HypervisorType = "qemu" | "firecracker";

export type CPUArchitecture = "x86_64" | "arm64";

export type NetworkCapability = "overlay" | "user_mode";

export interface HypervisorCapabilities {
  type: HypervisorType;
  supportsPause: boolean;
  supportsLiveMigration: boolean;
  supportsSnapshots: boolean;
  requiresDirectKernelBoot: boolean;
  maxVCPUs: number;
  maxMemory: number;
}

// One hypervisor on an agent host, with availability probed at agent startup.
export interface HypervisorSupport {
  type: HypervisorType;
  available: boolean;
  accelerated: boolean;
  unavailabilityReason?: string;
  capabilities: HypervisorCapabilities;
}

export interface Agent {
  id: string;
  name: string;
  hostname: string;
  version: string;
  capabilities: string[];
  status: AgentStatus;
  resources: AgentResources;
  architecture?: CPUArchitecture;
  hypervisors: HypervisorSupport[];
  networkCapability?: NetworkCapability;
  lastHeartbeat?: string;
  createdAt: string;
  isOnline: boolean;
}

// Returned only from the create endpoint — the plaintext `token` and the
// `registrationURL` that embeds it are shown exactly once.
export interface AgentRegistrationToken {
  id: string;
  token: string;
  agentName: string;
  expiresAt: string;
  registrationURL: string;
  isValid: boolean;
}

// Returned when listing tokens — the secret is intentionally absent.
export interface AgentRegistrationTokenListItem {
  id: string;
  agentName: string;
  expiresAt: string;
  isUsed: boolean;
  isValid: boolean;
  createdAt?: string;
  usedAt?: string;
}

export interface APIKey {
  id: string;
  name: string;
  keyPrefix: string;
  scopes: string[];
  isActive: boolean;
  createdAt: string;
  expiresAt?: string;
  lastUsedAt?: string;
}

/**
 * Response returned when creating an API key. The full `key` is only ever
 * returned here — it is never retrievable again after creation.
 */
export interface CreateAPIKeyResponse {
  id: string;
  name: string;
  key: string;
  keyPrefix: string;
  scopes: string[];
  expiresAt?: string;
  createdAt?: string;
}

export interface SessionResponse {
  user: User;
}

// SCIM provisioning tokens (org-scoped, admin only)
export interface SCIMToken {
  id: string;
  name: string;
  tokenPrefix: string;
  organizationId: string;
  isActive: boolean;
  expiresAt?: string;
  lastUsedAt?: string;
  createdAt?: string;
}

export interface CreateSCIMTokenRequest {
  name: string;
  expiresInDays?: number;
}

/**
 * Response returned when creating a SCIM token. The full `token` is only ever
 * returned here — it is never retrievable again after creation.
 */
export interface CreateSCIMTokenResponse {
  id: string;
  name: string;
  token: string;
  tokenPrefix: string;
  organizationId: string;
  expiresAt?: string;
  createdAt?: string;
}

export interface UpdateSCIMTokenRequest {
  name?: string;
  isActive?: boolean;
}

// Request types
export interface CreateVMRequest {
  name: string;
  description?: string;
  /** @deprecated Use imageId instead */
  templateName?: string;
  imageId?: string;
  projectId?: string;
  environment?: string;
  cpu?: number;
  memory?: number;
  disk?: number;
  /** SSH public key authorized for the guest's default user (cloud-init). */
  sshPublicKey?: string;
}

export interface UpdateVMRequest {
  name?: string;
  description?: string;
}

// Async VM operations: lifecycle mutations return 202 Accepted with an
// Operation record, which the client polls until it reaches a terminal state.
export type OperationKind =
  | "create"
  | "boot"
  | "shutdown"
  | "reboot"
  | "pause"
  | "resume"
  | "delete";

export type OperationStatus = "pending" | "succeeded" | "failed";

export interface Operation {
  id: string;
  vmId: string;
  kind: OperationKind;
  status: OperationStatus;
  error?: string | null;
  createdAt?: string | null;
  completedAt?: string | null;
}

export interface CreateOrganizationRequest {
  name: string;
  description?: string;
}

export interface UpdateOrganizationRequest {
  name?: string;
  description?: string;
}

export interface CreateAPIKeyRequest {
  name: string;
  scopes?: string[];
  expiresInDays?: number;
}

export interface CreateAgentRegistrationTokenRequest {
  agentName: string;
  expirationHours?: number;
}

// Image types
export type ImageStatus =
  | "pending"
  | "uploading"
  | "downloading"
  | "validating"
  | "ready"
  | "error";

export type ImageFormat = "qcow2" | "raw";

export type ArtifactKind = "disk-image" | "kernel" | "initramfs" | "rootfs";

export interface ImageArtifact {
  id?: string;
  kind: ArtifactKind;
  format?: ImageFormat;
  architecture: CPUArchitecture;
  filename: string;
  size: number;
  checksum: string;
}

export interface Image {
  id?: string;
  name: string;
  description: string;
  projectId?: string;
  filename: string;
  size: number;
  sizeFormatted: string;
  format: ImageFormat;
  architecture: CPUArchitecture;
  checksum?: string;
  status: ImageStatus;
  sourceURL?: string;
  downloadProgress?: number;
  errorMessage?: string;
  defaultCpu?: number;
  defaultMemory?: number;
  defaultDisk?: number;
  defaultCmdline?: string;
  artifacts: ImageArtifact[];
  compatibleHypervisors: HypervisorType[];
  uploadedById?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateImageRequest {
  name: string;
  description?: string;
  sourceURL?: string;
  architecture?: CPUArchitecture;
  defaultCpu?: number;
  defaultMemory?: number;
  defaultDisk?: number;
  defaultCmdline?: string;
}

export interface UpdateImageRequest {
  name?: string;
  description?: string;
  architecture?: CPUArchitecture;
  defaultCpu?: number;
  defaultMemory?: number;
  defaultDisk?: number;
  defaultCmdline?: string;
}

export interface ImageStatusResponse {
  id: string;
  status: ImageStatus;
  downloadProgress?: number;
  errorMessage?: string;
  size?: number;
  checksum?: string;
}

// Volume types
export type VolumeStatus =
  | "creating"
  | "available"
  | "attaching"
  | "attached"
  | "detaching"
  | "resizing"
  | "snapshotting"
  | "cloning"
  | "deleting"
  | "error";

export type VolumeFormat = "qcow2" | "raw";

export type VolumeType = "boot" | "data";

export interface Volume {
  id?: string;
  name: string;
  description: string;
  projectId?: string;
  size: number;
  sizeFormatted: string;
  format: VolumeFormat;
  volumeType: VolumeType;
  status: VolumeStatus;
  errorMessage?: string;
  hypervisorId?: string;
  vmId?: string;
  deviceName?: string;
  bootOrder?: number;
  sourceImageId?: string;
  sourceVolumeId?: string;
  createdById?: string;
  createdAt?: string;
  updatedAt?: string;
}

export type SnapshotStatus =
  | "creating"
  | "available"
  | "restoring"
  | "deleting"
  | "error";

export interface VolumeSnapshot {
  id?: string;
  name: string;
  description: string;
  volumeId?: string;
  projectId?: string;
  size: number;
  sizeFormatted: string;
  status: SnapshotStatus;
  errorMessage?: string;
  createdById?: string;
  createdAt?: string;
}

export interface CreateVolumeRequest {
  name: string;
  description?: string;
  projectId?: string;
  sizeGB: number;
  format?: VolumeFormat;
  volumeType?: VolumeType;
  sourceImageId?: string;
}

export interface UpdateVolumeRequest {
  name?: string;
  description?: string;
}

export interface AttachVolumeRequest {
  vmId: string;
  deviceName?: string;
  bootOrder?: number;
  readonly?: boolean;
}

export interface ResizeVolumeRequest {
  sizeGB: number;
}

export interface CloneVolumeRequest {
  name: string;
  description?: string;
}

export interface CreateVolumeSnapshotRequest {
  name: string;
  description?: string;
}

// VM Log types
export type VMLogLevel = "debug" | "info" | "warning" | "error";
export type VMLogSource = "agent" | "qemu" | "control_plane";
export type VMEventType =
  | "status_change"
  | "operation"
  | "qemu_output"
  | "error"
  | "info";

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

export interface VMLogsQueryParams {
  limit?: number;
  direction?: "forward" | "backward";
  start?: number; // Unix timestamp
  end?: number; // Unix timestamp
}

// Resource Quotas
export type QuotaEntityType = "organization" | "ou" | "project";

export interface QuotaLimits {
  maxVCPUs: number;
  maxMemoryGB: number;
  maxStorageGB: number;
  maxVMs: number;
  maxNetworks: number;
}

export interface QuotaReservedUsage {
  reservedVCPUs: number;
  reservedMemoryGB: number;
  reservedStorageGB: number;
  vmCount: number;
  networkCount: number;
}

export interface QuotaUtilization {
  cpuPercent: number;
  memoryPercent: number;
  storagePercent: number;
  vmPercent: number;
}

export interface ResourceQuota {
  id: string;
  name: string;
  entityType: QuotaEntityType;
  entityId: string;
  environment?: string;
  isEnabled: boolean;
  limits: QuotaLimits;
  usage: QuotaReservedUsage;
  utilization: QuotaUtilization;
  createdAt?: string;
}

export interface CreateQuotaRequest {
  name: string;
  maxVCPUs: number;
  maxMemoryGB: number;
  maxStorageGB: number;
  maxVMs: number;
  maxNetworks?: number;
  environment?: string;
  isEnabled?: boolean;
}

export interface UpdateQuotaRequest {
  name?: string;
  maxVCPUs?: number;
  maxMemoryGB?: number;
  maxStorageGB?: number;
  maxVMs?: number;
  maxNetworks?: number;
  isEnabled?: boolean;
}

// Hierarchy
export interface VMSummaryNode {
  id: string;
  name: string;
  environment: string;
  status: string;
  cpu: number;
  memoryGB: number;
  diskGB: number;
}

export interface ProjectNode {
  id: string;
  name: string;
  description: string;
  path: string;
  environments: string[];
  defaultEnvironment: string;
  vms: VMSummaryNode[];
  quotas: ResourceQuota[];
}

export interface OrganizationalUnitNode {
  id: string;
  name: string;
  description: string;
  path: string;
  depth: number;
  childOUs: OrganizationalUnitNode[];
  projects: ProjectNode[];
  quotas: ResourceQuota[];
}

export interface OrganizationNode {
  id: string;
  name: string;
  description: string;
  organizationalUnits: OrganizationalUnitNode[];
  projects: ProjectNode[];
  quotas: ResourceQuota[];
}

export interface HierarchyResourceUsage {
  totalVCPUs: number;
  totalMemoryGB: number;
  totalStorageGB: number;
  totalVMs: number;
}

export interface HierarchyStats {
  totalOUs: number;
  totalProjects: number;
  totalVMs: number;
  totalQuotas: number;
  maxDepth: number;
  resourceUtilization: HierarchyResourceUsage;
}

export interface OrganizationHierarchy {
  organization: OrganizationNode;
  stats: HierarchyStats;
}

export interface HierarchySearchResult {
  id: string;
  name: string;
  type: string;
  path: string;
  description: string;
  parentId?: string;
  parentType?: string;
}

export interface HierarchySearchResponse {
  query: string;
  organizationId?: string;
  results: HierarchySearchResult[];
  totalResults: number;
}
