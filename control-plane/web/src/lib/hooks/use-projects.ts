import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import {
  projectsApi,
  type CreateProjectData,
  type UpdateProjectData,
  type TransferProjectData,
} from "@/lib/api/projects";

export function useProjects() {
  return useQuery({
    queryKey: ["projects"],
    queryFn: () => projectsApi.list(),
  });
}

export function useProjectsForOrganization(organizationId: string | undefined) {
  return useQuery({
    queryKey: ["projects", "organization", organizationId],
    queryFn: () =>
      organizationId
        ? projectsApi.listForOrganization(organizationId)
        : Promise.resolve([]),
    enabled: !!organizationId,
  });
}

export function useProject(projectId: string | undefined) {
  return useQuery({
    queryKey: ["projects", projectId],
    queryFn: () =>
      projectId ? projectsApi.get(projectId) : Promise.reject("No project ID"),
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
