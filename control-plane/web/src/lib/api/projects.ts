// Projects API endpoints

import { api } from "./client";

export interface Project {
  id: string;
  name: string;
  description: string;
  organizationId?: string;
  organizationalUnitId?: string;
  path: string;
  defaultEnvironment: string;
  environments: string[];
  createdAt: string;
  vmCount?: number;
}

export const projectsApi = {
  // Get all projects for the current user
  list(): Promise<Project[]> {
    return api.get<Project[]>("/api/projects");
  },

  // Get projects for a specific organization
  listForOrganization(organizationId: string): Promise<Project[]> {
    return api.get<Project[]>(`/api/organizations/${organizationId}/projects`);
  },

  // Get a specific project
  get(projectId: string): Promise<Project> {
    return api.get<Project>(`/api/projects/${projectId}`);
  },

  // Create a project in an organization
  create(
    organizationId: string,
    data: { name: string; description?: string; environments?: string[] }
  ): Promise<Project> {
    return api.post<Project>(
      `/api/organizations/${organizationId}/projects`,
      data
    );
  },

  // Update a project
  update(
    projectId: string,
    data: { name?: string; description?: string; defaultEnvironment?: string }
  ): Promise<Project> {
    return api.put<Project>(`/api/projects/${projectId}`, data);
  },

  // Delete a project
  delete(projectId: string): Promise<void> {
    return api.delete(`/api/projects/${projectId}`);
  },
};
