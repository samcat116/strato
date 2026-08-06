// Sandbox API endpoints (backend issue #413).

import { api } from "./client";
import { buildLogQueryString } from "./logs";
import type {
  Sandbox,
  CreateSandboxRequest,
  UpdateSandboxRequest,
  SandboxExecRequest,
  SandboxExecSession,
  SandboxLogEntry,
  SandboxLogsQueryParams,
  AcceptedMutation,
  Operation,
  Page,
  SandboxSnapshot,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

// Like VMs, sandbox lifecycle mutations are asynchronous: the server responds
// 202 Accepted with the sandbox, the generation it has to converge on, and the
// mutation's id (backend STR-147). MutationWatcher refetches the sandbox until
// its `conditions` say it converged — or, for a delete, polls
// operationsApi.get(mutationId). Sandboxes have no pause/resume or console
// endpoints; restart rides the desired-state sync, so unlike a VM's it is a
// generation-backed mutation too.
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

  create(data: CreateSandboxRequest): Promise<AcceptedMutation<Sandbox>> {
    return api.post<AcceptedMutation<Sandbox>>("/api/sandboxes", data);
  },

  update(id: string, data: UpdateSandboxRequest): Promise<Sandbox> {
    return api.put<Sandbox>(`/api/sandboxes/${id}`, data);
  },

  delete(id: string): Promise<AcceptedMutation<Sandbox>> {
    return api.delete<AcceptedMutation<Sandbox>>(`/api/sandboxes/${id}`);
  },

  start(id: string): Promise<AcceptedMutation<Sandbox>> {
    return api.post<AcceptedMutation<Sandbox>>(`/api/sandboxes/${id}/start`);
  },

  stop(id: string): Promise<AcceptedMutation<Sandbox>> {
    return api.post<AcceptedMutation<Sandbox>>(`/api/sandboxes/${id}/stop`);
  },

  restart(id: string): Promise<AcceptedMutation<Sandbox>> {
    return api.post<AcceptedMutation<Sandbox>>(`/api/sandboxes/${id}/restart`);
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
    return api.get<SandboxLogEntry[]>(
      `/api/sandboxes/${id}/logs${buildLogQueryString(params)}`
    );
  },
};
