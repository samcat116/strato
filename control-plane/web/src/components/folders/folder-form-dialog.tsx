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
  useCreateFolder,
  useUpdateFolder,
  folderErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";

/** Minimal shape needed to edit a folder (works for both list and tree nodes). */
export interface EditableFolder {
  id: string;
  name: string;
  description: string;
}

interface FolderFormDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When provided, the dialog edits this folder instead of creating one. */
  folder?: EditableFolder | null;
  /** When creating a subfolder, the parent folder's id and name (for context). */
  parent?: { id: string; name: string } | null;
}

export function FolderFormDialog({
  orgId,
  open,
  onOpenChange,
  folder,
  parent,
}: FolderFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        {/* Keyed so the form's initial state resets whenever the target folder
            or parent (create vs. edit vs. add-sub) changes. */}
        <FolderForm
          key={folder?.id ?? `new:${parent?.id ?? "root"}`}
          orgId={orgId}
          folder={folder ?? null}
          parent={parent ?? null}
          onClose={() => onOpenChange(false)}
        />
      </DialogContent>
    </Dialog>
  );
}

function FolderForm({
  orgId,
  folder,
  parent,
  onClose,
}: {
  orgId: string;
  folder: EditableFolder | null;
  parent: { id: string; name: string } | null;
  onClose: () => void;
}) {
  const isEdit = !!folder;
  const createFolder = useCreateFolder(orgId);
  const updateFolder = useUpdateFolder(orgId);
  const isPending = createFolder.isPending || updateFolder.isPending;

  const [name, setName] = useState(folder?.name ?? "");
  const [description, setDescription] = useState(folder?.description ?? "");

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Folder name is required");
      return;
    }

    try {
      if (isEdit && folder) {
        await updateFolder.mutateAsync({
          ouId: folder.id,
          data: { name: trimmedName, description: description.trim() },
        });
        toast.success(`Updated ${trimmedName}`);
      } else {
        await createFolder.mutateAsync({
          name: trimmedName,
          description: description.trim(),
          parentOuId: parent?.id,
        });
        toast.success(`Created ${trimmedName}`);
      }
      onClose();
    } catch (error) {
      toast.error(
        folderErrorMessage(
          error,
          isEdit
            ? "Failed to update folder"
            : "Failed to create folder"
        )
      );
    }
  };

  const title = isEdit
    ? "Edit Folder"
    : parent
      ? `Add subfolder to ${parent.name}`
      : "Create Folder";

  return (
    <>
      <DialogHeader>
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {isEdit
            ? "Update this folder's name and description."
            : "Folders group projects into a hierarchy within your organization."}
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="folderName" className="text-foreground">
              Name
            </Label>
            <Input
              id="folderName"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Platform"
              className="bg-background border-border text-foreground"
              disabled={isPending}
              autoFocus
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="folderDescription" className="text-foreground">
              Description
            </Label>
            <Input
              id="folderDescription"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="A short description of the folder"
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
              "Create Folder"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
