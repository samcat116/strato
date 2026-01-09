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

export type VMStatus = "running" | "shutdown" | "paused" | "created";

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
  templateName: string;
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
