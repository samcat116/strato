// Volume API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  AcceptedMutation,
  Volume,
  VolumeSnapshot,
  CreateVolumeRequest,
  AttachVolumeRequest,
  ResizeVolumeRequest,
  CloneVolumeRequest,
  CreateVolumeSnapshotRequest,
} from "@/types/api-contracts";

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
  list(projectId?: string, signal?: AbortSignal): Promise<Volume[]> {
    return listAllPages<Volume>(
      "/api/volumes",
      projectId ? { project_id: projectId } : {}, signal
    );
  },

  get(id: string, signal?: AbortSignal): Promise<Volume> {
    return api.get<Volume>(`/api/volumes/${id}`, undefined, signal);
  },

  create(data: CreateVolumeRequest, idempotencyKey?: string): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(
      "/api/volumes", data, undefined, idempotencyKey
    );
  },

  delete(id: string, idempotencyKey?: string): Promise<AcceptedMutation<Volume>> {
    return api.delete<AcceptedMutation<Volume>>(
      `/api/volumes/${id}`, undefined, idempotencyKey
    );
  },

  attach(
    id: string,
    data: AttachVolumeRequest,
    idempotencyKey?: string
  ): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(
      `/api/volumes/${id}/attach`, data, undefined, idempotencyKey
    );
  },

  detach(id: string, idempotencyKey?: string): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(
      `/api/volumes/${id}/detach`, undefined, undefined, idempotencyKey
    );
  },

  resize(
    id: string,
    data: ResizeVolumeRequest,
    idempotencyKey?: string
  ): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(
      `/api/volumes/${id}/resize`, data, undefined, idempotencyKey
    );
  },

  snapshot(
    id: string,
    data: CreateVolumeSnapshotRequest,
    idempotencyKey?: string
  ): Promise<AcceptedMutation<VolumeSnapshot>> {
    return api.post<AcceptedMutation<VolumeSnapshot>>(
      `/api/volumes/${id}/snapshot`,
      data,
      undefined,
      idempotencyKey
    );
  },

  clone(
    id: string, data: CloneVolumeRequest, idempotencyKey?: string
  ): Promise<AcceptedMutation<Volume>> {
    return api.post<AcceptedMutation<Volume>>(
      `/api/volumes/${id}/clone`, data, undefined, idempotencyKey
    );
  },

  listSnapshots(id: string, signal?: AbortSignal): Promise<VolumeSnapshot[]> {
    return listAllPages<VolumeSnapshot>(`/api/volumes/${id}/snapshots`, {}, signal);
  },

  listProjectSnapshots(projectId: string, signal?: AbortSignal): Promise<VolumeSnapshot[]> {
    return listAllPages<VolumeSnapshot>("/api/volume-snapshots", {
      project_id: projectId,
    }, signal);
  },

  deleteSnapshot(
    volumeId: string,
    snapshotId: string,
    idempotencyKey?: string
  ): Promise<AcceptedMutation<VolumeSnapshot>> {
    return api.delete<AcceptedMutation<VolumeSnapshot>>(
      `/api/volumes/${volumeId}/snapshots/${snapshotId}`, undefined, idempotencyKey
    );
  },
};
