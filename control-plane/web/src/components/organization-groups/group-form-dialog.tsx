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
import { useCreateGroup, useUpdateGroup, groupErrorMessage } from "@/lib/hooks";
import { toast } from "sonner";
import type { Group } from "@/types/api";

interface GroupFormDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When provided, the dialog edits this group instead of creating one. */
  group?: Group | null;
}

export function GroupFormDialog({
  orgId,
  open,
  onOpenChange,
  group,
}: GroupFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        {/* Keyed so the form's initial state resets whenever the target
            group (or create vs. edit mode) changes. */}
        <GroupForm
          key={group?.id ?? "new"}
          orgId={orgId}
          group={group ?? null}
          onClose={() => onOpenChange(false)}
        />
      </DialogContent>
    </Dialog>
  );
}

function GroupForm({
  orgId,
  group,
  onClose,
}: {
  orgId: string;
  group: Group | null;
  onClose: () => void;
}) {
  const isEdit = !!group;
  const createGroup = useCreateGroup(orgId);
  const updateGroup = useUpdateGroup(orgId);
  const isPending = createGroup.isPending || updateGroup.isPending;

  const [name, setName] = useState(group?.name ?? "");
  const [description, setDescription] = useState(group?.description ?? "");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Group name is required");
      return;
    }

    try {
      if (isEdit && group) {
        await updateGroup.mutateAsync({
          groupId: group.id,
          data: { name: trimmedName, description: description.trim() },
        });
        toast.success(`Updated ${trimmedName}`);
      } else {
        await createGroup.mutateAsync({
          name: trimmedName,
          description: description.trim(),
        });
        toast.success(`Created ${trimmedName}`);
      }
      onClose();
    } catch (error) {
      toast.error(
        groupErrorMessage(
          error,
          isEdit ? "Failed to update group" : "Failed to create group"
        )
      );
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>{isEdit ? "Edit Group" : "Create Group"}</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {isEdit
            ? "Update this group's name and description."
            : "Groups let you manage a set of organization members together."}
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="groupName" className="text-foreground">
              Name
            </Label>
            <Input
              id="groupName"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Engineering"
              className="bg-background border-border text-foreground"
              disabled={isPending}
              autoFocus
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="groupDescription" className="text-foreground">
              Description
            </Label>
            <Input
              id="groupDescription"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="A short description of the group"
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
          </div>
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            className="border-input"
            onClick={onClose}
            disabled={isPending}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
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
              "Create Group"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
