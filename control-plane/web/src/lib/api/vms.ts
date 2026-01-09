// VM API endpoints

import { api } from "./client";
import type { VM, CreateVMRequest, UpdateVMRequest } from "@/types/api";

export const vmsApi = {
  list(): Promise<VM[]> {
    return api.get<VM[]>("/vms");
  },

  get(id: string): Promise<VM> {
    return api.get<VM>(`/vms/${id}`);
  },

  create(data: CreateVMRequest): Promise<VM> {
    return api.post<VM>("/vms", data);
  },

  update(id: string, data: UpdateVMRequest): Promise<VM> {
    return api.put<VM>(`/vms/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/vms/${id}`);
  },

  start(id: string): Promise<VM> {
    return api.post<VM>(`/vms/${id}/start`);
  },

  stop(id: string): Promise<VM> {
    return api.post<VM>(`/vms/${id}/stop`);
  },

  restart(id: string): Promise<VM> {
    return api.post<VM>(`/vms/${id}/restart`);
  },

  pause(id: string): Promise<VM> {
    return api.post<VM>(`/vms/${id}/pause`);
  },

  resume(id: string): Promise<VM> {
    return api.post<VM>(`/vms/${id}/resume`);
  },

  getStatus(id: string): Promise<{ status: string }> {
    return api.get(`/vms/${id}/status`);
  },
};
