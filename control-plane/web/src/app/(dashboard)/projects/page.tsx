"use client";

import { useMemo, useState } from "react";
import { FolderKanban, Plus, Search, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import {
  ProjectsTable,
  ProjectFormDialog,
  TransferProjectDialog,
} from "@/components/projects";
import {
  buildProjectFolderOptions,
  buildProjectTableRows,
} from "@/components/projects/project-table-model";
import {
  useHierarchy,
  usePermissions,
  useProjectsForOrganization,
} from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { Project } from "@/lib/api/projects";

export default function ProjectsPage() {
  const { currentOrg } = useOrganization();
  const orgId = currentOrg?.id;

  const projectsQuery = useProjectsForOrganization(orgId);
  const { data: projects = [], isLoading: projectsLoading } = projectsQuery;
  const hierarchyQuery = useHierarchy(orgId);
  const { permissions } = usePermissions([
    ...(orgId
      ? [
          {
            key: "create",
            action: "project:create",
            node: { type: "organization", id: orgId },
          },
        ]
      : []),
    ...projects.flatMap((project) => [
      {
        key: `update:${project.id}`,
        action: "project:update",
        node: { type: "project", id: project.id },
      },
      {
        key: `transfer:${project.id}`,
        action: "project:transfer",
        node: { type: "project", id: project.id },
      },
      {
        key: `delete:${project.id}`,
        action: "project:delete",
        node: { type: "project", id: project.id },
      },
    ]),
  ]);
  const canCreate = permissions.create;

  const [query, setQuery] = useState("");
  const [createOpen, setCreateOpen] = useState(false);
  const [editProject, setEditProject] = useState<Project | null>(null);
  const [transferProject, setTransferProject] = useState<Project | null>(null);

  const organizationHierarchy = hierarchyQuery.data?.organization;
  const rows = useMemo(
    () => buildProjectTableRows(projects, organizationHierarchy, query),
    [projects, organizationHierarchy, query]
  );
  const folderOptions = useMemo(
    () => buildProjectFolderOptions(organizationHierarchy),
    [organizationHierarchy]
  );

  if (!currentOrg) {
    return (
      <div className="max-w-6xl mx-auto py-12 text-center text-muted-foreground">
        Select an organization to manage its projects.
      </div>
    );
  }

  const isSearching = query.trim().length > 0;

  return (
    <div className="max-w-6xl mx-auto space-y-6">
      <div className="flex items-center justify-between gap-4">
        <div className="flex min-w-0 items-center gap-3">
          <FolderKanban className="h-8 w-8 shrink-0 text-blue-600" />
          <div className="min-w-0">
            <h1 className="text-2xl font-semibold text-foreground">Projects</h1>
            <p className="truncate text-sm text-muted-foreground">
              All projects in {currentOrg.name}, organized by their place in the
              hierarchy
            </p>
          </div>
        </div>
        {canCreate && (
          <Button
            className="shrink-0 bg-primary hover:bg-primary/90"
            onClick={() => setCreateOpen(true)}
          >
            <Plus className="h-4 w-4 mr-2" />
            New Project
          </Button>
        )}
      </div>

      <QueryErrorNotice
        resource="projects"
        error={projectsQuery.error}
        hasData={projectsQuery.data !== undefined}
        onRetry={() => void projectsQuery.refetch()}
      />
      <QueryErrorNotice
        resource="project hierarchy"
        error={hierarchyQuery.error}
        hasData={hierarchyQuery.data !== undefined}
        onRetry={() => void hierarchyQuery.refetch()}
      />

      <div className="overflow-hidden rounded-lg border border-border bg-card">
        <div className="flex flex-col gap-3 border-b border-border px-4 py-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 className="font-semibold text-foreground">
              All Projects ({projects.length})
            </h2>
            {!canCreate && (
              <p className="text-xs text-muted-foreground">
                You do not have permission to create projects.
              </p>
            )}
          </div>
          <div className="relative w-full sm:w-80">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search projects or locations..."
              className="bg-background border-border text-foreground pl-9 pr-9"
            />
            {isSearching && (
              <button
                type="button"
                onClick={() => setQuery("")}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                aria-label="Clear search"
              >
                <X className="h-4 w-4" />
              </button>
            )}
          </div>
        </div>

        <ProjectsTable
          rows={rows}
          organizationName={currentOrg.name}
          isLoading={projectsLoading || hierarchyQuery.isLoading}
          actionsFor={(project) => ({
            canUpdate: permissions[`update:${project.id}`],
            canTransfer: permissions[`transfer:${project.id}`],
            canDelete: permissions[`delete:${project.id}`],
          })}
          onEdit={setEditProject}
          onTransfer={setTransferProject}
          emptyMessage={
            isSearching
              ? `No projects match "${query.trim()}".`
              : "No projects yet. Create one to organize your VMs and images."
          }
        />
      </div>

      <ProjectFormDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        organizationId={currentOrg.id}
        organizationName={currentOrg.name}
        folderOptions={folderOptions}
      />

      <ProjectFormDialog
        open={!!editProject}
        onOpenChange={(open) => !open && setEditProject(null)}
        organizationId={currentOrg.id}
        organizationName={currentOrg.name}
        folderOptions={folderOptions}
        project={editProject}
      />

      <TransferProjectDialog
        open={!!transferProject}
        onOpenChange={(open) => !open && setTransferProject(null)}
        project={transferProject}
      />
    </div>
  );
}
