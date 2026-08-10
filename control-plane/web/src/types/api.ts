// API Types - matches Vapor backend response types

/** Paged envelope returned by every resource list endpoint (issue #700). */
export interface Page<T> {
  items: T[];
  /** Total rows the caller may see, ignoring limit/offset. */
  total: number;
  limit: number;
  offset: number;
}

/**
 * The server-side page-size cap. List wrappers that still want "everything"
 * request one max-size page; adopting real pagination per view is follow-up
 * work.
 */
export const LIST_PAGE_LIMIT = "500";

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
  /** Canonical org role UUID for `organizationId`; omit for bare membership. */
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
  username?: string;
  displayName?: string;
  email?: string;
}

/** A registered WebAuthn credential, as returned by /api/users/me/passkeys. */
export interface Passkey {
  id: string;
  /** User-chosen label; null until the user names it. */
  name: string | null;
  deviceType: string;
  transports: string[];
  /** True for cloud-synced ("multi-device") passkeys. */
  backedUp: boolean;
  createdAt?: string;
  lastUsedAt?: string;
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

/**
 * An address the guest actually configured on a NIC, reported by the QEMU
 * guest agent (issue #563) — distinct from the allocated `InterfaceAddress`.
 * No gateway, and `prefixLength` is optional since qga doesn't always supply it.
 */
export interface ObservedInterfaceAddress {
  family: "ipv4" | "ipv6";
  address: string;
  prefixLength?: number;
}

export interface VMNetworkInterface {
  id?: string;
  /** The logical network this NIC attaches to. */
  networkId: string;
  /**
   * Display name of that network. Present only when the response eager-loaded
   * it; names are unique per project, so the id is the reference.
   */
  network?: string;
  macAddress: string;
  /** All addresses on the NIC, one per family on a dual-stack network. */
  addresses?: InterfaceAddress[];
  /** Guest-reported addresses (qga); empty until a guest agent reports them. */
  observedAddresses?: ObservedInterfaceAddress[];
  mtu?: number;
  deviceName: string;
  orderIndex: number;
  attachmentState?:
    | "attaching"
    | "attached"
    | "detaching"
    | "attach_failed"
    | "detach_failed";
  attachmentError?: string;
  /**
   * The security groups filtering this NIC. `undefined` means the server did
   * not report membership (an older control plane), never that the NIC is in
   * no group — an empty array is what says that.
   */
  securityGroupIds?: string[];
}

export interface CreateVMNetworkInterfaceRequest {
  networkId?: string;
  networkName?: string;
  securityGroupIds?: string[];
  mtu?: number;
}

export interface VM {
  id: string;
  name: string;
  description: string;
  image: string;
  imageId?: string;
  projectId?: string;
  status: VMStatus;
  hypervisorType?: "qemu" | "firecracker";
  hypervisorId?: string;
  cpu: number;
  maxCpu: number;
  memory: number;
  memoryFormatted: string;
  /** Ceiling for online memory growth (backend issue #568); equals `memory` when the VM has no headroom. */
  maxMemory: number;
  disk: number;
  diskFormatted: string;
  networkInterfaces: VMNetworkInterface[];
  /**
   * Machine profile (backend issue #565). `secureBoot` selects the signed EDK2
   * firmware build with a pre-enrolled Microsoft key database; `tpmEnabled`
   * attaches a per-VM swtpm-backed TPM 2.0. Both are false on VMs created
   * before #565 and on every Firecracker VM. Optional here only because older
   * control planes omit them.
   */
  secureBoot?: boolean;
  tpmEnabled?: boolean;
  /**
   * Whether the VM's attached security groups are actually enforced. `false`
   * means a realizing agent is too old for security groups, or its site has no
   * usable network controller to author the ACLs — either way the groups the
   * UI shows filter nothing. `undefined` means the VM is unplaced (or the
   * control plane predates the field) — unknown, not "no".
   */
  securityGroupsEnforced?: boolean;
  /**
   * The VM's SPIFFE instance identity — `spiffe://<trust-domain>/vm/<vm-id>`,
   * the lookup key its workload registration is filed under. A name, never an
   * authorization: what it may do comes from role bindings against that
   * principal. `undefined` means the control plane predates the field, or an
   * administrator revoked the registration — not that the VM has no identity.
   */
  spiffeId?: string;
  /**
   * Graphics console (backend issue #566): whether the guest has a display
   * device whose framebuffer the Display tab can attach to. Fixed at creation
   * — the display lives in the hypervisor process's arguments, so an existing
   * VM cannot gain or lose one. Optional here only because older control
   * planes omit it.
   */
  graphicsConsole?: boolean;
  /**
   * Whether the instance metadata service answers this VM (backend STR-185) —
   * the per-instance kill switch, editable on a running VM. This is the VM's
   * own switch, not the effective answer: a VM on a network whose metadata is
   * turned off still reads `true` here unless someone turned it off for this
   * VM. Optional only because older control planes omit it; treat `undefined`
   * as on.
   */
  metadataEnabled?: boolean;
  /**
   * Observed guest-agent (qga) view (issue #563). `qgaAvailable` is undefined
   * until the agent's slow poll first sees a responsive guest agent;
   * `observedHostname` is the guest OS's own hostname when it reported one.
   */
  qgaAvailable?: boolean;
  observedHostname?: string;
  /**
   * Observed guest memory usage from the virtio-balloon device (issue #567).
   * Undefined until a guest with the virtio_balloon driver reports; used is
   * derived server-side as total - available.
   */
  guestMemoryTotalBytes?: number;
  guestMemoryAvailableBytes?: number;
  guestMemoryUsedBytes?: number;
  guestMemoryUsedFormatted?: string;
  guestMemoryStatsAt?: string;
  /** Convergence state (backend STR-142): what a client refetching after a 202 reads. */
  conditions: ResourceConditions;
  /**
   * Balloon target (issue #567 phase 2). `balloonTarget` is the memory an
   * operator asked the guest to be held to; `guestMemoryBalloonActualBytes` is
   * what the balloon has actually reached, and sits above the target while the
   * guest is still handing pages back.
   */
  balloonTarget?: number;
  balloonTargetFormatted?: string;
  guestMemoryBalloonActualBytes?: number;
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
  /** Canonical `iam_roles` id, or null for bare membership. */
  role: string | null;
  /** Human-readable role name, or null for bare membership. */
  roleDisplayName: string | null;
  joinedAt: string;
}

/**
 * A tier-2 ceiling that narrows a grant just written (STR-110). Never a
 * failure: the grant landed, and confers everything the ceiling does not take
 * back.
 */
export interface GrantCeiling {
  /** `organization/Acme/no-vm-stop` — attach node and guardrail name. */
  guardrail: string;
  /** `alice@acme (organization admin)`, when the author is resolvable. */
  setBy?: string;
  explanation: string;
  /** The role's actions this ceiling takes back; the rest still apply. */
  ceilingedActions: string[];
  counterexample?: string;
}

/** What every role-grant write returns. Usually `ceilings: []`. */
export interface GrantWriteResponse {
  ceilings: GrantCeiling[];
  /**
   * Why the ceiling analysis could not run, when it could not. `ceilings` is
   * empty in that case too, so this is the only thing separating "nothing
   * narrows this grant" from "nobody could say". The grant landed either way.
   */
  analysisUnavailable?: string;
}

/** Canonical `iam_roles` UUID used by project grant endpoints. */
export type ProjectRole = string;

export interface ProjectMember {
  userId: string;
  username: string;
  displayName: string;
  email: string;
  /** The role's `iam_roles` id as a string (issue #608). */
  role: string;
  /** Human-readable role name for display; "(deleted role)" if dangling. */
  roleDisplayName: string;
  joinedAt: string | null;
  /** Not a member of the project's organization — a cross-org grant. */
  external: boolean;
}

export interface ProjectGroupGrant {
  groupId: string;
  name: string;
  /** The role's `iam_roles` id as a string (issue #608). */
  role: string;
  /** Human-readable role name for display; "(deleted role)" if dangling. */
  roleDisplayName: string;
  grantedAt: string | null;
  /** Belongs to another organization — a cross-org grant. */
  external: boolean;
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

// IAM — roles, authored policies, and the action catalog. Roles and policies
// are owned by an organization or project; the four seeded defaults are
// `platform`-owned rows, immutable through the API.
export type IAMRoleOwnerType = "platform" | "organization" | "project";

// The tree nodes a role binding or guardrail can attach to (the org hierarchy
// plus any individual resource).
export type IAMNodeType =
  | "organization"
  | "organizational_unit"
  | "project"
  | "virtual_machine"
  | "sandbox"
  | "image"
  | "network"
  | "floating_ip"
  | "volume"
  | "volume_snapshot"
  | "sandbox_snapshot"
  | "site"
  | "agent"
  | "security_group";

export interface IAMNode {
  type: IAMNodeType;
  id: string;
}

export interface IAMRole {
  id: string;
  name: string;
  description?: string;
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  cedarText: string;
  actions: string[];
  managed: boolean;
  createdBy?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface IAMRoleListResponse {
  roles: IAMRole[];
}

// A role as the grant flow needs it: enough to choose one and know what it
// confers, without the (more sensitive) policy text.
export interface IAMBindableRole {
  id: string;
  name: string;
  description?: string;
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  actions: string[];
  managed: boolean;
}

export interface IAMBindableRolesResponse {
  node: IAMNode;
  ancestors: IAMNode[];
  roles: IAMBindableRole[];
}

// Send exactly one of `actions` (server generates the canonical permit) or
// `cedarText` (advanced). Cedar text needs the role `id` it is conditioned on.
export interface IAMRoleCreateRequest {
  name: string;
  description?: string;
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  actions?: string[];
  cedarText?: string;
  id?: string;
}

export interface IAMRoleUpdateRequest {
  name?: string;
  description?: string;
  actions?: string[];
  cedarText?: string;
}

export interface IAMRoleValidateRequest {
  actions?: string[];
  cedarText?: string;
  id?: string;
}

export interface IAMRoleValidateResponse {
  id: string;
  cedarText: string;
  actions: string[];
}

export type IAMPolicyEffect = "permit" | "forbid";

export interface IAMPolicy {
  id: string;
  name: string;
  description?: string;
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  cedarText: string;
  effect: IAMPolicyEffect;
  enabled: boolean;
  createdBy?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface IAMPolicyListResponse {
  policies: IAMPolicy[];
}

export interface IAMPolicyCreateRequest {
  name: string;
  description?: string;
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  cedarText: string;
  enabled?: boolean;
  id?: string;
}

export interface IAMPolicyUpdateRequest {
  name?: string;
  description?: string;
  cedarText?: string;
  enabled?: boolean;
}

export interface IAMPolicyValidateRequest {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  cedarText: string;
  id?: string;
}

export interface IAMPolicyValidateResponse {
  id: string;
  cedarText: string;
  effect: IAMPolicyEffect;
}

// The action vocabulary a role can be built from, grouped by service.
export interface IAMActionCatalogEntry {
  action: string;
  service: string;
  resourceTypes: IAMNodeType[];
  roles: string[];
  membershipDerived: boolean;
}

export interface IAMActionCatalogService {
  service: string;
  actions: IAMActionCatalogEntry[];
}

export interface IAMActionCatalogResponse {
  services: IAMActionCatalogService[];
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
  // Whether this node can back a VM's TPM 2.0 device, i.e. it has a usable
  // `swtpm` binary. A VM requesting a TPM only places on a capable node.
  // Absent for agents that haven't re-registered with a build that reports it.
  tpmCapable?: boolean;
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
  // The version this agent has been assigned, while it is converging; absent
  // once converged (or never assigned). Set by the fleet rollout and by an
  // operator's "update now" alike (STR-145), so it is not conditional on
  // `autoUpdate`.
  updateDesiredVersion?: string;
  // Who assigned it. Absent exactly when there is no assignment.
  updateAssignmentSource?: "rollout" | "manual";
  updateAttemptedAt?: string;
  // The agent's self-reported reason for not converging yet.
  updateBlockedReason?: string;
  // Terminal failure that halted the rollout at this agent, if any.
  updateFailureReason?: string;
  // Why the agent last refused to converge a sync's workload teardowns
  // (STR-98): removing that many of the host's workloads at once looked more
  // like a control-plane failure than an intention. Absent in the steady state.
  teardownRefusalReason?: string;
  teardownRefusedAt?: string;
  // What the agent last reported about its durable workload manifest — its
  // only memory of what it is running (STR-138). Present means either that the
  // manifest is unreadable, or that some entries in it cannot be routed by the
  // agent build on the host. Absent in the steady state.
  manifestStatusReason?: string;
  manifestStatusAt?: string;
  // False while the agent cannot enumerate its own workloads: it advertises no
  // capacity and converges nothing until the manifest is repaired.
  manifestInventoryComplete?: boolean;
  // Workloads the agent is running that no desired-state sync accounts for and
  // whose teardown the control plane refused to authorize, because a record
  // still exists for them. Returned by the single-agent endpoint only.
  heldWorkloads?: HeldWorkload[];
}

// One workload an agent holds that the control plane will not authorize
// tearing down. Most often the node re-enrolled under a new agent record and
// its workloads are still placed on the old one (`placedOnAgentId`).
export interface HeldWorkload {
  kind: "virtual_machine" | "sandbox";
  id: string;
  status?: string;
  reason?: string;
  placedOnAgentId?: string;
  firstSeenAt?: string;
}

// Result of POST /api/agents/:id/actions/adopt-workloads.
export interface AdoptWorkloadsResult {
  adoptedVMs: number;
  adoptedSandboxes: number;
  // Includes detached volumes on the source record — their data is on the
  // adopting host too.
  adoptedVolumes: number;
  // Workloads on the source record this agent doesn't report holding. Not
  // necessarily stranded: one running on a genuinely different host counts here.
  skippedUnclaimed: number;
}

// Result of POST /api/agents/:id/actions/update — the update the agent has
// been assigned and is now converging on (202, not a completed install).
export interface AgentUpdateResult {
  // Always "assigned".
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

export type SiteStatus = "active" | "draining" | "maintenance" | "decommissioned";

export interface Site {
  id: string;
  name: string;
  description?: string;
  status: SiteStatus;
  latitude?: number;
  longitude?: number;
  locationLabel?: string;
  regionCode?: string;
  labels: Record<string, string>;
  networkControllerAgentId?: string;
  /** Heartbeat-derived status of the designated controller; absent when none is designated. */
  networkControllerStatus?: AgentStatus;
  /**
   * Why the designated controller cannot author this site's topology right now;
   * absent while it can. When present, new networked workloads, site-pinned
   * networks, floating-IP attaches and security-group attaches here are refused.
   */
  networkControllerIssue?: string;
  organizationId?: string;
  organizationalUnitId?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateSiteRequest {
  name: string;
  description?: string;
  organizationId?: string;
  organizationalUnitId?: string;
  status?: SiteStatus;
  latitude?: number;
  longitude?: number;
  locationLabel?: string;
  regionCode?: string;
  labels?: Record<string, string>;
}

/**
 * PUT full-replace for descriptive fields; an omitted `status` leaves the
 * current lifecycle unchanged.
 */
export interface UpdateSiteRequest {
  description?: string;
  networkControllerAgentId?: string;
  status?: SiteStatus;
  latitude?: number;
  longitude?: number;
  locationLabel?: string;
  regionCode?: string;
  labels?: Record<string, string>;
}

/**
 * What a credential may do, in the IAM action and node vocabulary (STR-115).
 * A restriction only subtracts: the effective permission is the owner's role
 * bindings intersected with it, enforced by the Cedar evaluator like any other
 * authorization decision. `actions: ["*"]` with no node is unrestricted.
 */
export interface CredentialRestriction {
  /** Request only: sugar for a role's action list, expanded at write time. */
  role?: string;
  /**
   * Exact actions (`vm:read`), service wildcards (`vm:*`), `read` (every
   * action whose name says it reads, resolved server-side on every check), or
   * `*`.
   */
  actions?: string[];
  /** The subtree the credential may act in; both fields or neither. */
  nodeType?: string;
  nodeId?: string;
}

export interface APIKey {
  id: string;
  name: string;
  keyPrefix: string;
  /** @deprecated Superseded by `restriction`; kept for older clients. */
  scopes: string[];
  /** The effective restriction, stored or derived from `scopes`. */
  restriction: CredentialRestriction;
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
  /** @deprecated Superseded by `restriction`. */
  scopes: string[];
  restriction: CredentialRestriction;
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

/**
 * Whether the sign-in screen should offer account creation.
 * `selfRegistrationEnabled` is the effective answer — an install with no users
 * reports it as true even when the operator disabled self-registration, since
 * the first account always has to be creatable.
 */
export interface RegistrationPolicy {
  selfRegistrationEnabled: boolean;
  bootstrapRequired: boolean;
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

// Webhook subscriptions (org-scoped; managed by org admins, visible to members)
export interface WebhookSubscription {
  id: string;
  organizationId: string;
  /** Present when the subscription only receives events for one project. */
  projectId?: string | null;
  name: string;
  url: string;
  /** Empty array = subscribed to ALL event types. */
  eventTypes: string[];
  isActive: boolean;
  /** Set when the platform auto-disabled it after continuous delivery failures. */
  disabledReason?: string | null;
  /** ISO date; start of the current failure streak. */
  failingSince?: string | null;
  createdAt?: string;
  updatedAt?: string;
}

export interface WebhookDelivery {
  id: string;
  subscriptionId: string;
  eventId: string;
  eventType: string;
  status: "pending" | "succeeded" | "dead";
  attempts: number;
  /** Only while pending. */
  nextAttemptAt?: string | null;
  lastAttemptAt?: string | null;
  /** Last HTTP status from the endpoint. */
  responseStatus?: number | null;
  lastError?: string | null;
  deliveredAt?: string | null;
  createdAt?: string;
  /** Frozen JSON body that was POSTed. */
  payload: string;
}

export interface CreateWebhookRequest {
  name: string;
  url: string;
  projectId?: string;
  eventTypes?: string[];
}

export interface UpdateWebhookRequest {
  name?: string;
  url?: string;
  eventTypes?: string[];
  isActive?: boolean;
}

/**
 * Returned on create and rotate-secret. `signingSecret` is only ever shown
 * here — it is stored hashed and never retrievable again.
 */
export interface WebhookWithSecret {
  subscription: WebhookSubscription;
  signingSecret: string;
}

// Request types
export interface CreateVMRequest {
  name: string;
  description?: string;
  imageId: string;
  /** The project the resource is created in. Required; there is no default project. */
  projectId: string;
  environment?: string;
  cpu?: number;
  memory?: number;
  disk?: number;
  /** Legacy scalar selector; required when `networkInterfaces` is absent. */
  networkId?: string;
  /** Compatible scalar selector; mutually exclusive with `networkId`. */
  networkName?: string;
  /** Create-time multi-NIC form. Do not combine with scalar network fields. */
  networkInterfaces?: CreateVMNetworkInterfaceRequest[];
  /** SSH public key authorized for the guest's default user (cloud-init). */
  sshPublicKey?: string;
  /**
   * Cloud-init user data, passed to the guest verbatim at first boot. Any
   * format cloud-init dispatches on: `#cloud-config`, `#!` shell script,
   * `#include`, `## template: jinja`, or a full MIME multipart document
   * (which replaces Strato's built-in provisioning entirely).
   */
  userData?: string;
  /**
   * UEFI Secure Boot: boots the signed EDK2 build against a VARS template with
   * Microsoft's keys pre-enrolled. Defaults to false. Rejected with 400 for
   * Firecracker, which has no UEFI firmware.
   */
  secureBoot?: boolean;
  /**
   * TPM 2.0, emulated by a per-VM swtpm process on the agent. Defaults to
   * false. Rejected with 400 for Firecracker, and only schedulable onto an
   * agent whose `tpmCapable` is true.
   */
  tpm?: boolean;
  /**
   * Graphics console: gives the guest a display device and a VNC server, so a
   * graphical OS installer can be driven from the Display tab. Defaults to
   * false (headless). Rejected with 400 for Firecracker, which emulates no
   * display device, and only schedulable onto an agent new enough to realize
   * one. Cannot be changed after creation.
   */
  graphicsConsole?: boolean;
  /**
   * Security groups for the VM's NIC (max 5, same project as the VM).
   * Omitted → the project's default group.
   */
  securityGroupIds?: string[];
  /**
   * Whether the instance metadata service answers this VM. Defaults to true.
   * Creating a VM with it off denies the guest `169.254.169.254` outright, and
   * only agents new enough to honour that are schedulable — but note the
   * metadata service is also how a guest reads its cloud-init configuration,
   * so a VM created this way may not finish provisioning.
   */
  metadataEnabled?: boolean;
}

// Async VM operations: lifecycle mutations return 202 Accepted with an
// Operation record, which the client polls until it reaches a terminal state.
/// Mirrors `VMOperationKind` in shared/Sources/StratoShared/OperationModels.swift.
/// Adding a case here is what forces the matching entry in every
/// `Record<OperationKind, …>` — the `verbs` map in
/// components/vms/mutation-watcher.tsx, `kindToAction` in vm-actions.tsx and
/// sandbox-actions.tsx, and the labels in lib/operation-labels.ts — so the
/// compiler catches each omission. Forgetting to add it *here* is the silent
/// failure: the watcher then throws on an unknown kind and the user never sees
/// a terminal toast.
export type OperationKind =
  | "create"
  | "boot"
  | "shutdown"
  | "reboot"
  | "pause"
  | "resume"
  | "delete"
  // Online vCPU/memory resize of a running VM (backend issue #568).
  | "resize"
  // Sandbox checkpoint/restore (backend issue #426).
  | "snapshot"
  | "snapshot_delete"
  | "restore"
  // Snapshot mobility: off-node export (backend issue #428).
  | "snapshot_export"
  // Volume attachment (backend STR-148). Their own kinds rather than folded
  // into create/delete because "who plugged this volume into that VM" is a
  // different question from "who made the volume".
  | "attach"
  | "detach"
  // Per-volume I/O ceilings (backend STR-19). Its own kind for the same reason:
  // an audit trail that said "resize" when someone halved a throughput cap
  // would be a lie.
  | "throttle";

export type OperationStatus = "pending" | "succeeded" | "failed";

/**
 * How far a resource is from the state the API was last asked to put it in
 * (backend STR-142). Derived server-side on every read; nothing stores it.
 *
 * This is what replaced operation polling for lifecycle mutations (backend
 * STR-147). After a 202, refetch the resource: done is `converged` with
 * `observedGeneration >= targetGeneration`; failed is a `degraded` whose
 * `sinceGeneration` equals the generation the mutation targeted.
 *
 * The two are mutually exclusive (backend STR-191): a failure recorded at the
 * target generation makes `converged` false, so exactly one of them ever
 * answers. They used to be able to hold at once — an agent applies a generation
 * with one work item and can then fail a second at the same number — which left
 * a client following the rule above with no verdict.
 */
export interface ResourceConditions {
  /**
   * The owning agent confirmed the target generation, the desired state is
   * satisfied, and no attempt at that same generation failed.
   */
  converged: boolean;
  /** The generation the resource is trying to reach — what the last mutation bumped it to. */
  targetGeneration: number;
  /** The newest generation the owning agent confirmed; 0 means never confirmed. */
  observedGeneration: number;
  /** The agent's current step, present only while it is actively converging. */
  phase?: string | null;
  /**
   * The last convergence attempt that failed. Can stand against a *newer*
   * `targetGeneration` while a retry is in flight, which is why callers
   * compare `sinceGeneration` against the generation they are waiting on
   * rather than treating any `degraded` as their own failure. A `degraded`
   * that names the generation you are waiting on is that mutation's verdict,
   * and `converged` is false alongside it.
   */
  degraded?: {
    reason: string;
    sinceGeneration: number;
    /** ISO-8601 time when this error/generation pair was first observed. */
    lastErrorAt?: string | null;
  } | null;
}

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

// The resource an operation targets. Operations are shared machinery across VMs
// and sandboxes (backend issue #412), discriminated by `resourceKind`.
// Snapshot artifacts became their own resource kinds in ADR 0001 stage 8: a
// checkpoint is a durable noun with its own lifecycle, not a verb on its
// parent.
export type OperationResourceKind =
  | "virtual_machine"
  | "sandbox"
  | "volume"
  | "volume_snapshot"
  | "vm_checkpoint"
  | "sandbox_snapshot";

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
  /**
   * Security groups on the sandbox's NIC (flat: a sandbox has at most one).
   * Absent when the sandbox has no NIC. Kept alongside the per-NIC copy on
   * `networkInterfaces` for clients that predate it.
   */
  securityGroupIds?: string[];
  /** The sandbox's NICs — at most one today, a list for parity with VMs. */
  networkInterfaces?: SandboxNetworkInterface[];
  /**
   * Whether the attached groups actually filter traffic. `undefined` means the
   * sandbox has no NIC, so there is nothing to judge — not a claim that they
   * are unenforced. `false` when the sandbox's node cannot realize a sandbox
   * NIC (backend STR-103) or its site authors no ACLs: either way no port
   * exists to join the groups.
   *
   * `true` is a statement about the *node*, not about this sandbox's microVM.
   * A sandbox created before its node could realize NICs keeps reading `true`
   * after the node is upgraded while having no interface, because only
   * recreating a sandbox attaches one — neither restart nor boot rebuilds the
   * microVM. See `SecurityGroupService.sandboxEnforcement`.
   */
  securityGroupsEnforced?: boolean;
  /** Convergence state (backend STR-142) — the VM contract exactly. */
  conditions: ResourceConditions;
  createdAt: string;
  updatedAt: string;
}

/**
 * A sandbox's NIC. The sandbox analogue of {@link VMNetworkInterface}, without
 * `orderIndex` (sandboxes are single-NIC) or `observedAddresses` (no guest
 * agent).
 */
export interface SandboxNetworkInterface {
  id?: string;
  /** The logical network this NIC attaches to. */
  networkId: string;
  /**
   * Display name of that network. Present only when the response eager-loaded
   * it; names are unique per project, so the id is the reference.
   */
  network?: string;
  macAddress: string;
  /** All addresses on the NIC, one per family on a dual-stack network. */
  addresses?: InterfaceAddress[];
  mtu?: number;
  deviceName: string;
  /**
   * The security groups attached to this NIC. `undefined` means the server did
   * not report membership, never that the NIC is in no group — an empty array
   * is what says that.
   */
  securityGroupIds?: string[];
}

export interface CreateSandboxRequest {
  name: string;
  /** OCI image reference; required unless restoreFrom is present. */
  image?: string;
  /** Ready sandbox snapshot to restore as a new sandbox identity. */
  restoreFrom?: string;
  /** The project the resource is created in. Required; there is no default project. */
  projectId: string;
  environment?: string;
  cpus?: number;
  /** Guest memory in bytes. */
  memory?: number;
  entrypoint?: string[];
  cmd?: string[];
  env?: Record<string, string>;
  workingDir?: string;
  ttlSeconds?: number;
  /**
   * Firecracker CPU template (issue #428). Decided at create time; makes the
   * sandbox's snapshots restorable across same-arch hosts.
   */
  cpuTemplate?: string;
  /**
   * Logical network for the sandbox's NIC. Omitting it (and `networkName`)
   * creates the sandbox with no interface at all, which is legitimate — unlike
   * VM create, where a network is required.
   */
  networkId?: string;
  networkName?: string;
  /**
   * Security groups for the NIC. Omitted means the project's default group,
   * never "no groups". Sending these without a network is a 400.
   */
  securityGroupIds?: string[];
}

// Full-VM checkpoints (issue #564): guest memory + device state + disks at one
// instant, stored inside the VM's own qcow2 disks. Not to be confused with
// `Snapshot` above, which is a disk-only volume snapshot.
export type VMSnapshotStatus = "creating" | "ready" | "deleting" | "error";

export interface VMSnapshot {
  id: string;
  name: string;
  description: string;
  vmId: string;
  projectId: string;
  status: VMSnapshotStatus;
  // Bytes of guest memory and device state; the disks the checkpoint lives
  // inside are charged separately, under the VM.
  size?: number | null;
  // The agent holding the checkpoint. Restore is pinned to it: the machine
  // state never leaves that host.
  agentId?: string | null;
  qemuVersion?: string | null;
  architecture?: string | null;
  errorMessage?: string | null;
  // When retention will delete this checkpoint; null means it is kept until
  // someone deletes it.
  expiresAt?: string | null;
  conditions: ResourceConditions;
  createdById?: string | null;
  createdAt?: string | null;
}

export interface CreateVMSnapshotRequest {
  name?: string;
  description?: string;
  // Omitted uses the fleet default; 0 keeps the checkpoint until deleted.
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
  guestControlProtocolVersion?: number | null;
  forkLayoutVersion?: number | null;
  cpuTemplate?: string | null;
  // Whether an exported copy in project storage is wanted; `exportedAt` is
  // when one last completed (issue #428, STR-150).
  exportDesired?: boolean;
  // When the snapshot was last fully exported to object storage (issue
  // #428); null means agent-local only.
  exportedAt?: string | null;
  errorMessage?: string | null;
  expiresAt?: string | null;
  conditions: ResourceConditions;
  createdById?: string | null;
  createdAt?: string | null;
}

export interface CreateSandboxSnapshotRequest {
  name?: string;
  // When true, checkpoint and stop; defaults to false.
  stop?: boolean;
  // Omitted uses the fleet default; 0 keeps the snapshot until deleted.
  ttlSeconds?: number;
}

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
  /** @deprecated Ignored when `restriction` is present. */
  scopes?: string[];
  /** Omit for a key as wide as its owner. */
  restriction?: CredentialRestriction;
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

/**
 * Absolute per-volume I/O ceilings (backend STR-19). An *absent* member means
 * uncapped in that dimension — Swift encodes optionals with `encodeIfPresent`,
 * so the server omits the key rather than sending null.
 */
export interface VolumeIOLimits {
  iopsTotal?: number;
  bpsTotal?: number;
}

export interface Volume {
  id?: string;
  name: string;
  description: string;
  projectId?: string;
  /**
   * The size asked for by the last accepted create or resize — not necessarily
   * the size on disk. A resize is accepted and then converges.
   */
  size: number;
  sizeFormatted: string;
  /**
   * The size the owning agent reports the image actually has (backend
   * STR-199). Absent until an agent reports one. A disagreement with `size`
   * means a grow is still outstanding; `conditions` says whether it is in
   * flight or degraded.
   */
  observedSize?: number;
  observedSizeFormatted?: string;
  format: VolumeFormat;
  volumeType: VolumeType;
  status: VolumeStatus;
  errorMessage?: string;
  hypervisorId?: string;
  vmId?: string;
  deviceName?: string;
  bootOrder?: number;
  /** Whether the attachment presents the volume read-only. */
  readonly: boolean;
  /**
   * Whether the owning agent has caught up with the last mutation (backend
   * STR-148). Volume mutations are accepted, not performed: this is what says
   * one finished, not the `status` string, which lags a generation behind.
   */
  conditions: ResourceConditions;
  /** The I/O ceilings requested for this volume; absent when uncapped. */
  ioLimits?: VolumeIOLimits;
  /**
   * The ceilings the owning agent reports it has actually applied, and the only
   * signal that a cap is in force — unlike every other volume mutation,
   * `conditions` converging on a throttle says the agent accepted the sync, not
   * that the ceilings took effect. Compare against `ioLimits`: equal means in
   * force.
   *
   * Absent means they are *not* in effect, either because the agent has not
   * reported any or because it reported none. No agent applies ceilings yet, so
   * this is absent on every volume; a set `ioLimits` alongside an absent
   * `appliedIOLimits` is the expected reading today, not a fault.
   */
  appliedIOLimits?: VolumeIOLimits;
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
  // The agent holding the snapshot's overlay (STR-150).
  agentId?: string | null;
  expiresAt?: string | null;
  conditions: ResourceConditions;
  createdById?: string;
  createdAt?: string;
}

export interface CreateVolumeRequest {
  name: string;
  description?: string;
  /** The project the resource is created in. Required; there is no default project. */
  projectId: string;
  sizeGB: number;
  format?: VolumeFormat;
  volumeType?: VolumeType;
  sourceImageId?: string;
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
  // Omitted uses the fleet default; 0 keeps the snapshot until deleted.
  ttlSeconds?: number;
}

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

export interface QuotaLimits {
  maxVCPUs: number;
  maxMemoryGB: number;
  maxStorageGB: number;
  maxVMs: number;
  /** Volume count limit. Omitted or null means no count limit. */
  maxVolumes?: number | null;
  maxNetworks: number;
}

export interface QuotaReservedUsage {
  reservedVCPUs: number;
  reservedMemoryGB: number;
  reservedStorageGB: number;
  vmCount: number;
  volumeCount: number;
  networkCount: number;
}

export interface QuotaUtilization {
  cpuPercent: number;
  memoryPercent: number;
  storagePercent: number;
  vmPercent: number;
  /** Null when no volume count limit is set. */
  volumePercent: number | null;
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
  /** Omitted means no volume count limit, not one inferred from `maxVMs`. */
  maxVolumes?: number;
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
  /** Omit to leave the volume limit alone; send `0` to remove it. */
  maxVolumes?: number;
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

export interface FolderNode {
  id: string;
  name: string;
  description: string;
  path: string;
  depth: number;
  childOUs: FolderNode[];
  projects: ProjectNode[];
  quotas: ResourceQuota[];
}

export interface OrganizationNode {
  id: string;
  name: string;
  description: string;
  organizationalUnits: FolderNode[];
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
  /** Owning project. Network names are unique per project, not globally. */
  projectId: string;
  /** VM and sandbox interfaces attached; a network in use cannot be deleted. */
  attachedInterfaceCount: number;
  /** Whether agents program OVN's DHCP responder to configure guests. */
  dhcpEnabled: boolean;
  /** DNS resolvers advertised to guests over DHCP. */
  dnsServers: string[];
  /** DNS search domain advertised over DHCP. */
  domainName?: string;
  /** DHCP lease time in seconds. */
  leaseTime?: number;
  /**
   * Whether the network publishes the link-local instance metadata service
   * (169.254.169.254 / fd00:ec2::254) to its guests. Defaults on.
   */
  metadataEnabled: boolean;
  resolverEnabled: boolean;
  resolverAddresses?: string[];
  /**
   * Why this network's guests will not resolve the DNS zones attached to it,
   * with the remedy — absent when they will, and absent for a network with no
   * attached zone, which has nothing to fail to deliver.
   */
  zoneResolutionWarning?: string;
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
  /** The project the resource is created in. Required; there is no default project. */
  projectId: string;
  dhcpEnabled?: boolean;
  dnsServers?: string[];
  domainName?: string;
  leaseTime?: number;
  /** Omitted → the server's default (on). */
  metadataEnabled?: boolean;
  resolverEnabled?: boolean;
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
  metadataEnabled?: boolean;
  resolverEnabled?: boolean;
}

// Security groups (stateful NIC-level firewalls, realized as OVN ACLs)

export type SecurityGroupRuleDirection = "ingress" | "egress";
export type Ethertype = "ipv4" | "ipv6";

/** Server-enforced cap (SecurityGroup.maxGroupsPerNIC in the control plane). */
export const MAX_SECURITY_GROUPS_PER_NIC = 5;

export interface SecurityGroupRule {
  id: string;
  direction: SecurityGroupRuleDirection;
  ethertype: Ethertype;
  /** "tcp", "udp", or "icmp"; absent matches any protocol. */
  protocolName?: string;
  /**
   * tcp/udp: destination port range (min == max for one port).
   * icmp: min is the ICMP type, max the code. Absent means all.
   */
  portRangeMin?: number;
  portRangeMax?: number;
  /** At most one of remoteCIDR/remoteGroupId; both absent means "any peer". */
  remoteCIDR?: string;
  remoteGroupId?: string;
  /** Whether the realized OVN ACL logs the packets this rule matches. */
  log?: boolean;
  description?: string;
  createdAt?: string;
}

export interface SecurityGroup {
  id: string;
  name: string;
  description?: string;
  projectId: string;
  /** The project's auto-created fallback group: undeletable and un-renamable. */
  isDefault: boolean;
  rules: SecurityGroupRule[];
  /** How many NICs currently attach this group; a group in use cannot be deleted. */
  attachmentCount: number;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateSecurityGroupRequest {
  name: string;
  description?: string;
  /** The project the resource is created in. Required; there is no default project. */
  projectId: string;
}

export interface UpdateSecurityGroupRequest {
  name?: string;
  description?: string;
}

export interface CreateSecurityGroupRuleRequest {
  direction: SecurityGroupRuleDirection;
  ethertype: Ethertype;
  protocolName?: string;
  portRangeMin?: number;
  portRangeMax?: number;
  remoteCIDR?: string;
  remoteGroupId?: string;
  /** Log the packets this rule matches. Defaults to false. */
  log?: boolean;
  description?: string;
}

/**
 * Names exactly one workload — `vmId` or `sandboxId` — optionally narrowed to
 * one of its NICs. Naming neither or both is rejected with a 400.
 */
export interface AttachSecurityGroupRequest {
  vmId?: string;
  /**
   * Refused with a 409 when the sandbox is placed on a node that cannot
   * realize a sandbox NIC: there would be no OVN port to make a member. An
   * unplaced sandbox is always accepted. See `Sandbox.securityGroupsEnforced`.
   */
  sandboxId?: string;
  /** The NIC to attach to; defaults to the workload's first interface. */
  interfaceId?: string;
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

// OAuth device grant (strato CLI) — issue #558

/** A pending device authorization shown on the /activate approval page. */
export interface PendingDeviceAuthorization {
  userCode: string;
  clientName: string;
  /** @deprecated Superseded by `restriction`. */
  scopes: string[];
  /** What the client asked to be able to do. */
  restriction: CredentialRestriction;
  requestIP?: string;
  createdAt?: string;
  expiresAt: string;
}

/** A CLI login session (access + refresh token pair) listed in Settings. */
export interface CLISession {
  id: string;
  clientName: string;
  /** @deprecated Superseded by `restriction`. */
  scopes: string[];
  restriction: CredentialRestriction;
  accessTokenPrefix: string;
  createdAt?: string;
  lastUsedAt?: string;
  lastUsedIP?: string;
  refreshTokenExpiresAt: string;
}
