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

export type VMStatus = "Running" | "Shutdown" | "Paused" | "Created";

export interface VM {
  id: string;
  name: string;
  description: string;
  image: string;
  status: VMStatus;
  hypervisorId?: string;
  cpu: number;
  maxCpu: number;
  memory: number;
  disk: number;
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

export interface Agent {
  id: string;
  name: string;
  hostname: string;
  version: string;
  capabilities: string[];
  status: AgentStatus;
  resources: AgentResources;
  lastHeartbeat?: string;
  createdAt: string;
  isOnline: boolean;
}

export interface AgentRegistrationToken {
  token: string;
  agentName: string;
  expiresAt: string;
  registrationURL: string;
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
