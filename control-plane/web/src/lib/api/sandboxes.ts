// Sandbox API endpoints (backend issue #413).

import { api } from "./client";
import { listAllPages } from "./pagination";
import { buildLogQueryString } from "./logs";
import type {
  Sandbox,
  CreateSandboxRequest,
  SandboxExecRequest,
  SandboxExecSession,
  SandboxLogEntry,
  SandboxLogsQueryParams,
  AcceptedMutation,
  SandboxSnapshot,
  CreateSandboxSnapshotRequest,
} from "@/types/api";

// Like VMs, sandbox lifecycle mutations are asynchronous: the server responds
// 202 Accepted with the sandbox, the generation it has to converge on, and the
// mutation's id (backend STR-147). MutationWatcher refetches the sandbox until
// its `conditions` say it converged — or, for a delete, polls
// operationsApi.get(mutationId). Sandboxes have no pause/resume or console
// endpoints; restart rides the desired-state sync, so unlike a VM's it is a
// generation-backed mutation too.
export const sandboxesApi = {
  list(organizationId?: string, signal?: AbortSignal): Promise<Sandbox[]> {
    return listAllPages<Sandbox>(
      "/api/sandboxes",
      organizationId ? { organization_id: organizationId } : {}, signal
    );
  },

  get(id: string, signal?: AbortSignal): Promise<Sandbox> {
    return api.get<Sandbox>(`/api/sandboxes/${id}`, undefined, signal);
  },

  create(data: CreateSandboxRequest): Promise<AcceptedMutation<Sandbox>> {
    return api.post<AcceptedMutation<Sandbox>>("/api/sandboxes", data);
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

  listSnapshots(id: string, signal?: AbortSignal): Promise<SandboxSnapshot[]> {
    return listAllPages<SandboxSnapshot>(`/api/sandboxes/${id}/snapshots`, {}, signal);
  },

  createSnapshot(
    id: string,
    data?: CreateSandboxSnapshotRequest
  ): Promise<AcceptedMutation<SandboxSnapshot>> {
    return api.post<AcceptedMutation<SandboxSnapshot>>(
      `/api/sandboxes/${id}/snapshots`,
      data ?? {}
    );
  },

  deleteSnapshot(
    id: string,
    snapshotId: string
  ): Promise<AcceptedMutation<SandboxSnapshot>> {
    return api.delete<AcceptedMutation<SandboxSnapshot>>(
      `/api/sandboxes/${id}/snapshots/${snapshotId}`
    );
  },

  // Records that a snapshot's artifacts should also exist in control-plane
  // object storage (issue #428), making it durable against agent loss and
  // eligible for cross-agent restore/fork. A placement fact rather than a
  // command since STR-150: the owning agent converges by uploading, and the
  // snapshot stays unconverged until every artifact has landed.
  exportSnapshot(
    id: string,
    snapshotId: string
  ): Promise<AcceptedMutation<SandboxSnapshot>> {
    return api.post<AcceptedMutation<SandboxSnapshot>>(
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
    params?: SandboxLogsQueryParams,
    signal?: AbortSignal
  ): Promise<SandboxLogEntry[]> {
    return api.get<SandboxLogEntry[]>(
      `/api/sandboxes/${id}/logs${buildLogQueryString(params)}`, undefined, signal
    );
  },
};
