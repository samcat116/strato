"use client";

import { useState } from "react";
import { Loader2, Plus, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useCreateProject, useUpdateProject } from "@/lib/hooks";
import type { Project } from "@/lib/api/projects";
import { toast } from "sonner";

const DEFAULT_ENVIRONMENTS = ["development", "staging", "production"];

interface ProjectFormDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Organization the project is created in (create mode only). */
  organizationId: string;
  /** When provided, the dialog edits this project instead of creating one. */
  project?: Project | null;
}

export function ProjectFormDialog({
  open,
  onOpenChange,
  organizationId,
  project,
}: ProjectFormDialogProps) {
  const isEdit = !!project;
  const createProject = useCreateProject(organizationId);
  const updateProject = useUpdateProject();
  const isPending = createProject.isPending || updateProject.isPending;

  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [environments, setEnvironments] = useState<string[]>(
    DEFAULT_ENVIRONMENTS
  );
  const [defaultEnvironment, setDefaultEnvironment] = useState("development");
  const [newEnvironment, setNewEnvironment] = useState("");

  // Seed form state whenever the dialog opens (or the target project changes),
  // derived during render rather than in an effect to avoid cascading renders.
  // The key is null while closed so reopening always re-seeds.
  const seedKey = open ? project?.id ?? "new" : null;
  const [seededKey, setSeededKey] = useState<string | null>(null);
  if (seedKey !== seededKey) {
    setSeededKey(seedKey);
    if (open) {
      if (project) {
        setName(project.name);
        setDescription(project.description || "");
        setEnvironments(project.environments);
        setDefaultEnvironment(project.defaultEnvironment);
      } else {
        setName("");
        setDescription("");
        setEnvironments(DEFAULT_ENVIRONMENTS);
        setDefaultEnvironment("development");
      }
      setNewEnvironment("");
    }
  }

  const addEnvironment = () => {
    const value = newEnvironment.trim().toLowerCase();
    if (!value) return;
    if (environments.includes(value)) {
      toast.error(`Environment "${value}" already exists`);
      return;
    }
    setEnvironments((prev) => [...prev, value]);
    setNewEnvironment("");
  };

  const removeEnvironment = (env: string) => {
    if (environments.length <= 1) {
      toast.error("A project must have at least one environment");
      return;
    }
    setEnvironments((prev) => prev.filter((e) => e !== env));
    // Keep the default valid if it was just removed.
    if (defaultEnvironment === env) {
      setDefaultEnvironment(environments.find((e) => e !== env) ?? "");
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Project name is required");
      return;
    }
    if (environments.length === 0) {
      toast.error("A project must have at least one environment");
      return;
    }
    if (!environments.includes(defaultEnvironment)) {
      toast.error("The default environment must be one of the environments");
      return;
    }

    try {
      if (project) {
        await updateProject.mutateAsync({
          projectId: project.id,
          data: {
            name: trimmedName,
            description,
            environments,
            defaultEnvironment,
          },
        });
        toast.success("Project updated");
      } else {
        await createProject.mutateAsync({
          name: trimmedName,
          description,
          environments,
          defaultEnvironment,
        });
        toast.success(`Project "${trimmedName}" created`);
      }
      onOpenChange(false);
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : `Failed to ${isEdit ? "update" : "create"} project`
      );
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>
            {isEdit ? "Edit Project" : "Create Project"}
          </DialogTitle>
          <DialogDescription className="text-gray-400">
            {isEdit
              ? "Update this project's details and environments."
              : "Projects organize VMs and images within an organization."}
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="projectName" className="text-gray-200">
                Name
              </Label>
              <Input
                id="projectName"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="my-project"
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={isPending}
                autoFocus
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="projectDescription" className="text-gray-200">
                Description
              </Label>
              <Input
                id="projectDescription"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="A brief description of the project"
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={isPending}
              />
            </div>

            <div className="space-y-2">
              <Label className="text-gray-200">Environments</Label>
              <div className="flex flex-wrap gap-2">
                {environments.map((env) => (
                  <span
                    key={env}
                    className="inline-flex items-center gap-1 rounded-md bg-gray-700 px-2 py-1 text-sm text-gray-100"
                  >
                    {env}
                    <button
                      type="button"
                      onClick={() => removeEnvironment(env)}
                      disabled={isPending || environments.length <= 1}
                      className="text-gray-400 hover:text-red-400 disabled:opacity-40 disabled:hover:text-gray-400"
                      aria-label={`Remove ${env}`}
                    >
                      <X className="h-3 w-3" />
                    </button>
                  </span>
                ))}
              </div>
              <div className="flex gap-2">
                <Input
                  value={newEnvironment}
                  onChange={(e) => setNewEnvironment(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      addEnvironment();
                    }
                  }}
                  placeholder="Add environment"
                  className="bg-gray-900 border-gray-700 text-gray-100"
                  disabled={isPending}
                />
                <Button
                  type="button"
                  variant="outline"
                  onClick={addEnvironment}
                  className="border-gray-600 text-gray-300 hover:bg-gray-700"
                  disabled={isPending || !newEnvironment.trim()}
                >
                  <Plus className="h-4 w-4" />
                </Button>
              </div>
              {isEdit && (
                <p className="text-xs text-gray-500">
                  Environments in use by existing VMs cannot be removed.
                </p>
              )}
            </div>

            <div className="space-y-2">
              <Label htmlFor="defaultEnvironment" className="text-gray-200">
                Default Environment
              </Label>
              <Select
                value={defaultEnvironment}
                onValueChange={setDefaultEnvironment}
                disabled={isPending}
              >
                <SelectTrigger
                  id="defaultEnvironment"
                  className="bg-gray-900 border-gray-700 text-gray-100"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-gray-800 border-gray-700">
                  {environments.map((env) => (
                    <SelectItem
                      key={env}
                      value={env}
                      className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                    >
                      {env}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              className="border-gray-600 text-gray-300 hover:bg-gray-700"
              onClick={() => onOpenChange(false)}
              disabled={isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-blue-600 hover:bg-blue-700"
              disabled={isPending}
            >
              {isPending ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  {isEdit ? "Saving..." : "Creating..."}
                </>
              ) : isEdit ? (
                "Save Changes"
              ) : (
                "Create Project"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
