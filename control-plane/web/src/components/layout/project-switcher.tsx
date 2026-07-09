"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Check, ChevronDown, FolderKanban, Settings } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useProjectContext } from "@/providers";

export function ProjectSwitcher() {
  const { currentProject, projects, isLoading, switchProject } =
    useProjectContext();
  const router = useRouter();
  const [open, setOpen] = useState(false);

  const handleSwitch = (projectId: string) => {
    switchProject(projectId);
    setOpen(false);
  };

  const label = isLoading
    ? "Loading…"
    : currentProject?.name || "No project";

  return (
    <DropdownMenu open={open} onOpenChange={setOpen}>
      <DropdownMenuTrigger asChild>
        <button className="flex h-8 items-center gap-1.5 rounded-[7px] border border-border bg-background px-2.5 text-[12.5px] font-medium transition-colors hover:bg-accent">
          <FolderKanban className="h-3.5 w-3.5 text-muted-foreground" strokeWidth={1.6} />
          <span className="max-w-40 truncate">{label}</span>
          <ChevronDown className="h-3 w-3 text-muted-foreground" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-56">
        <DropdownMenuLabel className="text-xs font-medium uppercase text-muted-foreground">
          Switch Project
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <div className="max-h-48 overflow-y-auto">
          {projects.length === 0 ? (
            <div className="px-2 py-2 text-sm text-muted-foreground">
              No projects in this organization.
            </div>
          ) : (
            projects.map((project) => (
              <DropdownMenuItem
                key={project.id}
                onClick={() => handleSwitch(project.id)}
                className="cursor-pointer"
              >
                <span className="flex-1 truncate">{project.name}</span>
                {currentProject?.id === project.id && <Check className="h-4 w-4" />}
              </DropdownMenuItem>
            ))
          )}
        </div>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          onClick={() => {
            setOpen(false);
            router.push("/projects");
          }}
          className="cursor-pointer"
        >
          <Settings className="mr-2 h-4 w-4" />
          Manage Projects
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
