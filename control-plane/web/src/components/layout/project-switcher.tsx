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

export function ProjectSwitcher({ onSelection }: { onSelection?: () => void }) {
  const { currentProject, projects, isLoading, switchProject } =
    useProjectContext();
  const router = useRouter();
  const [open, setOpen] = useState(false);

  const handleSwitch = (projectId: string) => {
    switchProject(projectId);
    setOpen(false);
    onSelection?.();
  };

  const label = isLoading
    ? "Loading…"
    : currentProject?.name || "No project";

  return (
    <DropdownMenu open={open} onOpenChange={setOpen}>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          aria-label="Switch project"
          className="flex w-full items-center gap-2 rounded-[7px] border border-border bg-background px-[9px] py-[7px] text-[12.5px] font-semibold transition-colors hover:bg-accent"
        >
          <FolderKanban className="h-3.5 w-3.5 text-muted-foreground" strokeWidth={1.6} />
          <span className="min-w-0 flex-1 truncate text-left">{label}</span>
          <ChevronDown className="h-3 w-3 shrink-0 text-muted-foreground" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-56">
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
            onSelection?.();
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
