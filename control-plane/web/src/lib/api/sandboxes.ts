// Sandbox API endpoints (backend issue #413).

import { api } from "./client";
import type {
  Sandbox,
  CreateSandboxRequest,
  UpdateSandboxRequest,
  Operation,
} from "@/types/api";

// Like VMs, sandbox lifecycle mutations are asynchronous: the server responds
// 202 Accepted with an Operation record and the work completes in the
// background. Poll operationsApi.get (see OperationWatcher) until the operation
// is terminal. Sandboxes have no pause/resume, console, or logs endpoints.
export const sandboxesApi = {
  list(): Promise<Sandbox[]> {
    return api.get<Sandbox[]>("/api/sandboxes");
  },

  get(id: string): Promise<Sandbox> {
    return api.get<Sandbox>(`/api/sandboxes/${id}`);
  },

  create(data: CreateSandboxRequest): Promise<Operation> {
    return api.post<Operation>("/api/sandboxes", data);
  },

  update(id: string, data: UpdateSandboxRequest): Promise<Sandbox> {
    return api.put<Sandbox>(`/api/sandboxes/${id}`, data);
  },

  delete(id: string): Promise<Operation> {
    return api.delete<Operation>(`/api/sandboxes/${id}`);
  },

  start(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/sandboxes/${id}/start`);
  },

  stop(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/sandboxes/${id}/stop`);
  },

  restart(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/sandboxes/${id}/restart`);
  },

  listOperations(id: string, limit?: number): Promise<Operation[]> {
    return api.get<Operation[]>(
      `/api/sandboxes/${id}/operations${limit ? `?limit=${limit}` : ""}`
    );
  },

  getStatus(id: string): Promise<Sandbox> {
    return api.get<Sandbox>(`/api/sandboxes/${id}/status`);
  },
};
