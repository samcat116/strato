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
import {
  useCreateOrganizationalUnit,
  useUpdateOrganizationalUnit,
  ouErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";

/** Minimal shape needed to edit an OU (works for both list and tree nodes). */
export interface EditableOU {
  id: string;
  name: string;
  description: string;
}

interface OuFormDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When provided, the dialog edits this OU instead of creating one. */
  ou?: EditableOU | null;
  /** When creating a sub-unit, the parent OU's id and name (for context). */
  parent?: { id: string; name: string } | null;
}

export function OuFormDialog({
  orgId,
  open,
  onOpenChange,
  ou,
  parent,
}: OuFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        {/* Keyed so the form's initial state resets whenever the target OU
            or parent (create vs. edit vs. add-sub) changes. */}
        <OuForm
          key={ou?.id ?? `new:${parent?.id ?? "root"}`}
          orgId={orgId}
          ou={ou ?? null}
          parent={parent ?? null}
          onClose={() => onOpenChange(false)}
        />
      </DialogContent>
    </Dialog>
  );
}

function OuForm({
  orgId,
  ou,
  parent,
  onClose,
}: {
  orgId: string;
  ou: EditableOU | null;
  parent: { id: string; name: string } | null;
  onClose: () => void;
}) {
  const isEdit = !!ou;
  const createOU = useCreateOrganizationalUnit(orgId);
  const updateOU = useUpdateOrganizationalUnit(orgId);
  const isPending = createOU.isPending || updateOU.isPending;

  const [name, setName] = useState(ou?.name ?? "");
  const [description, setDescription] = useState(ou?.description ?? "");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Unit name is required");
      return;
    }

    try {
      if (isEdit && ou) {
        await updateOU.mutateAsync({
          ouId: ou.id,
          data: { name: trimmedName, description: description.trim() },
        });
        toast.success(`Updated ${trimmedName}`);
      } else {
        await createOU.mutateAsync({
          name: trimmedName,
          description: description.trim(),
          parentOuId: parent?.id,
        });
        toast.success(`Created ${trimmedName}`);
      }
      onClose();
    } catch (error) {
      toast.error(
        ouErrorMessage(
          error,
          isEdit
            ? "Failed to update organizational unit"
            : "Failed to create organizational unit"
        )
      );
    }
  };

  const title = isEdit
    ? "Edit Organizational Unit"
    : parent
      ? `Add Sub-Unit to ${parent.name}`
      : "Create Organizational Unit";

  return (
    <>
      <DialogHeader>
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {isEdit
            ? "Update this unit's name and description."
            : "Organizational units group projects into a hierarchy within your organization."}
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="ouName" className="text-foreground">
              Name
            </Label>
            <Input
              id="ouName"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Platform"
              className="bg-background border-border text-foreground"
              disabled={isPending}
              autoFocus
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="ouDescription" className="text-foreground">
              Description
            </Label>
            <Input
              id="ouDescription"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="A short description of the unit"
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
              "Create Unit"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
