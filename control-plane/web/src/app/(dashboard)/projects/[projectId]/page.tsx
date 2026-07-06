"use client";

import { useParams } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, FolderKanban } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { ProjectMembersSection } from "@/components/project-members";
import { useProject } from "@/lib/hooks";
import { useOrganization } from "@/providers";

export default function ProjectDetailPage() {
  const params = useParams();
  const projectId = params.projectId as string;
  const { currentOrg } = useOrganization();

  const { data: project, isLoading } = useProject(projectId);
  const organizationId = project?.organizationId ?? currentOrg?.id ?? "";

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <Link
        href="/projects"
        className="inline-flex items-center gap-2 text-sm text-gray-400 hover:text-gray-200"
      >
        <ArrowLeft className="h-4 w-4" />
        Back to projects
      </Link>

      <div className="flex items-center gap-3">
        <FolderKanban className="h-8 w-8 text-blue-400" />
        <div>
          {isLoading ? (
            <Skeleton className="h-8 w-48 bg-gray-700" />
          ) : (
            <h1 className="text-2xl font-semibold text-gray-100">
              {project?.name ?? "Project"}
            </h1>
          )}
          {project?.description && (
            <p className="text-sm text-gray-400">{project.description}</p>
          )}
        </div>
      </div>

      {isLoading ? (
        <Card className="bg-gray-800 border-gray-700">
          <CardContent className="py-8">
            <Skeleton className="h-24 w-full bg-gray-700" />
          </CardContent>
        </Card>
      ) : (
        <ProjectMembersSection
          projectId={projectId}
          organizationId={organizationId}
        />
      )}
    </div>
  );
}
