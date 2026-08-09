// Volume API endpoints

import { api } from "./client";
import type {
  AcceptedMutation,
  Volume,
  VolumeSnapshot,
  CreateVolumeRequest,
  AttachVolumeRequest,
  ResizeVolumeRequest,
  CloneVolumeRequest,
  CreateVolumeSnapshotRequest,
  Page,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

// Volume lifecycle mutations are asynchronous since backend STR-148: the
// server responds 202 Accepted with the volume, the generation it now has to
// converge on, and the id of the mutation's audit record. The work completes in
// the background; MutationWatcher refetches the volume until its `conditions`
// say it converged — or, for a delete, polls operationsApi.get(mutationId),
// because a deleted volume has nothing left to refetch.
//
// Snapshot verbs are asynchronous too — snapshots became desired artifacts in
// backend ADR 0001 stage 8 (STR-150), so capture and delete answer 202 like
// every other mutation.
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

  create(data: CreateVolumeRequest): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>("/api/volumes", data);
  },

  delete(id: string): Promise<AcceptedMutation<Volume>> {
    return api.delete<AcceptedMutation<Volume>>(`/api/volumes/${id}`);
  },

  attach(
    id: string,
    data: AttachVolumeRequest
  ): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(`/api/volumes/${id}/attach`, data);
  },

  detach(id: string): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(`/api/volumes/${id}/detach`);
  },

  resize(
    id: string,
    data: ResizeVolumeRequest
  ): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(`/api/volumes/${id}/resize`, data);
  },

  snapshot(
    id: string,
    data: CreateVolumeSnapshotRequest
  ): Promise<AcceptedMutation<VolumeSnapshot>> {
    return api.post<AcceptedMutation<VolumeSnapshot>>(
      `/api/volumes/${id}/snapshot`,
      data
    );
  },

  clone(id: string, data: CloneVolumeRequest): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(`/api/volumes/${id}/clone`, data);
  },

  listSnapshots(id: string): Promise<VolumeSnapshot[]> {
    return api
      .get<Page<VolumeSnapshot>>(`/api/volumes/${id}/snapshots`, {
        limit: LIST_PAGE_LIMIT,
      })
      .then((page) => page.items);
  },

  deleteSnapshot(
    volumeId: string,
    snapshotId: string
  ): Promise<AcceptedMutation<VolumeSnapshot>> {
    return api.delete<AcceptedMutation<VolumeSnapshot>>(
      `/api/volumes/${volumeId}/snapshots/${snapshotId}`
    );
  },
};
