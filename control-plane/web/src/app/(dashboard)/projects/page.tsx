"use client";

import { useState } from "react";
import { FolderKanban, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  ProjectsTable,
  ProjectFormDialog,
  TransferProjectDialog,
} from "@/components/projects";
import { useProjectsForOrganization } from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { Project } from "@/lib/api/projects";

export default function ProjectsPage() {
  const { currentOrg } = useOrganization();
  const orgId = currentOrg?.id;

  const { data: projects = [], isLoading } = useProjectsForOrganization(orgId);
  const canManage = currentOrg?.userRole === "admin";

  const [createOpen, setCreateOpen] = useState(false);
  const [editProject, setEditProject] = useState<Project | null>(null);
  const [transferProject, setTransferProject] = useState<Project | null>(null);

  if (!currentOrg) {
    return (
      <div className="max-w-5xl mx-auto py-12 text-center text-muted-foreground">
        Select an organization to manage its projects.
      </div>
    );
  }

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <FolderKanban className="h-8 w-8 text-blue-600" />
          <div>
            <h1 className="text-2xl font-semibold text-foreground">Projects</h1>
            <p className="text-sm text-muted-foreground">
              Organize VMs and images within {currentOrg.name}
            </p>
          </div>
        </div>
        <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          New Project
        </Button>
      </div>

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            All Projects ({projects.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          {!canManage && (
            <p className="text-sm text-muted-foreground mb-4">
              You need admin rights to edit, transfer, or delete projects.
            </p>
          )}
          <ProjectsTable
            projects={projects}
            isLoading={isLoading}
            canManage={canManage}
            onEdit={setEditProject}
            onTransfer={setTransferProject}
          />
        </CardContent>
      </Card>

      {/* Create */}
      <ProjectFormDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        organizationId={currentOrg.id}
      />

      {/* Edit */}
      <ProjectFormDialog
        open={!!editProject}
        onOpenChange={(open) => !open && setEditProject(null)}
        organizationId={currentOrg.id}
        project={editProject}
      />

      {/* Transfer */}
      <TransferProjectDialog
        open={!!transferProject}
        onOpenChange={(open) => !open && setTransferProject(null)}
        project={transferProject}
      />
    </div>
  );
}
