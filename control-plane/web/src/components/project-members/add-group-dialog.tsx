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
import {
  useGroups,
  useGrantProjectGroup,
  projectMemberErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { ProjectRole } from "@/types/api";

const ROLES: ProjectRole[] = ["admin", "member", "viewer"];

interface AddGroupDialogProps {
  projectId: string;
  organizationId: string;
  /** Group IDs already granted a role, hidden from the picker. */
  excludeGroupIds: string[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function AddGroupDialog({
  projectId,
  organizationId,
  excludeGroupIds,
  open,
  onOpenChange,
}: AddGroupDialogProps) {
  const { data: groups = [], isLoading: groupsLoading } =
    useGroups(organizationId);
  const grant = useGrantProjectGroup(projectId);
  const [groupId, setGroupId] = useState("");
  const [role, setRole] = useState<ProjectRole>("member");

  const available = groups.filter((g) => !excludeGroupIds.includes(g.id));

  const handleClose = () => {
    onOpenChange(false);
    setTimeout(() => {
      setGroupId("");
      setRole("member");
    }, 200);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!groupId) {
      toast.error("Please select a group");
      return;
    }
    try {
      await grant.mutateAsync({ groupId, role });
      toast.success("Group access granted");
      handleClose();
    } catch (error) {
      toast.error(projectMemberErrorMessage(error, "Failed to grant group"));
    }
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Grant group access</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Give a group a role on this project. Every member of the group
            inherits it.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="pgGroup" className="text-foreground">
                Group
              </Label>
              <Select
                value={groupId}
                onValueChange={setGroupId}
                disabled={grant.isPending || groupsLoading}
              >
                <SelectTrigger
                  id="pgGroup"
                  className="bg-background border-border text-foreground"
                >
                  <SelectValue
                    placeholder={
                      groupsLoading ? "Loading groups..." : "Select a group"
                    }
                  />
                </SelectTrigger>
                <SelectContent className="bg-card border-border">
                  {available.length === 0 ? (
                    <div className="px-2 py-1.5 text-sm text-muted-foreground">
                      No groups available
                    </div>
                  ) : (
                    available.map((g) => (
                      <SelectItem
                        key={g.id}
                        value={g.id}
                        className="text-foreground focus:bg-accent focus:text-accent-foreground"
                      >
                        {g.name}
                      </SelectItem>
                    ))
                  )}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label htmlFor="pgRole" className="text-foreground">
                Role
              </Label>
              <Select
                value={role}
                onValueChange={(v) => setRole(v as ProjectRole)}
                disabled={grant.isPending}
              >
                <SelectTrigger
                  id="pgRole"
                  className="bg-background border-border text-foreground capitalize"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-card border-border">
                  {ROLES.map((r) => (
                    <SelectItem
                      key={r}
                      value={r}
                      className="text-foreground capitalize focus:bg-accent focus:text-accent-foreground"
                    >
                      {r}
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
              className="border-input"
              onClick={handleClose}
              disabled={grant.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-primary hover:bg-primary/90"
              disabled={grant.isPending}
            >
              {grant.isPending ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Granting...
                </>
              ) : (
                "Grant access"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
