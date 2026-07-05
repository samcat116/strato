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
} from "@/types/api";

export const volumesApi = {
  list(projectId?: string): Promise<Volume[]> {
    return api.get<Volume[]>(
      "/api/volumes",
      projectId ? { project_id: projectId } : undefined
    );
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
    return api.get<VolumeSnapshot[]>(`/api/volumes/${id}/snapshots`);
  },

  deleteSnapshot(volumeId: string, snapshotId: string): Promise<void> {
    return api.delete(`/api/volumes/${volumeId}/snapshots/${snapshotId}`);
  },
};
