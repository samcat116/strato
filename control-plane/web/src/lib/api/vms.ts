// VM API endpoints

import { api } from "./client";
import type {
  VM,
  CreateVMRequest,
  UpdateVMRequest,
  Operation,
  VMLogEntry,
  VMLogsQueryParams,
} from "@/types/api";

// Lifecycle mutations are asynchronous: the server responds 202 Accepted with
// an Operation record, and the actual work completes in the background. Poll
// operationsApi.get (see OperationWatcher) until the operation is terminal.
export const vmsApi = {
  list(): Promise<VM[]> {
    return api.get<VM[]>("/api/vms");
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
