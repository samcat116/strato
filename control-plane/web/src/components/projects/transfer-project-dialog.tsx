"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useTransferProject } from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { Project } from "@/lib/api/projects";
import { toast } from "sonner";

interface TransferProjectDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  project: Project | null;
}

export function TransferProjectDialog({
  open,
  onOpenChange,
  project,
}: TransferProjectDialogProps) {
  const { organizations } = useOrganization();
  const transferProject = useTransferProject();
  const [destinationOrgId, setDestinationOrgId] = useState("");

  // Valid targets are other organizations the user administers — the backend
  // requires admin on the destination, so offering member-only orgs would just
  // produce a 403 on submit.
  const destinations = organizations.filter(
    (org) => org.id !== project?.organizationId && org.userRole === "admin"
  );

  // Clear the selection each time the dialog (re)opens, derived during render.
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) setDestinationOrgId("");
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!project) return;
    if (!destinationOrgId) {
      toast.error("Select a destination organization");
      return;
    }

    try {
      await transferProject.mutateAsync({
        projectId: project.id,
        data: { organizationId: destinationOrgId },
      });
      toast.success("Project transferred");
      onOpenChange(false);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to transfer project"
      );
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>Transfer Project</DialogTitle>
          <DialogDescription className="text-gray-400">
            Move{" "}
            <span className="font-medium text-gray-200">{project?.name}</span>{" "}
            to another organization. You must be an admin of both.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="destinationOrg" className="text-gray-200">
                Destination Organization
              </Label>
              {destinations.length === 0 ? (
                <p className="text-sm text-gray-400">
                  No other organizations are available to transfer to.
                </p>
              ) : (
                <Select
                  value={destinationOrgId}
                  onValueChange={setDestinationOrgId}
                  disabled={transferProject.isPending}
                >
                  <SelectTrigger
                    id="destinationOrg"
                    className="bg-gray-900 border-gray-700 text-gray-100"
                  >
                    <SelectValue placeholder="Select organization" />
                  </SelectTrigger>
                  <SelectContent className="bg-gray-800 border-gray-700">
                    {destinations.map((org) => (
                      <SelectItem
                        key={org.id}
                        value={org.id}
                        className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                      >
                        {org.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              )}
            </div>
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              className="border-gray-600 text-gray-300 hover:bg-gray-700"
              onClick={() => onOpenChange(false)}
              disabled={transferProject.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-blue-600 hover:bg-blue-700"
              disabled={transferProject.isPending || destinations.length === 0}
            >
              {transferProject.isPending ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Transferring...
                </>
              ) : (
                "Transfer"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
