"use client";

import { useState } from "react";
import Link from "next/link";
import { MoreHorizontal, Pencil, ArrowRightLeft, Trash2 } from "lucide-react";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useDeleteProject } from "@/lib/hooks";
import type { Project } from "@/lib/api/projects";
import { toast } from "sonner";

interface ProjectsTableProps {
  projects: Project[];
  isLoading?: boolean;
  /** Whether the current user can edit/transfer/delete projects (org admin). */
  canManage: boolean;
  onEdit: (project: Project) => void;
  onTransfer: (project: Project) => void;
}

export function ProjectsTable({
  projects,
  isLoading,
  canManage,
  onEdit,
  onTransfer,
}: ProjectsTableProps) {
  const deleteProject = useDeleteProject();
  const [pendingId, setPendingId] = useState<string | null>(null);

  const handleDelete = async (project: Project) => {
    if (
      !window.confirm(
        `Delete project "${project.name}"? This cannot be undone. Projects with VMs cannot be deleted.`
      )
    ) {
      return;
    }
    setPendingId(project.id);
    try {
      await deleteProject.mutateAsync(project.id);
      toast.success(`Deleted "${project.name}"`);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to delete project"
      );
    } finally {
      setPendingId(null);
    }
  };

  if (isLoading) {
    return (
      <div className="space-y-3">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (projects.length === 0) {
    return (
      <div className="py-12 text-center text-muted-foreground">
        No projects yet. Create one to organize your VMs and images.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader>
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground">Name</TableHead>
          <TableHead className="text-muted-foreground">Environments</TableHead>
          <TableHead className="text-muted-foreground text-right">VMs</TableHead>
          {canManage && (
            <TableHead className="text-muted-foreground w-12 text-right">
              Actions
            </TableHead>
          )}
        </TableRow>
      </TableHeader>
      <TableBody>
        {projects.map((project) => (
          <TableRow key={project.id} className="border-border">
            <TableCell>
              <Link
                href={`/projects/${project.id}`}
                className="font-medium text-foreground hover:text-blue-700 hover:underline"
              >
                {project.name}
              </Link>
              {project.description && (
                <div className="text-sm text-muted-foreground">
                  {project.description}
                </div>
              )}
            </TableCell>
            <TableCell>
              <div className="flex flex-wrap gap-1">
                {project.environments.map((env) => (
                  <Badge
                    key={env}
                    variant="outline"
                    className={
                      env === project.defaultEnvironment
                        ? "border-blue-500 text-blue-700"
                        : "border-input text-foreground/80"
                    }
                  >
                    {env}
                    {env === project.defaultEnvironment && " (default)"}
                  </Badge>
                ))}
              </div>
            </TableCell>
            <TableCell className="text-right text-foreground">
              {project.vmCount ?? 0}
            </TableCell>
            {canManage && (
              <TableCell className="text-right">
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="text-muted-foreground hover:text-foreground"
                      disabled={pendingId === project.id}
                    >
                      <MoreHorizontal className="h-4 w-4" />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent className="bg-card border-border">
                    <DropdownMenuItem
                      onClick={() => onEdit(project)}
                      className="text-foreground focus:bg-accent focus:text-accent-foreground cursor-pointer"
                    >
                      <Pencil className="h-4 w-4 mr-2" />
                      Edit
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      onClick={() => onTransfer(project)}
                      className="text-foreground focus:bg-accent focus:text-accent-foreground cursor-pointer"
                    >
                      <ArrowRightLeft className="h-4 w-4 mr-2" />
                      Transfer
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      onClick={() => handleDelete(project)}
                      className="text-red-600 focus:bg-accent focus:text-red-700 cursor-pointer"
                    >
                      <Trash2 className="h-4 w-4 mr-2" />
                      Delete
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              </TableCell>
            )}
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
