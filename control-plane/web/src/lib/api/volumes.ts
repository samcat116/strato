// Volume API endpoints

import { api } from "./client";
import type {
  Volume,
  VolumeSnapshot,
  CreateVolumeRequest,
  UpdateVolumeRequest,
  AttachVolumeRequest,
  ResizeVolumeRequest,
  CloneVolumeRequest,
  CreateVolumeSnapshotRequest,
  Page,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

export const volumesApi = {
  list(projectId?: string): Promise<Volume[]> {
    return api
      .get<Page<Volume>>("/api/volumes", {
        limit: LIST_PAGE_LIMIT,
        ...(projectId ? { project_id: projectId } : {}),
      })
      .then((page) => page.items);
  },

  get(id: string): Promise<Volume> {
    return api.get<Volume>(`/api/volumes/${id}`);
  },

  create(data: CreateVolumeRequest): Promise<Volume> {
    return api.post<Volume>("/api/volumes", data);
  },

  update(id: string, data: UpdateVolumeRequest): Promise<Volume> {
    return api.put<Volume>(`/api/volumes/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/volumes/${id}`);
  },

  attach(id: string, data: AttachVolumeRequest): Promise<Volume> {
    return api.post<Volume>(`/api/volumes/${id}/attach`, data);
  },

  detach(id: string): Promise<Volume> {
    return api.post<Volume>(`/api/volumes/${id}/detach`);
  },

  resize(id: string, data: ResizeVolumeRequest): Promise<Volume> {
    return api.post<Volume>(`/api/volumes/${id}/resize`, data);
  },

  snapshot(
    id: string,
    data: CreateVolumeSnapshotRequest
  ): Promise<VolumeSnapshot> {
    return api.post<VolumeSnapshot>(`/api/volumes/${id}/snapshot`, data);
  },

  clone(id: string, data: CloneVolumeRequest): Promise<Volume> {
    return api.post<Volume>(`/api/volumes/${id}/clone`, data);
  },

  listSnapshots(id: string): Promise<VolumeSnapshot[]> {
    return api
      .get<Page<VolumeSnapshot>>(`/api/volumes/${id}/snapshots`, {
        limit: LIST_PAGE_LIMIT,
      })
      .then((page) => page.items);
  },

  deleteSnapshot(volumeId: string, snapshotId: string): Promise<void> {
    return api.delete(`/api/volumes/${volumeId}/snapshots/${snapshotId}`);
  },
};
