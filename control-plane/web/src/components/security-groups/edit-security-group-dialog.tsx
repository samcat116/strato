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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { securityGroupsApi } from "@/lib/api/security-groups";
import type { SecurityGroup } from "@/types/api";
import { toast } from "sonner";

interface EditSecurityGroupDialogProps {
  group: SecurityGroup | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onUpdated?: () => void;
}

export function EditSecurityGroupDialog({
  group,
  open,
  onOpenChange,
  onUpdated,
}: EditSecurityGroupDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        {group && (
          // Keyed on the group id so switching targets remounts the form with
          // fresh initial state — no effect needed to re-seed.
          <EditSecurityGroupForm
            key={group.id}
            group={group}
            onOpenChange={onOpenChange}
            onUpdated={onUpdated}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

function EditSecurityGroupForm({
  group,
  onOpenChange,
  onUpdated,
}: {
  group: SecurityGroup;
  onOpenChange: (open: boolean) => void;
  onUpdated?: () => void;
}) {
  const [isLoading, setIsLoading] = useState(false);
  const [name, setName] = useState(group.name);
  const [description, setDescription] = useState(group.description ?? "");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmedName = name.trim();
    if (!group.isDefault && !trimmedName) {
      toast.error("Please enter a security group name");
      return;
    }

    setIsLoading(true);
    try {
      await securityGroupsApi.update(group.id, {
        // The default group cannot be renamed; only send a changed name.
        name:
          !group.isDefault && trimmedName !== group.name
            ? trimmedName
            : undefined,
        // Always sent: an empty string clears the description server-side
        // (omitting the field would mean "leave unchanged").
        description: description.trim(),
      });
      toast.success(
        `Security group "${group.isDefault ? group.name : trimmedName}" updated`
      );
      onOpenChange(false);
      onUpdated?.();
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : "Failed to update security group"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Edit {group.name}</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {group.isDefault
            ? "The default group cannot be renamed, but its description and rules are editable."
            : "Update the group's name and description."}
        </DialogDescription>
      </DialogHeader>
      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="editSecurityGroupName" className="text-foreground">
              Name
            </Label>
            <Input
              id="editSecurityGroupName"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isLoading || group.isDefault}
            />
          </div>
          <div className="space-y-2">
            <Label
              htmlFor="editSecurityGroupDescription"
              className="text-foreground"
            >
              Description
            </Label>
            <Input
              id="editSecurityGroupDescription"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isLoading}
            />
          </div>
        </div>
        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            className="border-input text-foreground/80 hover:bg-accent"
            disabled={isLoading}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
            disabled={isLoading}
          >
            {isLoading ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                Saving...
              </>
            ) : (
              "Save Changes"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
