// VM API endpoints

import { api } from "./client";
import { buildLogQueryString } from "./logs";
import type {
  VM,
  CreateVMRequest,
  AcceptedMutation,
  Page,
  VMLogEntry,
  VMLogsQueryParams,
  VMSnapshot,
  CreateVMSnapshotRequest,
  VNCSession,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

// Lifecycle mutations are asynchronous: the server responds 202 Accepted with
// the VM, the generation it now has to converge on, and the id of the
// mutation's audit record (backend STR-147). The work completes in the
// background; MutationWatcher refetches the VM until its `conditions` say it
// converged — or, for a delete, polls operationsApi.get(mutationId), because a
// deleted VM has nothing left to refetch.
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

  create(data: CreateVMRequest): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>("/api/vms", data);
  },

  // Mint a single-use graphics console session. Throws ApiError with the
  // server's reason when the VM has no display (409), or when its agent cannot
  // serve one right now (503) — surface that text rather than a generic
  // failure, since each case has a different remedy.
  startVNCSession(id: string): Promise<VNCSession> {
    return api.post<VNCSession>(`/api/vms/${id}/console/vnc`, {});
  },

  delete(id: string): Promise<AcceptedMutation<VM>> {
    return api.delete<AcceptedMutation<VM>>(`/api/vms/${id}`);
  },

  start(id: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(`/api/vms/${id}/start`);
  },

  stop(id: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(`/api/vms/${id}/stop`);
  },

  // Restart joined the rest at backend STR-151: a reboot rides the sync as a
  // monotonic nonce on the VM's desired entry, so it has a generation to
  // converge on like every other mutation.
  restart(id: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(`/api/vms/${id}/restart`);
  },

  pause(id: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(`/api/vms/${id}/pause`);
  },

  resume(id: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(`/api/vms/${id}/resume`);
  },

  // Full-VM checkpoints (issue #564): memory + device state + disks captured
  // at one instant, distinct from the disk-only volume snapshots. Capture and
  // delete are desired state on the checkpoint itself (STR-150); restore is an
  // edge-nonce on the VM's desired entry (STR-151) — see restoreSnapshot below.
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
  ): Promise<AcceptedMutation<VMSnapshot>> {
    return api.post<AcceptedMutation<VMSnapshot>>(
      `/api/vms/${id}/snapshots`,
      data ?? {}
    );
  },

  deleteSnapshot(
    id: string,
    snapshotId: string
  ): Promise<AcceptedMutation<VMSnapshot>> {
    return api.delete<AcceptedMutation<VMSnapshot>>(
      `/api/vms/${id}/snapshots/${snapshotId}`
    );
  },

  // A restore acts on the VM, not on the checkpoint, so its 202 carries the VM
  // and the generation to wait for (backend STR-151).
  restoreSnapshot(id: string, snapshotId: string): Promise<AcceptedMutation<VM>> {
    return api.post<AcceptedMutation<VM>>(
      `/api/vms/${id}/snapshots/${snapshotId}/restore`
    );
  },

  getLogs(id: string, params?: VMLogsQueryParams): Promise<VMLogEntry[]> {
    return api.get<VMLogEntry[]>(
      `/api/vms/${id}/logs${buildLogQueryString(params)}`
    );
  },
};
