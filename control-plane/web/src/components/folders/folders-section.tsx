"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { useFolders } from "@/lib/hooks";
import { FolderTree } from "./folder-tree";
import { FolderFormDialog, type EditableFolder } from "./folder-form-dialog";

interface FoldersSectionProps {
  orgId: string;
  /** Whether the current user can create/edit/delete folders (org admin). */
  canManage: boolean;
}

export function FoldersSection({
  orgId,
  canManage,
}: FoldersSectionProps) {
  const { data: folders = [], isLoading } = useFolders(orgId);

  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<EditableFolder | null>(null);
  const [parent, setParent] = useState<{ id: string; name: string } | null>(
    null
  );

  const handleCreateTopLevel = () => {
    setEditing(null);
    setParent(null);
    setFormOpen(true);
  };

  const handleEdit = (folder: EditableFolder) => {
    setEditing(folder);
    setParent(null);
    setFormOpen(true);
  };

  const handleAddSub = (p: { id: string; name: string }) => {
    setEditing(null);
    setParent(p);
    setFormOpen(true);
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <CardTitle className="text-lg font-semibold text-foreground">
            Folders
          </CardTitle>
          {canManage && (
            <Button
              size="sm"
              className="bg-primary hover:bg-primary/90"
              onClick={handleCreateTopLevel}
            >
              <Plus className="h-4 w-4 mr-2" />
              Create Folder
            </Button>
          )}
        </CardHeader>
        <CardContent>
          {!canManage && (
            <p className="text-sm text-muted-foreground mb-4">
              You need admin rights to create, edit, or delete folders.
            </p>
          )}
          <FolderTree
            orgId={orgId}
            folders={folders}
            isLoading={isLoading}
            canManage={canManage}
            onEdit={handleEdit}
            onAddSub={handleAddSub}
          />
        </CardContent>
      </Card>

      <FolderFormDialog
        orgId={orgId}
        open={formOpen}
        onOpenChange={setFormOpen}
        folder={editing}
        parent={parent}
      />
    </>
  );
}
