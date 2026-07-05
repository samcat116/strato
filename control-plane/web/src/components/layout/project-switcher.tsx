"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Check, ChevronDown, FolderKanban, Settings } from "lucide-react";
import { Button } from "@/components/ui/button";
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
    ? "Loading..."
    : currentProject?.name || "No project";

  return (
    <DropdownMenu open={open} onOpenChange={setOpen}>
      <DropdownMenuTrigger asChild>
        <Button
          variant="outline"
          className="bg-gray-800 hover:bg-gray-700 text-gray-200 border-gray-600"
        >
          <FolderKanban className="mr-2 h-4 w-4 text-gray-400" />
          {label}
          <ChevronDown className="ml-2 h-4 w-4 text-gray-500" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="w-64 bg-gray-800 border-gray-600">
        <DropdownMenuLabel className="text-xs font-medium text-gray-400 uppercase">
          Switch Project
        </DropdownMenuLabel>
        <DropdownMenuSeparator className="bg-gray-700" />
        <div className="max-h-48 overflow-y-auto">
          {projects.length === 0 ? (
            <div className="px-2 py-2 text-sm text-gray-400">
              No projects in this organization.
            </div>
          ) : (
            projects.map((project) => (
              <DropdownMenuItem
                key={project.id}
                onClick={() => handleSwitch(project.id)}
                className="text-gray-200 hover:bg-gray-700 focus:bg-gray-700 cursor-pointer"
              >
                <span className="flex-1 truncate">{project.name}</span>
                {currentProject?.id === project.id && (
                  <Check className="h-4 w-4 text-blue-400" />
                )}
              </DropdownMenuItem>
            ))
          )}
        </div>
        <DropdownMenuSeparator className="bg-gray-700" />
        <DropdownMenuItem
          onClick={() => {
            setOpen(false);
            router.push("/projects");
          }}
          className="text-blue-400 hover:bg-gray-700 focus:bg-gray-700 cursor-pointer"
        >
          <Settings className="h-4 w-4 mr-2" />
          Manage Projects
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
