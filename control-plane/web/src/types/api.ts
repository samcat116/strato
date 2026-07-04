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

export type HostArchitecture = "x86_64" | "arm64";

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
  architecture?: HostArchitecture;
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

export interface SessionResponse {
  user: User;
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
}

export interface UpdateVMRequest {
  name?: string;
  description?: string;
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

export interface Image {
  id?: string;
  name: string;
  description: string;
  projectId?: string;
  filename: string;
  size: number;
  sizeFormatted: string;
  format: ImageFormat;
  checksum?: string;
  status: ImageStatus;
  sourceURL?: string;
  downloadProgress?: number;
  errorMessage?: string;
  defaultCpu?: number;
  defaultMemory?: number;
  defaultDisk?: number;
  defaultCmdline?: string;
  uploadedById?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateImageRequest {
  name: string;
  description?: string;
  sourceURL?: string;
  defaultCpu?: number;
  defaultMemory?: number;
  defaultDisk?: number;
  defaultCmdline?: string;
}

export interface UpdateImageRequest {
  name?: string;
  description?: string;
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
