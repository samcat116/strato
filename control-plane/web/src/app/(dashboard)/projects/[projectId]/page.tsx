"use client";

import { useParams } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, FolderKanban } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { ProjectMembersSection } from "@/components/project-members";
import { RolesSection, PoliciesSection } from "@/components/iam";
import { useProject, usePermissions } from "@/lib/hooks";
import { useOrganization } from "@/providers";

export default function ProjectDetailPage() {
  const params = useParams();
  const projectId = params.projectId as string;
  const { currentOrg } = useOrganization();

  const { data: project, isLoading } = useProject(projectId);
  const organizationId = project?.organizationId ?? currentOrg?.id ?? "";

  const { permissions } = usePermissions([
    {
      key: "manage_project",
      resourceType: "project",
      resourceId: projectId,
      permission: "manage_project",
    },
  ]);
  const canManage = permissions.manage_project;

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <Link
        href="/projects"
        className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="h-4 w-4" />
        Back to projects
      </Link>

      <div className="flex items-center gap-3">
        <FolderKanban className="h-8 w-8 text-blue-600" />
        <div>
          {isLoading ? (
            <Skeleton className="h-8 w-48 bg-muted" />
          ) : (
            <h1 className="text-2xl font-semibold text-foreground">
              {project?.name ?? "Project"}
            </h1>
          )}
          {project?.description && (
            <p className="text-sm text-muted-foreground">{project.description}</p>
          )}
        </div>
      </div>

      {isLoading ? (
        <Card className="bg-card border-border">
          <CardContent className="py-8">
            <Skeleton className="h-24 w-full bg-muted" />
          </CardContent>
        </Card>
      ) : (
        <>
          <ProjectMembersSection
            projectId={projectId}
            organizationId={organizationId}
          />
          <RolesSection
            ownerType="project"
            ownerId={projectId}
            canManage={canManage}
          />
          <PoliciesSection
            ownerType="project"
            ownerId={projectId}
            canManage={canManage}
          />
        </>
      )}
    </div>
  );
}
