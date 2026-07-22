// Projects API endpoints

import { api } from "./client";
import type { components } from "@/types/openapi";

// Projects are the first surface whose types come from the OpenAPI document
// instead of being hand-maintained (issue #583) — the same document the
// control plane generates its handlers from, so these cannot drift from the
// server. Regenerate `src/types/openapi.ts` with `bun run generate:api-types`.
type Schemas = components["schemas"];

export type Project = Schemas["ProjectSummary"];
/** A single-project read, which additionally carries the project's quotas. */
export type ProjectDetail = Schemas["ProjectDetail"];
/** `description` is required by the API; the create helper defaults it. */
export type CreateProjectData = Omit<Schemas["CreateProjectRequest"], "description"> & {
  description?: string;
};
export type UpdateProjectData = Schemas["UpdateProjectRequest"];
export type TransferProjectData = Schemas["TransferProjectRequest"];

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
  get(projectId: string): Promise<ProjectDetail> {
    return api.get<ProjectDetail>(`/api/projects/${projectId}`);
  },

  // Create a project in an organization
  create(
    organizationId: string,
    data: CreateProjectData
  ): Promise<Project> {
    // The backend requires a non-optional description; default to an empty string.
    return api.post<Project>(`/api/organizations/${organizationId}/projects`, {
      ...data,
      description: data.description ?? "",
    });
  },

  // Update a project
  update(projectId: string, data: UpdateProjectData): Promise<Project> {
    return api.put<Project>(`/api/projects/${projectId}`, data);
  },

  // Delete a project
  delete(projectId: string): Promise<void> {
    return api.delete(`/api/projects/${projectId}`);
  },

  // Transfer a project to a different organization or folder
  transfer(projectId: string, data: TransferProjectData): Promise<Project> {
    return api.post<Project>(`/api/projects/${projectId}/transfer`, data);
  },
};
