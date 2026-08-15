"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
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
import { usePermissions, useTransferProject } from "@/lib/hooks";
import { organizationsApi } from "@/lib/api/organizations";
import { useAuth, useOrganization } from "@/providers";
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
  const { user } = useAuth();
  const { organizations, currentOrg } = useOrganization();
  const transferProject = useTransferProject();
  const [destinationOrgId, setDestinationOrgId] = useState("");

  const allOrganizationsQuery = useQuery({
    queryKey: ["organizations", "all"],
    queryFn: ({ signal }) => organizationsApi.listAll(signal),
    enabled: open && !!user?.isSystemAdmin,
  });
  const candidateOrganizations = user?.isSystemAdmin
    ? (allOrganizationsQuery.data ?? organizations)
    : organizations;
  const destinationCandidates = candidateOrganizations.filter(
    (organization) => organization.id !== currentOrg?.id
  );
  const { permissions } = usePermissions(
    destinationCandidates.map((organization) => ({
      key: `destination:${organization.id}`,
      action: "org:update",
      node: { type: "organization", id: organization.id },
    }))
  );
  // The backend requires org:update on the destination. Ask the evaluator
  // directly so canonical role IDs, custom roles, and system-admin bypass all
  // produce the same decision here as they do on submit.
  const destinations = destinationCandidates.filter(
    (organization) => permissions[`destination:${organization.id}`]
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
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Transfer Project</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Move{" "}
            <span className="font-medium text-foreground">{project?.name}</span>{" "}
            to another organization. You must be an admin of both.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="destinationOrg" className="text-foreground">
                Destination Organization
              </Label>
              {destinations.length === 0 ? (
                <p className="text-sm text-muted-foreground">
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
                    className="bg-background border-border text-foreground"
                  >
                    <SelectValue placeholder="Select organization" />
                  </SelectTrigger>
                  <SelectContent className="bg-card border-border">
                    {destinations.map((org) => (
                      <SelectItem
                        key={org.id}
                        value={org.id}
                        className="text-foreground focus:bg-accent focus:text-accent-foreground"
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
              className="border-input text-foreground/80 hover:bg-accent"
              onClick={() => onOpenChange(false)}
              disabled={transferProject.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-primary hover:bg-primary/90"
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
