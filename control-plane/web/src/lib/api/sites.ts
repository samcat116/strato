// Site (availability zone) API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  CephCluster,
  CephProjectAccess,
  ConfigureCephProjectAccessRequest,
  Site,
  CreateSiteRequest,
  RegisterCephClusterRequest,
  StoragePool,
  UpdateCephClusterRequest,
  UpdateSiteRequest,
} from "@/types/api";

export const sitesApi = {
  list(organizationId?: string, signal?: AbortSignal): Promise<Site[]> {
    return listAllPages<Site>(
      "/api/sites",
      organizationId ? { organization_id: organizationId } : {}, signal
    );
  },

  create(data: CreateSiteRequest): Promise<Site> {
    return api.post<Site>("/api/sites", data);
  },

  // PUT is full-replace for descriptive fields; an omitted `status` leaves the
  // current lifecycle unchanged. Callers building an update from an existing
  // Site should echo the fields they want to keep.
  update(id: string, data: UpdateSiteRequest): Promise<Site> {
    return api.put<Site>(`/api/sites/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/sites/${id}`);
  },

  getCephCluster(id: string, signal?: AbortSignal): Promise<CephCluster> {
    return api.get<CephCluster>(`/api/sites/${id}/ceph-cluster`, undefined, signal);
  },

  registerCephCluster(
    id: string,
    data: RegisterCephClusterRequest
  ): Promise<CephCluster> {
    return api.post<CephCluster>(`/api/sites/${id}/ceph-cluster`, data);
  },

  updateCephCluster(
    id: string,
    data: UpdateCephClusterRequest
  ): Promise<CephCluster> {
    return api.put<CephCluster>(`/api/sites/${id}/ceph-cluster`, data);
  },

  deleteCephCluster(id: string): Promise<void> {
    return api.delete(`/api/sites/${id}/ceph-cluster`);
  },

  getCephProjectAccess(
    siteId: string,
    projectId: string,
    signal?: AbortSignal
  ): Promise<CephProjectAccess> {
    return api.get<CephProjectAccess>(
      `/api/sites/${siteId}/ceph-cluster/projects/${projectId}`,
      undefined,
      signal
    );
  },

  configureCephProjectAccess(
    siteId: string,
    projectId: string,
    data: ConfigureCephProjectAccessRequest
  ): Promise<CephProjectAccess> {
    return api.put<CephProjectAccess>(
      `/api/sites/${siteId}/ceph-cluster/projects/${projectId}`,
      data
    );
  },

  deleteCephProjectAccess(
    siteId: string,
    projectId: string,
    cephxRevoked: boolean
  ): Promise<void> {
    return api.delete(
      `/api/sites/${siteId}/ceph-cluster/projects/${projectId}?cephxRevoked=${cephxRevoked}`
    );
  },

  listProjectStoragePools(
    projectId: string,
    signal?: AbortSignal
  ): Promise<StoragePool[]> {
    return api.get<StoragePool[]>(
      `/api/projects/${projectId}/storage-pools`,
      undefined,
      signal
    );
  },
};
