import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  projectsApi,
  type CreateProjectData,
  type UpdateProjectData,
  type TransferProjectData,
} from "@/lib/api/projects";

export function useProjectsForOrganization(
  organizationId: string | undefined,
  initialData?: Awaited<ReturnType<typeof projectsApi.listForOrganization>>
) {
  return useQuery({
    queryKey: ["projects", "organization", organizationId],
    queryFn: ({ signal }) =>
      organizationId
        ? projectsApi.listForOrganization(organizationId, signal)
        : Promise.resolve([]),
    enabled: !!organizationId,
    initialData,
  });
}

export function useProject(projectId: string | undefined) {
  return useQuery({
    queryKey: ["projects", projectId],
    queryFn: ({ signal }) =>
      projectId ? projectsApi.get(projectId, signal) : Promise.reject("No project ID"),
    enabled: !!projectId,
  });
}

/**
 * Invalidate every projects query. Project lists are keyed both globally
 * (["projects"]) and per-organization (["projects", "organization", orgId]),
 * so a broad invalidation keeps switchers, the projects page, and scoped
 * resource lists consistent after a mutation.
 */
function invalidateAllProjects(
  queryClient: ReturnType<typeof useQueryClient>
) {
  queryClient.invalidateQueries({ queryKey: ["projects"] });
  // Project names and parent folders are duplicated in hierarchy responses.
  // Keep table breadcrumbs current after create, update, transfer, or delete.
  queryClient.invalidateQueries({ queryKey: ["hierarchy"] });
}

export function useCreateProject(organizationId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateProjectData) =>
      projectsApi.create(organizationId, data),
    onSuccess: () => invalidateAllProjects(queryClient),
  });
}

export function useUpdateProject() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      projectId,
      data,
    }: {
      projectId: string;
      data: UpdateProjectData;
    }) => projectsApi.update(projectId, data),
    onSuccess: () => invalidateAllProjects(queryClient),
  });
}

export function useDeleteProject() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (projectId: string) => projectsApi.delete(projectId),
    onSuccess: () => invalidateAllProjects(queryClient),
  });
}

export function useTransferProject() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      projectId,
      data,
    }: {
      projectId: string;
      data: TransferProjectData;
    }) => projectsApi.transfer(projectId, data),
    onSuccess: () => invalidateAllProjects(queryClient),
  });
}
