// Sandbox API endpoints (backend issue #413).

import { api } from "./client";
import type {
  Sandbox,
  CreateSandboxRequest,
  UpdateSandboxRequest,
  SandboxExecRequest,
  SandboxExecSession,
  SandboxLogEntry,
  SandboxLogsQueryParams,
  Operation,
  Page,
  SandboxSnapshot,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

// Like VMs, sandbox lifecycle mutations are asynchronous: the server responds
// 202 Accepted with an Operation record and the work completes in the
// background. Poll operationsApi.get (see OperationWatcher) until the operation
// is terminal. Sandboxes have no pause/resume or console endpoints.
export const sandboxesApi = {
  list(organizationId?: string): Promise<Sandbox[]> {
    return api
      .get<Page<Sandbox>>("/api/sandboxes", {
        limit: LIST_PAGE_LIMIT,
        ...(organizationId ? { organization_id: organizationId } : {}),
      })
      .then((page) => page.items);
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

  listSnapshots(id: string): Promise<SandboxSnapshot[]> {
    return api
      .get<Page<SandboxSnapshot>>(`/api/sandboxes/${id}/snapshots`, {
        limit: LIST_PAGE_LIMIT,
      })
      .then((page) => page.items);
  },

  // Copies a snapshot's artifacts into control-plane object storage (issue
  // #428), making it durable against agent loss and eligible for cross-agent
  // restore/fork. 202 + operation, like the other snapshot mutations.
  exportSnapshot(id: string, snapshotId: string): Promise<Operation> {
    return api.post<Operation>(
      `/api/sandboxes/${id}/snapshots/${snapshotId}/export`
    );
  },

  // Creates a pending exec session (201). Attach to the returned
  // `websocketPath` before `expiresAt` to actually start the process.
  exec(id: string, body: SandboxExecRequest): Promise<SandboxExecSession> {
    return api.post<SandboxExecSession>(`/api/sandboxes/${id}/exec`, body);
  },

  getLogs(
    id: string,
    params?: SandboxLogsQueryParams
  ): Promise<SandboxLogEntry[]> {
    const searchParams = new URLSearchParams();
    if (params?.limit) searchParams.set("limit", String(params.limit));
    if (params?.direction) searchParams.set("direction", params.direction);
    if (params?.start) searchParams.set("start", String(params.start));
    if (params?.end) searchParams.set("end", String(params.end));

    const query = searchParams.toString();
    return api.get<SandboxLogEntry[]>(
      `/api/sandboxes/${id}/logs${query ? `?${query}` : ""}`
    );
  },
};
