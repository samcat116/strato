// Folder API endpoints (scoped to an organization).
//
// Folders are still called "organizational units" on the wire — the route
// segment is `/ous` and the DTO fields keep their `ou` spellings. The wire
// rename lands with the Cedar cutover.

import { api } from "./client";
import type {
  Folder,
  FolderTreeNode,
  CreateFolderRequest,
  UpdateFolderRequest,
} from "@/types/api";

export const foldersApi = {
  /** Top-level folders for the organization. */
  list(orgId: string): Promise<Folder[]> {
    return api.get<Folder[]>(`/api/organizations/${orgId}/ous`);
  },

  get(orgId: string, ouId: string): Promise<Folder> {
    return api.get<Folder>(`/api/organizations/${orgId}/ous/${ouId}`);
  },

  /** Full recursive subtree rooted at the given folder. */
  tree(orgId: string, ouId: string): Promise<FolderTreeNode> {
    return api.get<FolderTreeNode>(
      `/api/organizations/${orgId}/ous/${ouId}/tree`
    );
  },

  create(orgId: string, data: CreateFolderRequest): Promise<Folder> {
    return api.post<Folder>(`/api/organizations/${orgId}/ous`, data);
  },

  update(
    orgId: string,
    ouId: string,
    data: UpdateFolderRequest
  ): Promise<Folder> {
    return api.put<Folder>(`/api/organizations/${orgId}/ous/${ouId}`, data);
  },

  delete(orgId: string, ouId: string): Promise<void> {
    return api.delete(`/api/organizations/${orgId}/ous/${ouId}`);
  },
};
