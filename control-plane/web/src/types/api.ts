// API Types - matches Vapor backend response types

/** How a user account came into existence (see backend UserSource). */
export type UserSource = "local" | "scim" | "oidc";

export interface User {
  id: string;
  username: string;
  email: string;
  displayName: string;
  createdAt: string;
  currentOrganizationId?: string;
  isSystemAdmin: boolean;
  source: UserSource;
}

export interface CreateUserRequest {
  username: string;
  email: string;
  displayName: string;
}

/** Admin-only user creation (mints a passkey-claim invite). */
export interface AdminCreateUserRequest {
  username: string;
  email: string;
  displayName: string;
  isSystemAdmin?: boolean;
  /** Optional org to provision the invitee into up front. */
  organizationId?: string;
  /** Org role for `organizationId` — "admin" or "member". */
  role?: string;
}

export interface AdminCreateUserResponse {
  user: User;
  /** Raw claim token — shown once. */
  claimToken: string;
  /** Server-built claim URL (may be rebuilt from window.location.origin). */
  claimUrl: string;
  claimExpiresAt?: string;
}

export interface ClaimInfoResponse {
  username: string;
  displayName: string;
  valid: boolean;
  alreadyClaimed: boolean;
  expired: boolean;
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

export interface InterfaceAddress {
  family: "ipv4" | "ipv6";
  address: string;
  prefixLength: number;
  gateway?: string;
}

export interface VMNetworkInterface {
  id?: string;
  network: string;
  macAddress: string;
  /** All addresses on the NIC, one per family on a dual-stack network. */
  addresses?: InterfaceAddress[];
  mtu?: number;
  deviceName: string;
  orderIndex: number;
}

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
  networkInterfaces: VMNetworkInterface[];
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

// Descriptive hardware/platform/OS details the agent reports at registration,
// for operator display. Purely informational; every field is best-effort, so
// any of them may be absent.
export interface HostInfo {
  // OS product/distribution name including version, e.g. "Ubuntu 24.04.1 LTS".
  osName?: string;
  // Kernel release (`uname -r`), e.g. "6.8.0-45-generic".
  kernelVersion?: string;
  // CPU brand/model string, e.g. "Apple M2 Pro".
  cpuModel?: string;
  // CPU vendor, e.g. "GenuineIntel", "AuthenticAMD", "Apple".
  cpuVendor?: string;
  // Physical CPU cores (distinct from logical/hyperthreaded cores).
  physicalCoreCount?: number;
  // Logical CPU cores (hardware threads).
  logicalCoreCount?: number;
  // Total physical memory in bytes.
  totalMemoryBytes?: number;
  // Machine/hardware model, e.g. "MacBookPro18,3" or "PowerEdge R650".
  machineModel?: string;
  // ISO timestamp of the host's last boot.
  bootTime?: string;
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
  // Host OS ("linux" | "macos"); absent for agents that haven't re-registered
  // with a build that reports it.
  operatingSystem?: string;
  hypervisors: HypervisorSupport[];
  networkCapability?: NetworkCapability;
  // Descriptive hardware/platform/OS details for display; absent for agents
  // that haven't re-registered with a build that reports it.
  hostInfo?: HostInfo;
  siteId?: string;
  organizationId?: string;
  organizationalUnitId?: string;
  lastHeartbeat?: string;
  createdAt: string;
  isOnline: boolean;
  // The version this agent should be running (the control plane's own build
  // version, or its AGENT_TARGET_VERSION override); absent for dev builds.
  targetVersion?: string;
  updateAvailable: boolean;
  // Declarative auto-update enrollment and rollout state (issue #434).
  autoUpdate: boolean;
  // The version the fleet rollout has assigned this agent, while it is
  // converging; absent once converged (or never assigned).
  updateDesiredVersion?: string;
  updateAttemptedAt?: string;
  // The agent's self-reported reason for not converging yet.
  updateBlockedReason?: string;
  // Terminal failure that halted the rollout at this agent, if any.
  updateFailureReason?: string;
}

// Result of POST /api/agents/:id/actions/update — the agent has verified and
// installed the new binary and is restarting into it.
export interface AgentUpdateResult {
  status: string;
  targetVersion: string;
  artifactUrl: string;
  message?: string;
}

// Returned only from the create endpoint — the SPIRE join token embedded in
// `bootstrapCommand` is shown exactly once and never re-exposed.
export interface AgentEnrollment {
  id: string;
  agentName: string;
  spiffeId: string;
  expiresAt: string;
  spire: SPIREProvisioning;
  bootstrapCommand: string;
}

export interface SPIREProvisioning {
  joinToken: string;
  joinTokenExpiresAt: string;
  spiffeId: string;
  nodeId: string;
  trustDomain: string;
  serverAddress: string;
}

// Returned when listing enrollments — the join token is intentionally absent.
export interface AgentEnrollmentListItem {
  id: string;
  agentName: string;
  spiffeId: string;
  expiresAt: string;
  isUsed: boolean;
  isValid: boolean;
  organizationId?: string;
  organizationalUnitId?: string;
  createdAt?: string;
  usedAt?: string;
}

export interface Site {
  id: string;
  name: string;
  description?: string;
  networkControllerAgentId?: string;
  organizationId?: string;
  organizationalUnitId?: string;
  createdAt?: string;
}

export interface CreateSiteRequest {
  name: string;
  description?: string;
  organizationId?: string;
  organizationalUnitId?: string;
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

// OIDC / SSO providers (org-scoped; managed by org admins)
export interface OIDCProvider {
  id: string;
  name: string;
  clientID: string;
  discoveryURL?: string | null;
  authorizationEndpoint?: string | null;
  tokenEndpoint?: string | null;
  userinfoEndpoint?: string | null;
  jwksURI?: string | null;
  endSessionEndpoint?: string | null;
  scopes: string[];
  enabled: boolean;
  /** Send + require the OIDC nonce. Disable for IdPs (e.g. Discord) that don't echo it. */
  useNonce: boolean;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateOIDCProviderRequest {
  name: string;
  clientID: string;
  clientSecret: string;
  discoveryURL?: string;
  authorizationEndpoint?: string;
  tokenEndpoint?: string;
  userinfoEndpoint?: string;
  jwksURI?: string;
  endSessionEndpoint?: string;
  scopes?: string[];
  enabled?: boolean;
  useNonce?: boolean;
}

export interface UpdateOIDCProviderRequest {
  name?: string;
  clientID?: string;
  clientSecret?: string;
  discoveryURL?: string;
  authorizationEndpoint?: string;
  tokenEndpoint?: string;
  userinfoEndpoint?: string;
  jwksURI?: string;
  endSessionEndpoint?: string;
  scopes?: string[];
  enabled?: boolean;
  useNonce?: boolean;
}

export interface OIDCProviderTestResult {
  valid: boolean;
  message: string;
}

/** Minimal provider info exposed to the (unauthenticated) login page. */
export interface PublicOIDCProvider {
  id: string;
  name: string;
  enabled: boolean;
}

/**
 * Login-page SSO discovery. `organizationID` is null/absent when the
 * organization doesn't exist or has no enabled providers.
 */
export interface SSOLookupResponse {
  organizationID?: string | null;
  providers: PublicOIDCProvider[];
}

// Shared Signals Framework receiver streams (org-scoped; managed by org admins)
export interface SSFStream {
  id: string;
  organizationId: string;
  name: string;
  description?: string | null;
  transmitterURL: string;
  expectedIssuer?: string | null;
  expectedAudience: string[];
  deliveryMethod: "push" | "poll";
  eventsRequested: string[];
  remoteStreamID?: string | null;
  pollEndpoint?: string | null;
  pushEndpoint?: string | null;
  pushTokenPrefix?: string | null;
  enabled: boolean;
  registered: boolean;
  verifiedAt?: string | null;
  lastEventAt?: string | null;
  lastError?: string | null;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateSSFStreamRequest {
  name: string;
  description?: string;
  transmitterURL: string;
  authToken?: string;
  expectedIssuer?: string;
  expectedAudience?: string[];
  deliveryMethod: "push" | "poll";
  eventsRequested?: string[];
}

export interface UpdateSSFStreamRequest {
  name?: string;
  description?: string;
  authToken?: string;
  expectedIssuer?: string;
  expectedAudience?: string[];
  eventsRequested?: string[];
  enabled?: boolean;
}

/**
 * Response returned when registering a stream at its transmitter. For push
 * streams, `pushToken` is only ever returned here — it is stored hashed and
 * never retrievable again.
 */
export interface RegisterSSFStreamResponse {
  stream: SSFStream;
  pushToken?: string | null;
}

export interface SSFStreamStatus {
  remoteStreamID: string;
  status: string;
  reason?: string | null;
}

export interface SSFPollResult {
  processed: number;
  failed: number;
  moreAvailable: boolean;
}

// Request types
export interface CreateVMRequest {
  name: string;
  description?: string;
  imageId: string;
  projectId?: string;
  environment?: string;
  cpu?: number;
  memory?: number;
  disk?: number;
  /** Logical network the VM's NIC attaches to; defaults to the "default" network. */
  networkId?: string;
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
  | "delete"
  // Sandbox checkpoint/restore (backend issue #426).
  | "snapshot"
  | "snapshot_delete"
  | "restore";

export type OperationStatus = "pending" | "succeeded" | "failed";

// The resource an operation targets. Operations are shared machinery across VMs
// and sandboxes (backend issue #412), discriminated by `resourceKind`.
export type OperationResourceKind = "virtual_machine" | "sandbox";

export interface Operation {
  id: string;
  /** Legacy alias for `resourceId`, kept by the backend; equals the VM or sandbox id. */
  vmId: string;
  /** Discriminates whether the operation targets a VM or a sandbox. */
  resourceKind: OperationResourceKind;
  /** The targeted resource's id (VM or sandbox); prefer this over `vmId`. */
  resourceId: string;
  kind: OperationKind;
  status: OperationStatus;
  error?: string | null;
  createdAt?: string | null;
  completedAt?: string | null;
}

// Sandboxes: OCI-image Firecracker microVMs (backend issue #413). A resource
// surface parallel to VMs, not a VM variant — own table, own API, own status.
export type SandboxStatus =
  | "Stopped"
  | "Running"
  // The workload ran and ended on its own; `exitCode` carries the result.
  | "Exited"
  | "Starting"
  | "Stopping"
  | "Error"
  | "Unknown";

export interface Sandbox {
  id: string;
  name: string;
  projectId?: string;
  environment: string;
  /** OCI image reference as provided, e.g. `ghcr.io/acme/worker:v3`. */
  image: string;
  /** Manifest digest (`sha256:...`) the reference resolved to; null until resolved. */
  imageDigest?: string | null;
  cpus: number;
  /** Guest memory in bytes. */
  memory: number;
  /** Entrypoint override; null means use the image config's entrypoint. */
  entrypoint?: string[] | null;
  /** Command (args) override; null means use the image config's cmd. */
  cmd?: string[] | null;
  /** Environment variable overrides, merged over the image config's env. */
  env: Record<string, string>;
  workingDir?: string | null;
  /** Lifetime budget in seconds, counted from `createdAt`. */
  ttlSeconds?: number | null;
  /** When the TTL runs out and the sandbox is auto-deleted; null without a TTL. */
  expiresAt?: string | null;
  hypervisorId?: string | null;
  /** Snapshot lineage for a sandbox created by fork (backend issue #427). */
  restoredFromSnapshotId?: string | null;
  status: SandboxStatus;
  /** Exit code of a workload that ran to completion (`status === "Exited"`). */
  exitCode?: number | null;
  createdAt: string;
  updatedAt: string;
}

export interface CreateSandboxRequest {
  name: string;
  /** OCI image reference; required unless restoreFrom is present. */
  image?: string;
  /** Ready sandbox snapshot to restore as a new sandbox identity. */
  restoreFrom?: string;
  projectId?: string;
  environment?: string;
  cpus?: number;
  /** Guest memory in bytes. */
  memory?: number;
  entrypoint?: string[];
  cmd?: string[];
  env?: Record<string, string>;
  workingDir?: string;
  ttlSeconds?: number;
}

export type SandboxSnapshotStatus =
  | "creating"
  | "ready"
  | "deleting"
  | "error";

export interface SandboxSnapshot {
  id: string;
  name: string;
  sandboxId: string;
  projectId: string;
  status: SandboxSnapshotStatus;
  size?: number | null;
  agentId?: string | null;
  firecrackerVersion?: string | null;
  architecture?: string | null;
  errorMessage?: string | null;
  createdById?: string | null;
  createdAt?: string | null;
}

export interface UpdateSandboxRequest {
  name?: string;
  ttlSeconds?: number;
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
}

export interface SandboxExecSession {
  sessionId: string;
  /** Same-origin WebSocket path, e.g. `/api/sandboxes/<id>/exec/<sessionId>/attach`. */
  websocketPath: string;
  /** When the pending (unattached) session expires. */
  expiresAt: string;
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

export interface SandboxLogsQueryParams {
  limit?: number;
  direction?: "forward" | "backward";
  start?: number; // Unix timestamp
  end?: number; // Unix timestamp
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

export interface CreateAgentEnrollmentRequest {
  agentName: string;
  expirationHours?: number;
  siteId?: string;
  // Owning scope the agent becomes dedicated to; exactly one is required.
  organizationId?: string;
  organizationalUnitId?: string;
}

// Image types
export type ImageStatus =
  | "pending"
  | "uploading"
  | "downloading"
  | "validating"
  | "ready"
  | "error";

export type ImageFormat = "qcow2" | "raw" | "vmdk" | "vhd" | "vhdx";

export type ArtifactKind = "disk-image" | "kernel" | "initramfs" | "rootfs";

export type ArtifactStatus = "pending" | "downloading" | "ready" | "error";

export interface ImageArtifact {
  id?: string;
  kind: ArtifactKind;
  format?: ImageFormat;
  architecture: CPUArchitecture;
  filename: string;
  size: number;
  checksum: string;
  status: ArtifactStatus;
  sourceURL?: string;
  downloadProgress?: number;
  errorMessage?: string;
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
  /** Optional SHA-256 (64 hex chars) the download must match, for URL imports.
   *  A mismatch fails the image rather than publishing it. */
  checksum?: string;
  /** Explicit disk format for uploads. Omit to let the server detect it from
   *  the file header; only meaningful on the multipart upload path. */
  format?: ImageFormat;
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

// Networks

export interface Network {
  id?: string;
  name: string;
  subnet: string;
  gateway?: string;
  /** IPv6 subnet (always a /64) when the network is dual-stack. */
  subnet6?: string;
  gateway6?: string;
  projectId?: string;
  /** The seeded global "default" network, which cannot be renamed or deleted. */
  isDefault: boolean;
  /** Number of VM interfaces attached; a network in use cannot be deleted. */
  attachedInterfaceCount: number;
  /** Whether agents program OVN's DHCP responder to configure guests. */
  dhcpEnabled: boolean;
  /** DNS resolvers advertised to guests over DHCP. */
  dnsServers: string[];
  /** DNS search domain advertised over DHCP. */
  domainName?: string;
  /** DHCP lease time in seconds. */
  leaseTime?: number;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateNetworkRequest {
  name: string;
  subnet: string;
  gateway?: string;
  /** Explicit IPv6 /64; omitted → the server generates a ULA (dual-stack default). */
  subnet6?: string;
  gateway6?: string;
  /** false → v4-only network. */
  ipv6Enabled?: boolean;
  projectId?: string;
  dhcpEnabled?: boolean;
  dnsServers?: string[];
  domainName?: string;
  leaseTime?: number;
}

export interface UpdateNetworkRequest {
  name?: string;
  subnet?: string;
  gateway?: string;
  subnet6?: string;
  gateway6?: string;
  /** true with no subnet6 → enable IPv6 with a generated ULA; false → remove IPv6. */
  ipv6Enabled?: boolean;
  dhcpEnabled?: boolean;
  dnsServers?: string[];
  domainName?: string;
  leaseTime?: number;
}

// Audit events (system-admin / org-admin trail)

export interface AuditEvent {
  id: string;
  eventType: string;
  userID?: string;
  /** Username snapshot at event time; survives user deletion/rename. */
  username?: string;
  apiKeyID?: string;
  organizationID?: string;
  method?: string;
  path?: string;
  status?: number;
  resourceType?: string;
  resourceID?: string;
  action?: string;
  sourceIP?: string;
  /** True when the request was served via the system-admin permission bypass. */
  adminBypass: boolean;
  metadata?: Record<string, string>;
  createdAt?: string;
}

export interface AuditEventListResponse {
  events: AuditEvent[];
  total: number;
  limit: number;
  offset: number;
}

// Workload Identity (SPIFFE / SPIRE) — matches WorkloadIdentityController DTOs.

/** SVID kinds an entry issues. */
export type SVIDType = "x509" | "jwt";

export interface WorkloadRegistrationEntry {
  id: string;
  /** Full identity, e.g. `spiffe://strato.prod/db/primary`. */
  spiffeID: string;
  /** Path portion after the trust domain, e.g. `/db/primary`. */
  path: string;
  /** Parent identity (SPIRE server for node entries, or a node ID). */
  parentID: string;
  /** Short node name derived from `parentID` (e.g. `agent-1`), best-effort. */
  node?: string;
  /** Selectors formatted as `type:value`. */
  selectors: string[];
  svidTypes: SVIDType[];
  x509TTLSeconds: number;
  jwtTTLSeconds: number;
  federatesWith: string[];
  admin: boolean;
  downstream: boolean;
  hint?: string;
  expiresAt?: string;
  createdAt?: string;
}

/** Attested nodes summarized by attestation method. */
export interface NodeAttestationGroup {
  attestationType: string;
  count: number;
  banned: number;
}

export interface TrustBundleInfo {
  trustDomain: string;
  x509AuthorityCount: number;
  refreshedAt: string;
  sequenceNumber: number;
}

export interface FederatedDomain {
  trustDomain: string;
  /** `synced` | `refresh_failed` | `unknown`. */
  state: "synced" | "refresh_failed" | "unknown";
}

/**
 * Federation relationships. When `available` is true, `domains` are the trust
 * domain's configured relationships with real sync state from SPIRE; when
 * false (unconfigured, or the trustdomain API was unreachable) `domains`
 * degrades to the trust domains entries federate with, with `state: unknown`.
 */
export interface FederationInfo {
  available: boolean;
  domains: FederatedDomain[];
}

/** SVID issuance metrics read from the configured metrics store; `available`
 * is false when no source is wired or the query failed. */
export interface IssuanceInfo {
  available: boolean;
  windowHours: number;
  x509SVIDs?: number;
  jwtSVIDs?: number;
}

export interface WorkloadIdentityOverview {
  /** Whether SPIRE is configured on this control plane. */
  enabled: boolean;
  trustDomain?: string;
  entries: WorkloadRegistrationEntry[];
  nodeAttestation: NodeAttestationGroup[];
  trustBundle?: TrustBundleInfo;
  federation: FederationInfo;
  issuance: IssuanceInfo;
  /** Non-fatal problem reaching the SPIRE server, if any. */
  warning?: string;
}
