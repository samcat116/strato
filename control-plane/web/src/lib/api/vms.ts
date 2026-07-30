// VM API endpoints

import { api } from "./client";
import type {
  VM,
  CreateVMRequest,
  UpdateVMRequest,
  Operation,
  Page,
  VMLogEntry,
  VMLogsQueryParams,
  VMSnapshot,
  CreateVMSnapshotRequest,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

// Lifecycle mutations are asynchronous: the server responds 202 Accepted with
// an Operation record, and the actual work completes in the background. Poll
// operationsApi.get (see OperationWatcher) until the operation is terminal.
export const vmsApi = {
  list(organizationId?: string): Promise<VM[]> {
    return api
      .get<Page<VM>>("/api/vms", {
        limit: LIST_PAGE_LIMIT,
        ...(organizationId ? { organization_id: organizationId } : {}),
      })
      .then((page) => page.items);
  },

  get(id: string): Promise<VM> {
    return api.get<VM>(`/api/vms/${id}`);
  },

  create(data: CreateVMRequest): Promise<Operation> {
    return api.post<Operation>("/api/vms", data);
  },

  update(id: string, data: UpdateVMRequest): Promise<VM> {
    return api.put<VM>(`/api/vms/${id}`, data);
  },

  delete(id: string): Promise<Operation> {
    return api.delete<Operation>(`/api/vms/${id}`);
  },

  start(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/vms/${id}/start`);
  },

  stop(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/vms/${id}/stop`);
  },

  restart(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/vms/${id}/restart`);
  },

  pause(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/vms/${id}/pause`);
  },

  resume(id: string): Promise<Operation> {
    return api.post<Operation>(`/api/vms/${id}/resume`);
  },

  listOperations(id: string, limit?: number): Promise<Operation[]> {
    return api.get<Operation[]>(
      `/api/vms/${id}/operations${limit ? `?limit=${limit}` : ""}`
    );
  },

  getStatus(id: string): Promise<{ status: string }> {
    return api.get(`/api/vms/${id}/status`);
  },

  // Full-VM checkpoints (issue #564): memory + device state + disks captured
  // at one instant, distinct from the disk-only volume snapshots. All three
  // mutations are 202 + operation, like the rest of the VM lifecycle.
  listSnapshots(id: string): Promise<VMSnapshot[]> {
    return api
      .get<Page<VMSnapshot>>(`/api/vms/${id}/snapshots`, {
        limit: LIST_PAGE_LIMIT,
      })
      .then((page) => page.items);
  },

  createSnapshot(
    id: string,
    data?: CreateVMSnapshotRequest
  ): Promise<Operation> {
    return api.post<Operation>(`/api/vms/${id}/snapshots`, data ?? {});
  },

  deleteSnapshot(id: string, snapshotId: string): Promise<Operation> {
    return api.delete<Operation>(`/api/vms/${id}/snapshots/${snapshotId}`);
  },

  restoreSnapshot(id: string, snapshotId: string): Promise<Operation> {
    return api.post<Operation>(
      `/api/vms/${id}/snapshots/${snapshotId}/restore`
    );
  },

  getLogs(id: string, params?: VMLogsQueryParams): Promise<VMLogEntry[]> {
    const searchParams = new URLSearchParams();
    if (params?.limit) searchParams.set("limit", String(params.limit));
    if (params?.direction) searchParams.set("direction", params.direction);
    if (params?.start) searchParams.set("start", String(params.start));
    if (params?.end) searchParams.set("end", String(params.end));

    const query = searchParams.toString();
    return api.get<VMLogEntry[]>(
      `/api/vms/${id}/logs${query ? `?${query}` : ""}`
    );
  },
};
