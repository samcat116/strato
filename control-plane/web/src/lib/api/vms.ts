// VM API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import { buildLogQueryString } from "./logs";
import type {
  VM,
  CreateVMRequest,
  PatchVMMetadataRequest,
  AcceptedMutation,
  VMLogEntry,
  VMLogsQueryParams,
  VMSnapshot,
  CreateVMSnapshotRequest,
  VNCSession,
  VMNetworkInterface,
  CreateVMNetworkInterfaceRequest,
} from "@/types/api-contracts";

// Lifecycle mutations are asynchronous: the server responds 202 Accepted with
// the VM, the generation it now has to converge on, and the id of the
// mutation's audit record (backend STR-147). The work completes in the
// background; MutationWatcher refetches the VM until its `conditions` say it
// converged — or, for a delete, polls operationsApi.get(mutationId), because a
// deleted VM has nothing left to refetch.
export const vmsApi = {
  list(organizationId?: string, signal?: AbortSignal): Promise<VM[]> {
    return listAllPages<VM>(
      "/api/vms",
      organizationId ? { organization_id: organizationId } : {}, signal
    );
  },

  get(id: string, signal?: AbortSignal): Promise<VM> {
    return api.get<VM>(`/api/vms/${id}`, undefined, signal);
  },

  create(data: CreateVMRequest, idempotencyKey?: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>("/api/vms", data, undefined, idempotencyKey);
  },

  patchMetadata(id: string, data: PatchVMMetadataRequest): Promise<VM> {
    return api.patch<VM>(`/api/vms/${id}`, data);
  },

  listInterfaces(id: string): Promise<VMNetworkInterface[]> {
    return api.get<VMNetworkInterface[]>(`/api/vms/${id}/interfaces`);
  },

  attachInterface(
    id: string,
    data: CreateVMNetworkInterfaceRequest,
    idempotencyKey?: string
  ): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/interfaces`, data, undefined, idempotencyKey
    );
  },

  detachInterface(
    id: string, interfaceId: string, idempotencyKey?: string
  ): Promise<AcceptedMutation<VM>> {
    return api.delete<AcceptedMutation<VM>>(
      `/api/vms/${id}/interfaces/${interfaceId}`, undefined, idempotencyKey
    );
  },

  retryInterface(
    id: string, interfaceId: string, idempotencyKey?: string
  ): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/interfaces/${interfaceId}/retry`, undefined, undefined, idempotencyKey
    );
  },

  // Mint a single-use graphics console session. Throws ApiError with the
  // server's reason when the VM has no display (409), or when its agent cannot
  // serve one right now (503) — surface that text rather than a generic
  // failure, since each case has a different remedy.
  startVNCSession(id: string): Promise<VNCSession> {
    return api.post<VNCSession>(`/api/vms/${id}/console/vnc`, {});
  },

  delete(id: string, idempotencyKey?: string): Promise<AcceptedMutation<VM>> {
    return api.delete<AcceptedMutation<VM>>(`/api/vms/${id}`, undefined, idempotencyKey);
  },

  start(id: string, idempotencyKey?: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/start`, undefined, undefined, idempotencyKey
    );
  },

  stop(id: string, idempotencyKey?: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/stop`, undefined, undefined, idempotencyKey
    );
  },

  // Restart joined the rest at backend STR-151: a reboot rides the sync as a
  // monotonic nonce on the VM's desired entry, so it has a generation to
  // converge on like every other mutation.
  restart(id: string, idempotencyKey?: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/restart`, undefined, undefined, idempotencyKey
    );
  },

  pause(id: string, idempotencyKey?: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/pause`, undefined, undefined, idempotencyKey
    );
  },

  resume(id: string, idempotencyKey?: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/resume`, undefined, undefined, idempotencyKey
    );
  },

  // Full-VM checkpoints (issue #564): memory + device state + disks captured
  // at one instant, distinct from the disk-only volume snapshots. Capture and
  // delete are desired state on the checkpoint itself (STR-150); restore is an
  // edge-nonce on the VM's desired entry (STR-151) — see restoreSnapshot below.
  listSnapshots(id: string, signal?: AbortSignal): Promise<VMSnapshot[]> {
    return listAllPages<VMSnapshot>(`/api/vms/${id}/snapshots`, {}, signal);
  },

  createSnapshot(
    id: string,
    data?: CreateVMSnapshotRequest,
    idempotencyKey?: string
  ): Promise<AcceptedMutation<VMSnapshot>> {
    return api.post<AcceptedMutation<VMSnapshot>>(
      `/api/vms/${id}/snapshots`,
      data ?? {},
      undefined,
      idempotencyKey
    );
  },

  deleteSnapshot(
    id: string,
    snapshotId: string,
    idempotencyKey?: string
  ): Promise<AcceptedMutation<VMSnapshot>> {
    return api.delete<AcceptedMutation<VMSnapshot>>(
      `/api/vms/${id}/snapshots/${snapshotId}`, undefined, idempotencyKey
    );
  },

  // A restore acts on the VM, not on the checkpoint, so its 202 carries the VM
  // and the generation to wait for (backend STR-151).
  restoreSnapshot(
    id: string, snapshotId: string, idempotencyKey?: string
  ): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/snapshots/${snapshotId}/restore`, undefined, undefined, idempotencyKey
    );
  },

  getLogs(id: string, params?: VMLogsQueryParams, signal?: AbortSignal): Promise<VMLogEntry[]> {
    return api.get<VMLogEntry[]>(
      `/api/vms/${id}/logs${buildLogQueryString(params)}`, undefined, signal
    );
  },
};
